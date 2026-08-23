//
//  UploadProcessor.swift
//  Swingline
//
//  The upload to analysis pipeline, now in its two-pass Phase 2+ form. A
//  video URL goes in, a saved and analysed SwingRecord comes out, ready to
//  open in AnalysisView.
//
//  WHAT CHANGED IN THIS PASS, AND WHY
//
//  1. TWO PASSES (conflict C4 resolved as designed). Phase-aware smoothing
//     needs phases, and phases are computed from smoothed landmarks, so the
//     pipeline runs twice: pass 1 cleans and applies a provisional uniform
//     6 Hz smooth, builds the series and segments provisional phases; pass 2
//     starts again from the raw frames, cleans, optionally refines the
//     downswing crops, then applies the speed and phase SCHEDULED smoothing
//     (Task 1) and the prior. Analysis runs once, on the pass 2 output, so
//     the record's phases come from the refined data.
//
//  2. SCHEDULED SMOOTHING replaces the uniform 6 Hz filter on pass 2
//     (Task 1). Backswing stays firm around 4 to 5 Hz on the body, the
//     downswing opens to the per-joint band highs (wrists up to 15 Hz), the
//     follow through settles mid band. Uniform 6 Hz remains pass 1's filter
//     and the fallback when segmentation returns nil.
//
//  3. CROP REFINEMENT over P4 to P8 (Task 4), gated three ways: the device
//     capability check, MediaPipe actually being the backend, and phases
//     having been found. A second short-lived reader re-decodes only the
//     downswing window and a second image-mode landmarker refines elbows
//     and wrists; see CropRefinement.swift for the rules it obeys.
//
//  4. SELECTION QC (Task 2). The bounding-box area floor and the raised
//     tracking confidence already live in MediaPipePoseProvider; what is new
//     here is that the provider's selection statistics are copied onto
//     TrackingQC after the streaming pass, so a clip where the lock was
//     fought over says so.
//
//  5. The prior runs the GMM stage (Task 5) once a trained model ships,
//     inside PosePriorCorrector. The midpoint magnet (Task 3) and grip
//     fusion have both since been removed from the pipeline.
//
//  6. THE VIDEO AUDIT FIXES (Gemini vision review of two reference clips).
//     Three additions, each detailed at its implementation site:
//
//     The hand collapse guard (Video 1: knuckles collapsing onto the wrist
//     at impact). Rejection form in LandmarkCleanupEngine, on by default,
//     flags the collapsed knuckles so the gap fill bridges them from
//     healthy neighbours; reconstruction form in PosePriorCorrector as the
//     backstop. Nothing to wire here, both ride the existing calls.
//
//     The background person rules (Video 2: walker in frame). Rule 1, the
//     area ratio against the clip's own baseline golfer, and Rule 2, hard
//     torso-centroid continuity, are provider selection gates configured
//     at construction below. Rule 3, the ROI bounding mask, is opt in via
//     roiMaskEnabled, default off; see the provider's class note for why
//     (it is a pixel crop, the Tasks API takes no ROI, and video-mode
//     tracking prefers stable framing).
//
//     The finish polish (Video 1: micro-jitter through the finish hold).
//     A zero-phase EMA final pass on pass 2's smoothing, speed gated so
//     impact is untouched, on by default behind finishPolishEnabled.
//
//  7. THE ONFORM PARITY PASS (final accuracy overhaul, Gemini analysis of
//     the benchmark). Four integration points, each detailed at its site:
//
//     Occlusion RTS smoothing (Fix 2) runs between cleanup plus crop
//     refinement and the scheduled smoothing, so the Butterworth receives
//     a track whose occluded stretches are already plausible trajectories
//     instead of teleports it would smear.
//
//     The torso constraints (Fix 1) and the ground plane (Fix 4) ride
//     inside PosePriorCorrector, in its documented order.
//
//     The midpoint magnet (Fix 5) no longer writes into the skeleton: the
//     corrector instance is now held so its lead hand path anchor can be
//     handed to HandPathBuilder.
//
//     The hand path gate (Fix 3) is computed here, once, after the final
//     phases exist, and travels on Result.handPath, so the overlay's job
//     is rendering rather than deciding. Club head smoothing (Fix 6) is
//     the one parity piece NOT wired here: the club path is assembled in
//     TrackingLayers at render time, and ClubHeadPathSmoother in
//     AdaptiveSmoothing.swift is its one-line call.
//
//  WHY THIS STILL DOES NOT TOUCH THE CAMERA
//
//  The live path streams sample buffers off the capture session and needs
//  causal filtering (One Euro) because the future is unknown. None of that
//  changes here. CaptureViewModel is not modified by this file. (Grip
//  fusion, which the live path used to do at detection time, has been
//  removed from the providers themselves; that change lives in
//  MediaPipePoseProvider and VisionPoseProvider, not here.)
//
//  House rule: no em dashes anywhere.
//

import Foundation
import AVFoundation
import CoreGraphics
import CoreImage

enum UploadError: LocalizedError {
    case notReadable
    case tooLong(seconds: Int)
    case noFrames
    case noPerson

    var errorDescription: String? {
        switch self {
        case .notReadable:
            return "That video could not be read."
        case .tooLong(let seconds):
            return "That clip is \(seconds) seconds. The limit is \(UploadProcessor.maxSeconds), because tracking reads every frame of the whole video and longer clips will not finish on a phone. Trim it to the swing and try again."
        case .noFrames:
            return "No frames could be read from that clip."
        case .noPerson:
            return "No golfer was found in that clip. Make sure the whole body is in frame."
        }
    }
}

enum UploadProcessor {

    /// Effective sampling ceiling. Native fps passes straight through; 120
    /// and 240 fps slow motion is decimated down to this.
    static let targetFps: Double = 60

    /// Thirty seconds, down from the web build's ninety. The new path reads
    /// every frame at up to 60 fps, so the frame budget of a 30 second clip
    /// already exceeds the old path's budget for a 90 second one, and a
    /// single swing does not need half a minute.
    static let maxSeconds: Int = 30

    /// The uniform grid the post-processing runs on. PoseTimeline caps this
    /// at the clip's own measured rate so no frame is invented.
    static let gridHz: Double = 60

    /// Phase 4 gate for the crop refinement tier. On by default; the device
    /// capability check inside CropRefinementPass is the real gate, this is
    /// the switch for QA to isolate the pass when diffing results.
    static var cropRefinementEnabled = true

    /// The finish polish (Video 1 audit): a zero-phase, speed-gated EMA
    /// final pass over pass 2's smoothed channels, which removes the
    /// finish-hold micro-jitter without touching impact. On by default;
    /// the switch exists so QA can diff with and without.
    static var finishPolishEnabled = true

    /// Rule 3 of the Video 2 audit, the ROI bounding mask. Off by default
    /// on purpose: rules 1 and 2 already make a lock swap structurally
    /// impossible, and the mask trades a little video-mode tracking
    /// stability (framing changes between frames) for its hard guarantee.
    /// Flip on for clips where background people are a real problem and
    /// diff the results.
    static var roiMaskEnabled = false

    /// Invisible contrast enhancement of the DETECTOR INPUT only (dark clothing
    /// on dark backgrounds, backlit clips, same luminance confusion). On by
    /// default: it strictly widens the luminance band the detector reads and is
    /// geometry preserving, so it cannot move a landmark, only help one be
    /// found. The switch exists so QA can diff a clip with it off. Shared by the
    /// MediaPipe provider, the crop refinement pass, and the Vision fallback, so
    /// every surface that reaches a detector is covered by one instance. See
    /// ImagePreprocessing.swift.
    static var contrastEnhancementEnabled = true

    struct Result {
        var record: SwingRecord
        /// The refined frames: the playback, overlay and export currency.
        var frames: [Frame]
        /// The detector's untouched output, for QA diffing and honest dataset
        /// inputs. Not persisted with the record.
        var rawFrames: [Frame]
        /// What the pipeline saw and what it changed.
        var qc: TrackingQC
        /// The gated hand path (Fix 3), one sample per refined frame, with
        /// the velocity and phase start and stop already decided. The
        /// overlay draws the active samples and computes nothing.
        var handPath: [HandPathSample]
        /*
          Round five (P0). The address window this clip was measured
          against, in clip milliseconds, or nil when no usable window was
          found. Travels out so the 3D view can build its SwingAnchor from
          the same known-good frames the corrector used, instead of from
          clip extremes that one residual bad frame can set. Not persisted
          on SwingRecord: it is a property of this processing run, and
          adding it to the stored record would need a schema migration for
          no benefit the view cannot get from here.
        */
        var addressReference: AddressReference?
        // The stable clip to keep with the swing, so analysis can play it back.
        var video: URL
        /*
          A 4:3 tile cropped from a frame of the clip, written to a temporary
          file for the store to move into the swing's slot. Nil when the grab
          failed, in which case the store falls back to the tracked skeleton.
        */
        var thumbnail: URL?
    }

    // MARK: - Entry point

    /*
      Extract, clean, analyse, and build a record. Runs off the main actor:
      decoding and pose detection are heavy and the caller awaits this from a
      background Task.

      model is the AppSettings.model value ("lite" / "full" / "heavy"). The
      caller passes settings.model through; the default is full, the roadmap's
      choice for offline work where accuracy beats latency.

      progress is called with a 0 to 1 fraction as work proceeds, so the UI
      can show something during what may be many seconds of work.
    */
    static func processUploadedVideo(
        videoURL: URL,
        dominantHand: DominantHand,
        model: String = "full",
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Result {

        // ---- 1. Frame source: sequential decode, validated limits ---------

        let source = try await UploadFrameSource(
            url: videoURL, maxFps: targetFps, maxSeconds: maxSeconds
        )

        // One enhancer for the whole clip, shared by the provider, the crop
        // pass, and the Vision fallback below. Nil when disabled, which every
        // consumer reads as "behave exactly as before". Upload preset: full
        // strength, since this path is offline.
        let enhancer: PoseImageEnhancer? = contrastEnhancementEnabled
            ? PoseImageEnhancer(config: .upload)
            : nil

        // ---- 2. Backend: MediaPipe VIDEO mode, Vision as fallback ---------

        let useMediaPipe = MediaPipePoseProvider.isModelAvailable(settingsModel: model)
        let provider: MediaPipePoseProvider? = useMediaPipe
            ? MediaPipePoseProvider(
                settingsModel: model,
                orientation: source.orientation,
                // Three candidates per frame so the provider's golfer
                // selection has someone to choose among when a person walks
                // through the background. Tracking confidence raised so a
                // weak lock is dropped and re-detected rather than coasted
                // on. Detection confidence stays at the model's 0.5 ON
                // PURPOSE; the 0.7 bar and the bounding-box area floor both
                // live at the selection layer, where a largest-person
                // fallback can exist. See the recorded brief correction in
                // MediaPipePoseProvider.
                numPoses: 3,
                minTrackingConfidence: 0.7,
                // The Video 2 audit rules, detailed in the provider's class
                // note. Rule 1: nobody under 35 percent of this clip's own
                // baseline golfer (median of the first 5 picks) can win the
                // real tiers. Rule 2: nobody whose torso centroid jumped
                // more than 0.15 normalised per frame step can either.
                // Rule 3 is the ROI pixel-crop mask, behind its switch.
                areaRatioFloor: 0.35,
                baselineFrameCount: 5,
                maxCentroidJumpPerStep: 0.15,
                roiEnabled: roiMaskEnabled,
                roiMargin: 0.15,
                enhancer: enhancer
              )
            : nil
        if !useMediaPipe {
            print("[Upload] MediaPipe model \"\(model)\" not in bundle; falling back to Apple Vision")
        }
        defer { provider?.close() }

        // ---- 3. One streaming pass: decode, detect, collect ---------------

        var raw: [Frame] = []
        var lastTs = -1.0
        for try await sourced in source.frames() {
            try Task.checkCancellation()

            // MediaPipe's video mode requires strictly increasing integer
            // milliseconds. The source guarantees increasing doubles; this
            // guarantees the integer form after rounding.
            let ts = max(lastTs + 1, sourced.timestampMs.rounded())
            lastTs = ts

            let detections: [PersonDetection]
            if let provider {
                detections = (try? await provider.detect(frame: sourced.buffer, timestampMs: ts)) ?? []
            } else {
                detections = visionDetections(from: sourced.buffer, orientation: source.cgOrientation, enhancer: enhancer)
            }

            if let person = detections.first {
                raw.append(Frame(
                    t: ts,
                    world: person.world,
                    norm: person.norm,
                    conf: person.conf,
                    people: detections
                ))
            }
            progress(0.58 * sourced.fraction)
        }

        guard !raw.isEmpty else { throw UploadError.noFrames }
        // A handful of frames with a body is the floor below which nothing
        // can be read. Matches the detector clip floor on the live path.
        guard raw.count >= 12 else { throw UploadError.noPerson }

        // ---- 4. QC bookkeeping, including what selection did (Task 2) -----

        var qc = TrackingQC()
        qc.backend = useMediaPipe ? "mediapipe" : "vision"
        qc.model = useMediaPipe ? model : ""
        qc.framesIn = raw.count
        qc.effectiveFps = source.effectiveFps

        if let provider {
            let s = provider.selectionStats()
            qc.framesWithMultipleCandidates = s.framesWithMultipleCandidates
            qc.backgroundCandidatesExcluded = s.subFloorCandidatesExcluded
            qc.selectionFallbackFrames = s.largestPersonFallbacks + s.lastResortPicks
            if s.framesSeen > 0 { qc.golferAreaMean = ((s.golferAreaSum / Double(s.framesSeen)) * 1000).rounded() / 1000 }
            qc.golferAreaMin = s.golferAreaMin.isFinite ? (s.golferAreaMin * 1000).rounded() / 1000 : 0
            // The Video 2 audit rules (new TrackingQC fields, see the
            // integration notes): what each gate rejected, the baseline
            // they judged against, and how often the ROI mask actually
            // cropped. All zero on a clean one-golfer clip, which is the
            // hoped-for reading.
            qc.candidatesRejectedByAreaRatio = s.areaRatioRejected
            qc.candidatesRejectedByContinuity = s.continuityRejected
            qc.golferBaselineArea = (s.baselineGolferArea * 1000).rounded() / 1000
            qc.roiCroppedFrames = s.roiCroppedFrames
        }

        // ---- 5. PASS 1: provisional smooth, provisional phases (C4) -------

        // The pass 1 QC is scratch: everything it would record is recorded
        // again, for real, by the pass 2 run on the same raw frames.
        var scratchQC = TrackingQC()
        var pass1 = PoseTimeline(frames: raw, resampleHz: gridHz)
        LandmarkCleanupEngine().run(&pass1, qc: &scratchQC)
        progress(0.64)
        TemporalSmoothingService.uniform(cutoffHz: 6).run(&pass1)
        progress(0.68)

        let provisional = pass1.frames()
        let provisionalSeries = Biomechanics.buildSeries(provisional, dominantHand)
        let provisionalPhases = Phases.segment(provisionalSeries, provisional)

        // ROUND FIVE (P0). The address window, captured ONCE here from the
        // provisional hand speed and phases, then handed to every consumer
        // that needs a known-good reading of this golfer's body: the
        // corrector's body constants and the humanoid anchor's floor and
        // height. Nil for a clip that starts mid-takeaway, in which case
        // every consumer falls back to its clip statistics and the
        // pipeline behaves exactly as it did in round four.
        let addressReference = captureAddressReference(
            handSpeed: provisionalSeries.handSpeed,
            times: provisionalSeries.t,
            phases: provisionalPhases
        )
        if let addressReference {
            qc.addressReferenceFrames = addressReference.frameCountAtCapture
            qc.addressReferenceStillness = addressReference.stillness
        }
        progress(0.72)

        // ---- 6. PASS 2: re-clean from raw, refine, final smooth, prior ----

        var timeline = PoseTimeline(frames: raw, resampleHz: gridHz)
        LandmarkCleanupEngine().run(&timeline, qc: &qc)
        progress(0.76)

        // TASK 4. The optional accuracy tier: crop refinement over the
        // downswing window, on capable devices, when MediaPipe carried the
        // clip and the provisional phases exist to name the window.
        if cropRefinementEnabled, useMediaPipe,
           CropRefinementPass.isDeviceCapable(),
           let phases = provisionalPhases,
           let p4 = phases.idx[.p4], let p8 = phases.idx[.p8],
           p4 < provisionalSeries.t.count, p8 < provisionalSeries.t.count, p8 > p4,
           let clipStartPtsMs = await source.firstSamplePtsMs(),
           let cropPass = CropRefinementPass(
               asset: source.asset,
               track: source.track,
               cgOrientation: source.cgOrientation,
               settingsModel: model,
               enhancer: enhancer
           ) {
            let window = provisionalSeries.t[p4]...provisionalSeries.t[p8]
            cropPass.run(
                &timeline, qc: &qc,
                windowMs: window,
                clipStartPtsMs: clipStartPtsMs,
                progress: { f in progress(0.76 + 0.08 * f) }
            )
        }
        progress(0.84)

        // FIX 2 (OnForm parity). Occlusion window RTS smoothing, BEFORE the
        // Butterworth on purpose: a DTL lead arm teleport is broadband, and
        // a low pass run over it smears it into the neighbouring honest
        // samples, while the window smoother replaces it with the coasted
        // and back-corrected trajectory the surrounding measurements imply.
        // Inert on clips with no sub-0.3 visibility runs, and on the Vision
        // backend, which reports no visibility at all.
        OcclusionRTSSmoother().run(&timeline, qc: &qc)
        progress(0.86)

        // TASK 1. Speed and phase scheduled smoothing when phases exist,
        // the honest uniform fallback when they do not. The finish polish
        // (Video 1 audit) rides on either as an optional zero-phase,
        // speed-gated EMA final pass; the smoothing mode string says when
        // it ran, so QC output stays self-describing without a new field.
        let polish: TemporalSmoothingService.FinalPassConfig? =
            finishPolishEnabled ? TemporalSmoothingService.FinalPassConfig() : nil
        if provisionalPhases != nil {
            qc.smoothingMode = polish != nil ? "scheduled+ema" : "scheduled"
            qc.scheduledCutoffLowHz = 4
            qc.scheduledCutoffHighHz = 15
            TemporalSmoothingService.scheduled(
                handSpeed: provisionalSeries.handSpeed,
                times: provisionalSeries.t,
                phases: provisionalPhases,
                finalPass: polish
            ).run(&timeline)
        } else {
            qc.smoothingMode = polish != nil ? "uniform+ema" : "uniform"
            TemporalSmoothingService.uniform(cutoffHz: 6, finalPass: polish).run(&timeline)
        }
        progress(0.88)

        // TASK 5, the torso constraints (Fix 1), the shoulder occlusion
        // projection (Fix S) and the ground plane (Fix 4) all ride inside
        // the corrector. Grip fusion is gone from the pipeline, so the
        // corrector no longer collapses the two wrists into a grip; both
        // wrists reach the refined frames as measured, and the hand path
        // below reads the lead wrist straight from them.
        let corrector = PosePriorCorrector.analytic(dominantHand: dominantHand)
        // Round five: the address reference rides in here. The two-argument
        // spelling still exists and still self-classifies with no reference,
        // so any caller that lags this commit is unaffected.
        corrector.run(&timeline, qc: &qc, reference: addressReference)
        corrector.enforceGroundBackstop(&timeline, qc: &qc)
        progress(0.90)

        let refined = timeline.frames()

        // ---- 7. The one orchestrator, unchanged, on refined frames --------

        let analysis = Analyze.analyseSwing(refined, dominantHand: dominantHand)
        let record = Analyze.buildRecord(from: analysis, createdAt: Date(), source: "upload")
        progress(0.94)

        // Per-phase confidence for the QC badge. Segmented independently of
        // Analyze's internals, from the same refined frames, using the same
        // series builder, so the two cannot disagree about what a phase is.
        let series = Biomechanics.buildSeries(refined, dominantHand)
        let finalPhases = Phases.segment(series, refined)
        if let phases = finalPhases {
            qc.fillPhaseConfidence(frames: refined, phases: phases)
        }
        qc.gridFrames = refined.count

        // FIX 3 (OnForm parity). The hand path, gated by velocity and phase,
        // built once from the refined frames and the FINAL phases so the P8
        // its stop condition reads is the P8 the record reports. Positions
        // come from the lead wrist slot of those refined frames; with grip
        // fusion removed that slot is the measured lead wrist rather than a
        // fused grip. The gate's verdict lands in QC.
        let handPath = HandPathBuilder.build(
            frames: refined,
            phases: finalPhases,
            dominantHand: dominantHand,
            qc: &qc
        )

        // Fire and forget: the dataset that unblocks the learned priors
        // (Task 5) keeps accumulating from every shipped upload. After the
        // hand path build, so the gate's QC fields ride along.
        SwingDatasetLogger.log(frames: refined, qc: qc, source: "upload")

        let thumbnail = await thumbnail(asset: source.asset, frames: refined)
        progress(1)

        return Result(
            record: record,
            frames: refined,
            rawFrames: raw,
            qc: qc,
            handPath: handPath,
            addressReference: addressReference,
            video: videoURL,
            thumbnail: thumbnail
        )
    }

    /// The old entry point, forwarding to the new pipeline so existing call
    /// sites keep compiling while they migrate to the richer signature.
    @available(*, deprecated, renamed: "processUploadedVideo(videoURL:dominantHand:model:progress:)")
    static func process(
        videoURL: URL,
        dominantHand: DominantHand,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Result {
        try await processUploadedVideo(
            videoURL: videoURL, dominantHand: dominantHand, progress: progress
        )
    }

    // MARK: - Address reference capture (round five)

    /*
      The address window, from the provisional pass. See AddressReference
      in CoreTypes for what it is and why the pipeline wants it.

      The run is anchored to the TAKEAWAY and walked backward, rather than
      taken as the longest still run in the clip. That matters: a golfer
      who holds the finish produces a still run at the end of the clip
      which is often longer than the address run, and it describes the
      finish pose. Only the frames immediately before the club moves
      describe the pose the swing starts from.

      Returns nil for a clip that starts mid-takeaway, a clip with no
      measurable hand speed, or a window too short to carry a median. In
      every one of those cases each consumer falls back to its clip
      statistics and the pipeline behaves exactly as it did in round four.
    */
    private static func captureAddressReference(
        handSpeed: [Double],
        times: [Double],
        phases: PhaseResult?,
        config: AddressReference.CaptureConfig = AddressReference.CaptureConfig()
    ) -> AddressReference? {
        let n = Swift.min(handSpeed.count, times.count)
        guard n >= 12 else { return nil }
        guard let peak = handSpeed.prefix(n).max(), peak > 1e-6 else { return nil }

        let stillBar = config.maxSpeedFraction * peak
        let moveBar = config.takeawaySpeedFraction * peak

        // Where the search ends: P1 when phases found one, otherwise the
        // frame before the club first moves, otherwise the clip end.
        var end = n - 1
        if let p1 = phases?.idx[.p1], p1 > 0, p1 < n {
            end = p1
        } else if let firstMove = (0..<n).first(where: { handSpeed[$0] > moveBar }), firstMove > 0 {
            end = firstMove - 1
        }
        guard end > 0 else { return nil }

        // The still run ending at (or just before) the takeaway. A single
        // frame of noise inside an otherwise still stretch would truncate
        // the run, so one frame over the bar is tolerated as long as its
        // neighbours are under it: at 60 Hz a lone spike is a tracking
        // artefact, not the golfer starting the swing.
        func still(_ i: Int) -> Bool { handSpeed[i] < stillBar }
        var last = end
        while last > 0, !still(last) { last -= 1 }
        guard still(last) else { return nil }

        var first = last
        while first > 0 {
            let candidate = first - 1
            if still(candidate) {
                first = candidate
            } else if candidate > 0, still(candidate - 1) {
                // One-frame excursion inside the run: step over it.
                first = candidate - 1
            } else {
                break
            }
        }

        // Trim to the last maxDurationMs, so a long settle keeps only the
        // frames that describe the address the swing starts from.
        var startMs = times[first]
        let endMs = times[last]
        if endMs - startMs > config.maxDurationMs {
            startMs = endMs - config.maxDurationMs
        }
        guard endMs - startMs >= config.minDurationMs else { return nil }

        var inside: [Double] = []
        var count = 0
        for i in first...last where times[i] >= startMs {
            inside.append(handSpeed[i])
            count += 1
        }
        guard count >= 8 else { return nil }
        inside.sort()
        let stillness = inside[inside.count / 2] / peak

        return AddressReference(
            startMs: startMs,
            endMs: endMs,
            stillness: (stillness * 1000).rounded() / 1000,
            frameCountAtCapture: count
        )
    }

    // MARK: - Vision fallback

    /// Shared CoreImage context for the fallback conversion. Cheap to hold,
    /// expensive to recreate per frame.
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /*
      Bridge a decoded sample buffer to the CGImage entry Vision's static
      detect expects, applying the clip's rotation so the golfer is upright,
      which is what the old generator path (appliesPreferredTrackTransform)
      always delivered. Slower than the MediaPipe path by the cost of one
      render per frame, which is acceptable for a fallback.
    */
    private static func visionDetections(
        from buffer: CMSampleBuffer,
        orientation: CGImagePropertyOrientation,
        enhancer: PoseImageEnhancer?
    ) -> [PersonDetection] {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return [] }
        var ci = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        // Fuse the enhancement into the createCGImage render this path already
        // does, so it costs nothing extra. Geometry preserving, so the
        // normalised image points Vision returns are unchanged in meaning.
        if let enhancer { ci = enhancer.enhanced(ci, roiNormalize: false) }
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return [] }
        return (try? VisionPoseProvider.detect(cgImage: cg)) ?? []
    }

    // MARK: - Thumbnail

    /*
      One 4:3 tile for the swing, taken from the middle of the tracked frames
      rather than the middle of the clip: half of a file's duration lands in
      the setup dead air as often as on the swing, but halfway through the
      frames that actually held a body is somewhere in the swing itself.

      This is the one remaining use of AVAssetImageGenerator on this path,
      and rightly so: a single accurate seek is exactly what a generator is
      for, it is sequential reading that it was the wrong tool for.
    */
    private static func thumbnail(asset: AVURLAsset, frames: [Frame]) async -> URL? {
        guard !frames.isEmpty else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)

        let midMs = frames[frames.count / 2].t
        let time = CMTime(seconds: midMs / 1000.0, preferredTimescale: 600)
        guard let cgImage = try? await copyImage(generator, at: time) else { return nil }
        return SwingThumbnail.makeFile(from: cgImage)
    }

    private static func copyImage(_ generator: AVAssetImageGenerator, at time: CMTime) async throws -> CGImage {
        let (image, _) = try await generator.image(at: time)
        return image
    }
}
