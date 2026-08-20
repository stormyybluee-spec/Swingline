//
//  CaptureViewModel.swift
//  Swingline
//
//  The capture engine. This file owns the one AVCaptureSession in the app.
//  RecordView drives it for the real capture chrome. The bare debug harness
//  (CaptureView) and the preview layer (CameraPreview) live alongside it in
//  CaptureView.swift.
//
//  WHAT THIS DOES.
//
//  It connects the camera to VisionPoseProvider, computes lead hand speed per
//  frame, and feeds that to SwingDetector. When SwingDetector confirms a swing,
//  analyseBufferedSwing() runs the buffered frames through the engine and hands
//  a finished SwingRecord to AppStore, which persists it. That is the whole
//  capture to stored swing path.
//
//  MULTI SWING SETS.
//
//  A set is the same camera and the same detector, with the auto save switched
//  off and a longer buffer. The golfer hits a run of swings, the detector is
//  used only to count them so the disc can read 2/3, and when the set ends the
//  whole buffer is split into one clip per swing and each clip goes through the
//  ordinary single swing path. Splitting happens here, in splitSwingWindows,
//  not in Phases: Phases.segment finds P1 through P10 inside one swing and has
//  exactly one peak and one top to work with, so a buffer holding five swings
//  has to be cut into five clips before it ever reaches it.
//
//  The scoring itself lives in Analyze.analyseSwing, ported from analyze.js.
//  This file is the seam between the live camera and that pipeline, plus the
//  mapping from an analysis result onto the stored record shape.
//
//  House rule: no em dashes anywhere.
//

import SwiftUI
import AVFoundation

// MARK: - Capture engine

@MainActor
final class CaptureViewModel: NSObject, ObservableObject {

    // Live telemetry, read by RecordView's top strip and readiness ring.
    @Published var latestPersonCount: Int = 0
    @Published var latestConfidence: Double = 0
    @Published var trackedFps: Int = 0
    @Published var handSpeed: Double = 0
    @Published var detectorReady: Bool = false
    @Published var permission: Permission = .unknown
    @Published var bufferedFrames: Int = 0

    // Swing detection, mirrored off the detector so RecordView observes a single
    // object. swingPhase drives the record disc, swingCount ticks per swing,
    // lastSwingPeak is the peak hand speed of the most recent swing.
    @Published private(set) var swingPhase: SwingDetector.Phase = .idle
    @Published private(set) var swingCount: Int = 0
    @Published private(set) var lastSwingPeak: Double = 0

    // Multi swing sets. swingTarget is how many the golfer asked for, 1 meaning
    // ordinary automatic single capture. The rest drive the record disc.
    @Published private(set) var swingTarget: Int = 1
    @Published private(set) var isMultiRecording: Bool = false
    @Published private(set) var multiProcessing: Bool = false
    @Published private(set) var multiDetectedCount: Int = 0
    @Published private(set) var multiSavedCount: Int = 0

    enum Permission { case unknown, authorised, denied }

    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let poseProvider: any PoseProvider
    private let queue = DispatchQueue(label: "swingline.capture.frames")

    // The app store, so a finished swing can be persisted and shown. Weak
    // because the store outlives this view model and owns nothing here. Attached
    // by RecordView, which is where the store is in scope.
    weak var store: AppStore?
    // The camera in use, retained so exposure can be re-applied when the golfer
    // changes the manual exposure controls without rebuilding the session.
    private var activeDevice: AVCaptureDevice?

    /*
      Apply the manual exposure choice, or hand control back to the camera.

      Both the shutter duration and the ISO are clamped to what the active format
      actually supports, because setExposureModeCustom rejects values outside the
      device range. So a 1/8000 request on a sensor that tops out slower settles
      on the fastest it can do rather than throwing.
    */
    func applyExposureSettings() {
        guard let device = activeDevice else { return }
        let enabled = store?.settings.manualExposureEnabled ?? false

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if enabled, device.isExposureModeSupported(.custom) {
                let denom = Int32(max(1, store?.settings.exposureDurationDenominator ?? 2000))
                var duration = CMTimeMake(value: 1, timescale: denom)
                let minD = device.activeFormat.minExposureDuration
                let maxD = device.activeFormat.maxExposureDuration
                duration = CMTimeMinimum(CMTimeMaximum(duration, minD), maxD)

                var iso = store?.settings.exposureISO ?? 200.0
                iso = min(max(iso, device.activeFormat.minISO), device.activeFormat.maxISO)

                device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
            } else if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
        } catch {
            // A failed exposure change leaves the camera on its previous mode,
            // which is a safe fallback, so this is not surfaced to the golfer.
        }
    }

    // The live swing detector. Fed one hand speed per tracked frame. When it
    // fires, analyseBufferedSwing runs, unless a set is in progress.
    private let swingDetector = SwingDetector()

    // Rolling window of recent frames. On a confirmed swing this is the clip the
    // engine reads. Bounded so memory does not grow without limit.
    private var buffer: [Frame] = []
    private let maxBufferedFrames = 240
    /*
      The set buffer. Five swings with a walk up and a reset between each is a
      minute of footage, which the 240 frame single swing window cannot hold, so
      the cap is raised for the duration of a set and dropped again afterwards.
      At the 60fps delivery cap this is 60 seconds of pose frames, roughly 8MB of
      landmark data. Raise it and check memory on the oldest supported device.
    */
    private let maxBufferedFramesSet = 3600
    private var bufferCap = 240
    // A set that is never stopped would run until the cap evicts the first
    // swings. This stops it at a length no golfer needs.
    private let maxSetSeconds: Double = 90
    private var setStartedAtMs: Double?

    private var recentTimestamps: [Double] = []
    private var lastLeadWrist: Vec3?

    // Lead wrist index for a right handed golfer, used only for the live hand
    // speed readout. The real analysis resolves handedness from settings.
    private let sides = Landmarks.sides(.right)

    init(poseProvider: any PoseProvider = MediaPipePoseProvider()) {
        self.poseProvider = poseProvider
        super.init()

        // A confirmed swing runs the pipeline and stores the result. During a
        // set it only advances the counter: the clips are cut and saved when the
        // set ends, so a swing is never saved twice.
        swingDetector.onSwing = { [weak self] peak in
            guard let self else { return }
            self.lastSwingPeak = peak

            if self.isMultiRecording {
                self.multiDetectedCount += 1
                if self.multiDetectedCount >= self.swingTarget {
                    self.stopMultiCapture()
                }
                return
            }

            // A set is selected but not started. The disc is a start control in
            // that mode, so nothing is captured until the golfer taps it.
            guard self.swingTarget == 1 else { return }
            self.analyseBufferedSwing()
        }
    }

    // Called by RecordView once the store is in scope, so a finished swing has
    // somewhere to go.
    func attach(store: AppStore) {
        self.store = store
    }

    // MARK: Permission

    func requestPermissionAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permission = .authorised
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.permission = granted ? .authorised : .denied
                    if granted { self.configureAndStart() }
                }
            }
        default:
            permission = .denied
        }
    }

    // MARK: Session

    private func configureAndStart() {
        // Configuration reads store.settings, which is main actor state, so it
        // stays on the main actor. Only startRunning, which Apple documents as a
        // blocking call that should not sit on the main thread, is hopped onto
        // the capture queue. The session object is safe to start from there.
        configureSession()
        let session = self.session
        queue.async {
            if !session.isRunning { session.startRunning() }
        }
    }

    /*
      Swap the camera and restart the feed on the new one.

      Everything derived from the old camera is thrown away: the frame buffer,
      the timestamp window and the last wrist position. A front camera sees the
      golfer from the opposite side, so a hand speed computed across the swap
      would be a jump between two unrelated coordinate frames, and a buffer
      holding both halves would be analysed as one impossible swing.
    */
    func flipCamera() {
        let next = (store?.settings.cameraFacing ?? "environment") == "user" ? "environment" : "user"
        store?.update { $0.cameraFacing = next }
        reconfigureCamera()
    }

    /*
      Rebuild the session inputs against current settings, live.

      AVCaptureSession accepts a configuration change while it is running, so the
      preview keeps its layer and the golfer sees a swap rather than a black
      screen and a reconnect. Also used by the quality picker, which changes the
      active format on the same device.
    */
    func reconfigureCamera() {
        guard permission == .authorised else { return }
        discardInFlightSet()
        resetTrackingState()
        configureSession()
        let session = self.session
        queue.async {
            if !session.isRunning { session.startRunning() }
        }
    }

    // Phase 5, Step 9: camera facing and capture quality are read from settings
    // here rather than hardcoded. The old version pinned the rear camera and a
    // fixed preset, so the settings screen's camera controls did nothing.
    //
    // Idempotent: safe to call again on an already configured session, which is
    // what the camera flip and the quality picker both do.
    private func configureSession() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .high

        // Drop whatever camera is attached before attaching the next one. A
        // session will not take a second video input.
        for input in session.inputs { session.removeInput(input) }
        activeDevice = nil

        // Camera facing from settings, rear when unset.
        let facing = store?.settings.cameraFacing ?? "environment"
        let position: AVCaptureDevice.Position = facing == "user" ? .front : .back

        // A device with no front camera, or a simulator, still gets a session
        // rather than a black screen.
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(for: .video)

        if let device,
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            activeDevice = device
            // Capture quality. iOS can genuinely deliver high frame rate where
            // the web could only request it.
            applyQuality(store?.settings.cameraQuality ?? "1080p60", to: device)
            applyExposureSettings()
        }

        // The output survives a camera swap, so it is only attached once.
        if session.outputs.isEmpty {
            videoOutput.setSampleBufferDelegate(self, queue: queue)
            videoOutput.alwaysDiscardsLateVideoFrames = true
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            }
        }
    }

    // Parse a quality string like "1080p120" into a target height and fps, then
    // choose the AVCaptureDevice.Format that meets or best approaches it, then
    // lock the frame duration so the camera actually runs at that rate. This is
    // the single biggest thing the native build can do that the web could not.
    private func applyQuality(_ quality: String, to device: AVCaptureDevice) {
        let parts = quality.split(separator: "p")
        let targetHeight = Int(parts.first ?? "1080") ?? 1080
        let requestedFps = Double(parts.count > 1 ? parts[1] : "60") ?? 60

        /*
          PERFORMANCE CAP.

          High frame rate capture at 120 or 240 fps is where the record screen
          starts dropping frames on device, because every delivered frame runs
          the full pose pipeline and the SceneKit panel is competing for the same
          GPU. The delivered rate is therefore capped here. The format is still
          chosen at the requested resolution and the requested high speed range,
          so the sensor is in its high speed mode, but the effective frame
          duration is locked to the cap so the pipeline sees a rate it can keep
          up with.

          To lift the cap, raise this one number, or set it to requestedFps to
          honour the setting exactly:

              let performanceCapFps = 60.0            // current, smooth
              let performanceCapFps = requestedFps    // full rate, may drop frames

          The format search still uses requestedFps, so a 120 or 240 request
          picks a real high speed format and only the delivered cadence is
          limited. That keeps the door open to raising the cap later without
          re picking formats.
        */
        let performanceCapFps = 60.0
        let targetFps = requestedFps
        let effectiveFps = min(requestedFps, performanceCapFps)

        var best: AVCaptureDevice.Format?
        var bestScore = Double.greatestFiniteMagnitude

        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let maxRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            // Only consider formats that can hit the requested rate, so a 30fps
            // format is never chosen for a 240 request. The format is picked for
            // the full requested rate even though delivery is capped, so the
            // sensor runs in the right high speed mode.
            guard maxRate + 0.5 >= targetFps else { continue }
            let heightGap = abs(Double(dims.height) - Double(targetHeight))
            let rateGap = abs(maxRate - targetFps) * 10
            let score = heightGap + rateGap
            if score < bestScore {
                bestScore = score
                best = format
            }
        }

        guard let chosen = best, (try? device.lockForConfiguration()) != nil else { return }
        device.activeFormat = chosen
        // Lock to the capped delivery rate, not the requested one.
        let duration = CMTime(value: 1, timescale: CMTimeScale(effectiveFps.rounded()))
        // Clamp to what the chosen format supports, so an unsupported request
        // settles on the nearest legal rate rather than throwing.
        if let range = chosen.videoSupportedFrameRateRanges.first {
            let clamped = min(max(duration, range.minFrameDuration), range.maxFrameDuration)
            device.activeVideoMinFrameDuration = clamped
            device.activeVideoMaxFrameDuration = clamped
        }
        device.unlockForConfiguration()
    }

    func stop() {
        // Capture the session reference on the main actor, then stop it off the
        // main thread. Capturing self inside the background closure is what
        // tripped the isolation warning, so only the Sendable session crosses.
        let session = self.session
        queue.async {
            if session.isRunning { session.stopRunning() }
        }
        poseProvider.close()
    }

    // Cancel a false arm or an in progress capture from the UI, dropping the
    // detector straight back to WAIT. Harmless while already idle.
    func cancelDetection() {
        swingDetector.reset()
        swingPhase = swingDetector.phase
    }

    // MARK: Multi swing sets

    // Set the size of a set. 1 restores ordinary automatic single capture.
    // Changing size cancels anything in progress rather than half applying.
    func setSwingTarget(_ target: Int) {
        let clamped = min(max(target, 1), 5)
        guard clamped != swingTarget else { return }
        discardInFlightSet()
        swingTarget = clamped
        multiSavedCount = 0
    }

    /*
      Begin a set.

      The buffer is emptied first so a practice swing taken while the golfer was
      lining up does not become swing one of the set, and the cap is raised for
      the duration.
    */
    func startMultiCapture() {
        guard swingTarget > 1, !isMultiRecording, !multiProcessing else { return }
        buffer.removeAll()
        bufferedFrames = 0
        bufferCap = maxBufferedFramesSet
        multiDetectedCount = 0
        multiSavedCount = 0
        setStartedAtMs = nil
        swingDetector.reset()
        swingPhase = swingDetector.phase
        isMultiRecording = true
    }

    /*
      End a set and cut it into swings.

      Called by the golfer tapping the disc, by the counter reaching the target,
      and by the length guard. Everything recorded is saved: if the splitter
      cannot find a clean swing in the footage the whole buffer is analysed once,
      which is the same promise the single swing path makes.
    */
    func stopMultiCapture() {
        guard isMultiRecording else { return }
        isMultiRecording = false
        bufferCap = maxBufferedFrames
        setStartedAtMs = nil

        let snapshot = buffer
        buffer.removeAll()
        bufferedFrames = 0
        swingDetector.reset()
        swingPhase = swingDetector.phase

        multiProcessing = true
        multiSavedCount = processSet(snapshot)
        multiProcessing = false
        multiDetectedCount = 0
    }

    // Abandon a set without saving. Used when the camera or the set size
    // changes underneath it, where the footage is no longer one coherent clip.
    private func discardInFlightSet() {
        guard isMultiRecording else { return }
        isMultiRecording = false
        bufferCap = maxBufferedFrames
        setStartedAtMs = nil
        multiDetectedCount = 0
    }

    /*
      Cut a set buffer into clips and push each through the ordinary pipeline.

      Each clip is analysed exactly as a single capture is, which is what keeps
      a swing from a set and a swing on its own scored identically. createdAt is
      offset by the swing's own position in the recording, so the saved order
      matches the order they were hit.
    */
    private func processSet(_ snapshot: [Frame]) -> Int {
        guard snapshot.count >= 12 else { return 0 }

        let hand = DominantHand(rawValue: store?.settings.dominantHand ?? "right") ?? .right
        var windows = Self.splitSwingWindows(snapshot, hand: hand, maxWindows: swingTarget)

        // Nothing clean found. Rather than lose the recording, treat it as one
        // clip and let the engine report why it could not be read.
        if windows.isEmpty {
            windows = [SwingWindow(start: 0, end: snapshot.count - 1, peak: 0)]
        }

        let base = Date()
        let originMs = snapshot[0].t
        var saved = 0

        for window in windows {
            let clip = Array(snapshot[window.start...window.end])
            guard clip.count >= 12 else { continue }

            let createdAt = base.addingTimeInterval((snapshot[window.start].t - originMs) / 1000)
            let analysis = Analyze.analyseSwing(clip, dominantHand: hand)
            let record = CaptureViewModel.buildRecord(from: analysis, createdAt: createdAt)
            let framesToStore = analysis.validity?.ok == true || analysis.ok ? clip : []
            store?.recordNewSwing(record, frames: framesToStore)
            saved += 1
        }

        return saved
    }

    // MARK: Splitting a set into swings

    struct SwingWindow {
        var start: Int
        var end: Int
        var peak: Double
    }

    /*
      Find one clip per swing in a continuous recording.

      The signal is the same one the rest of the app trusts: lead hand speed. A
      swing is a single tall hump in it, separated from the next by the golfer
      walking back to the ball, which is quiet by comparison. So the algorithm
      is: threshold to find the humps, merge humps that belong to the same
      swing, then grow each one outward to the quiet on either side and add roll
      in and roll out so address and finish are inside the clip.

      Thresholds are relative to both the peak and the noise floor, for the same
      reason Phases.segment sets its onset that way: a fraction of peak alone
      misses a deliberate takeaway, and a fixed number in metres per second is
      wrong for a wedge and wrong again for a driver.
    */
    static func splitSwingWindows(_ frames: [Frame], hand: DominantHand, maxWindows: Int) -> [SwingWindow] {
        let n = frames.count
        guard n >= 12 else { return [] }

        let speeds = handSpeedSeries(frames, hand: hand)
        let peak = speeds.max() ?? 0
        // The same floor Phases.segment uses. Below it there is no swing here.
        guard peak >= 0.15 else { return [] }

        let sorted = speeds.sorted()
        let noiseFloor = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.2))]
        let fireThreshold = max(peak * 0.35, noiseFloor * 4)
        let quiet = max(peak * 0.06, noiseFloor * 1.5)

        // Contiguous runs above the firing threshold. One run is one downswing.
        var cores: [(start: Int, end: Int, peak: Double)] = []
        var i = 0
        while i < n {
            guard speeds[i] > fireThreshold else { i += 1; continue }
            var j = i
            var localPeak = speeds[i]
            while j + 1 < n && speeds[j + 1] > fireThreshold {
                j += 1
                localPeak = max(localPeak, speeds[j])
            }
            cores.append((start: i, end: j, peak: localPeak))
            i = j + 1
        }
        guard !cores.isEmpty else { return [] }

        /*
          Merge runs that are the same swing.

          The hand speed hump is not always convex: a hitch at the top or a brief
          tracking dropout can dip the trace under the threshold for a few
          frames and split one swing into two runs. Nothing under a third of a
          second apart is a separate swing, since no golfer resets and hits again
          that fast.
        */
        let mergeGapMs: Double = 350
        var merged: [(start: Int, end: Int, peak: Double)] = [cores[0]]
        for core in cores.dropFirst() {
            let previous = merged[merged.count - 1]
            if frames[core.start].t - frames[previous.end].t < mergeGapMs {
                merged[merged.count - 1] = (
                    start: previous.start,
                    end: core.end,
                    peak: max(previous.peak, core.peak)
                )
            } else {
                merged.append(core)
            }
        }

        // Grow each core out to address on one side and finish on the other.
        let preRollMs: Double = 900
        let postRollMs: Double = 1200
        var windows: [SwingWindow] = []

        for (index, core) in merged.enumerated() {
            // Never cross into a neighbouring swing. The halfway point between
            // two swings is the hard boundary.
            let lowerBound: Int
            if index == 0 {
                lowerBound = 0
            } else {
                lowerBound = (merged[index - 1].end + core.start) / 2
            }
            let upperBound: Int
            if index == merged.count - 1 {
                upperBound = n - 1
            } else {
                upperBound = (core.end + merged[index + 1].start) / 2
            }

            var start = core.start
            while start > lowerBound && speeds[start] > quiet { start -= 1 }
            let preLimit = frames[core.start].t - preRollMs
            while start > lowerBound && frames[start].t > preLimit { start -= 1 }

            var end = core.end
            while end < upperBound && speeds[end] > quiet { end += 1 }
            let postLimit = frames[core.end].t + postRollMs
            while end < upperBound && frames[end].t < postLimit { end += 1 }

            guard end - start + 1 >= 12 else { continue }
            windows.append(SwingWindow(start: start, end: end, peak: core.peak))
        }

        /*
          More humps than swings asked for.

          A set of three that yields four candidates usually picked up a practice
          swing or a waggle, and those are slower than the real thing, so the
          strongest ones are kept and put back in the order they were hit.
        */
        if windows.count > maxWindows {
            windows = Array(windows.sorted { $0.peak > $1.peak }.prefix(maxWindows))
                .sorted { $0.start < $1.start }
        }

        return windows
    }

    // Lead hand speed per frame, in metres per second, lightly smoothed. Same
    // measurement as the live readout, computed over a whole buffer instead of
    // across the last two frames.
    private static func handSpeedSeries(_ frames: [Frame], hand: DominantHand) -> [Double] {
        let sides = Landmarks.sides(hand)
        var speeds = [Double](repeating: 0, count: frames.count)
        guard frames.count > 1 else { return speeds }

        for i in 1..<frames.count {
            let dt = (frames[i].t - frames[i - 1].t) / 1000
            guard dt > 1e-6,
                  sides.leadWrist < frames[i].world.count,
                  sides.leadWrist < frames[i - 1].world.count else { continue }
            let current = frames[i].world[sides.leadWrist].vec
            let previous = frames[i - 1].world[sides.leadWrist].vec
            speeds[i] = Geometry.v.dist(current, previous) / dt
        }
        speeds[0] = speeds.count > 1 ? speeds[1] : 0

        return smoothed(speeds, radius: 2)
    }

    // A short moving average. Pose jitter puts single frame spikes in the trace
    // that would otherwise read as extra swings.
    private static func smoothed(_ values: [Double], radius: Int) -> [Double] {
        guard radius > 0, values.count > radius * 2 else { return values }
        var out = values
        for i in 0..<values.count {
            let lower = max(0, i - radius)
            let upper = min(values.count - 1, i + radius)
            var sum = 0.0
            for j in lower...upper { sum += values[j] }
            out[i] = sum / Double(upper - lower + 1)
        }
        return out
    }

    // MARK: Frame handling

    private func resetTrackingState() {
        buffer.removeAll()
        bufferedFrames = 0
        recentTimestamps.removeAll()
        lastLeadWrist = nil
        handSpeed = 0
        trackedFps = 0
        detectorReady = false
        swingDetector.reset()
        swingPhase = swingDetector.phase
    }

    fileprivate func handle(person: PersonDetection?, timestampMs: Double) {
        // Measured frame rate over the last handful of frames, which is the
        // honest number, not the requested capture rate.
        recentTimestamps.append(timestampMs)
        if recentTimestamps.count > 12 { recentTimestamps.removeFirst() }
        let fps = Geometry.effectiveFps(recentTimestamps)

        var speed = 0.0
        if let person, sides.leadWrist < person.world.count {
            let wrist = person.world[sides.leadWrist].vec
            if let previous = lastLeadWrist, recentTimestamps.count >= 2 {
                let dt = (recentTimestamps[recentTimestamps.count - 1] - recentTimestamps[recentTimestamps.count - 2]) / 1000
                if dt > 1e-6 { speed = Geometry.v.dist(wrist, previous) / dt }
            }
            lastLeadWrist = wrist
        }

        if let person {
            buffer.append(Frame(t: timestampMs, world: person.world, norm: person.norm, conf: person.conf))
            if buffer.count > bufferCap { buffer.removeFirst(buffer.count - bufferCap) }
        }

        latestPersonCount = person == nil ? 0 : 1
        latestConfidence = person?.conf ?? 0
        trackedFps = Int(fps.rounded())
        handSpeed = speed
        bufferedFrames = buffer.count
        // Ready once there is a body found confidently enough to bother
        // recording. A real readiness detector also checks framing.
        detectorReady = (person?.conf ?? 0) > 0.5 && fps >= Tempo.MIN_FPS_FOR_TEMPO

        // Advance the swing detector only while a body is actually tracked. An
        // empty viewfinder must not arm the machine, or the record disc would
        // read STOP over nobody. A brief tracking dropout mid swing is
        // tolerated: only a stale arm is dropped, never an in progress swing.
        if person != nil {
            swingDetector.push(speed: speed, t: timestampMs)
        } else if swingDetector.phase == .armed {
            swingDetector.reset()
        }
        swingPhase = swingDetector.phase
        swingCount = swingDetector.swingCount

        // A set left running, pocket in hand, ends itself rather than quietly
        // dropping its first swings out of the buffer.
        if isMultiRecording {
            if let started = setStartedAtMs {
                if (timestampMs - started) / 1000 > maxSetSeconds { stopMultiCapture() }
            } else {
                setStartedAtMs = timestampMs
            }
        }
    }

    // MARK: The scoring bridge

    /*
      A confirmed swing becomes a stored record.

      The buffer is snapshotted, run through the engine, and the result mapped
      onto a SwingRecord that AppStore persists. A swing that fails validity or
      cannot be segmented is still saved, unscored, with its failure reason, so a
      recording is never silently lost.

      Runs on the main actor. onSwing fires at the end of the swing, when the
      golfer has come to rest, so the pipeline run here does not compete with an
      active swing on screen. If profiling ever shows a hitch this is the one
      place to move onto a background actor, which needs the engine value types
      marked Sendable first.
    */
    func analyseBufferedSwing() {
        let snapshot = buffer
        // The detector's own clip floor. Below this there is nothing to read.
        guard snapshot.count >= 12 else { return }

        // settings.dominantHand is stored as a string ("right" or "left"), the
        // same shape the web settings use. Resolve it to the engine enum.
        let hand = DominantHand(rawValue: store?.settings.dominantHand ?? "right") ?? .right
        let createdAt = Date()

        let analysis = Analyze.analyseSwing(snapshot, dominantHand: hand)
        let record = CaptureViewModel.buildRecord(from: analysis, createdAt: createdAt)

        // Frames are kept only when there is a body to replay later. A failed
        // capture saves its record without them.
        let framesToStore = analysis.validity?.ok == true || analysis.ok ? snapshot : []
        store?.recordNewSwing(record, frames: framesToStore)
    }

    // Map an analysis result onto the stored record shape. Delegates to
    // Analyze.buildRecord, which upload also uses, so the two producers cannot
    // drift. Capture passes its own source tag.
    private static func buildRecord(from analysis: Analyze.SwingAnalysis, createdAt: Date) -> SwingRecord {
        Analyze.buildRecord(from: analysis, createdAt: createdAt, source: "capture")
    }
}

extension CaptureViewModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds = CMTimeGetSeconds(presentationTime)
        guard seconds.isFinite else { return }
        let timestampMs = seconds * 1000

        Task { [weak self] in
            guard let self else { return }
            let people = try? await self.detect(sampleBuffer, timestampMs)
            await MainActor.run {
                self.handle(person: people?.first, timestampMs: timestampMs)
            }
        }
    }

    private nonisolated func detect(_ buffer: CMSampleBuffer, _ timestampMs: Double) async throws -> [PersonDetection] {
        try await poseProvider.detect(frame: buffer, timestampMs: timestampMs)
    }
}
