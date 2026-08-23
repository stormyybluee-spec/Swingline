import Foundation
import CoreMedia
import CoreImage
import UIKit
import MediaPipeTasksVision

/*
  Camera view of the golfer, inferred per frame from shoulder geometry.

  faceOn        the camera looks at the golfer's chest. Both shoulders sit at
                roughly the same distance from the lens, so their world-space z
                values are close together.
  downTheLine   the camera looks along the target line, at the golfer's side.
                The shoulders are separated in depth, so their z values differ.

  The view distinction survives the removal of grip fusion because other files
  still read it (the overlay's face-on versus down-the-line handling among
  them). The classifier that computes it now lives in SwingViewClassifier in
  PosePrior.swift; this enum stays here because it is the provider that first
  needed the distinction and other files may already name it.
*/
enum SwingView {
    case faceOn
    case downTheLine
}

class MediaPipePoseProvider: PoseProvider {

    /// The MediaPipe 33-slot contract from Landmarks.swift. Every LandmarkSet
    /// this provider returns has exactly this many entries, with untracked
    /// slots holding a zero placeholder at visibility 0, matching what
    /// VisionPoseProvider.emptySet() does on the other backend.
    static let slotCount = 33

    private var poseLandmarker: PoseLandmarker?

    /// Bare resource name WITHOUT extension, plus its extension, kept separate so
    /// Bundle lookups can use the (name, ext) form that actually works reliably.
    private let modelName: String
    private let modelExt: String

    /*
      How the pixel data in incoming sample buffers is rotated relative to
      upright. The live camera path delivers buffers that are already the way
      the session was configured, so it keeps the .up default and nothing
      changes. The upload path reads buffers straight off AVAssetReader, which
      does NOT apply the track's preferredTransform, so a portrait phone clip
      arrives sideways; UploadFrameSource computes the right orientation from
      the transform and passes it here, and MediaPipe rotates internally before
      detecting. Landmarks come back in upright normalised space either way.
    */
    private let orientation: UIImage.Orientation

    /*
      Golfer selection, and why it exists.

      With numPoses at 1, MediaPipe picks the one person itself, and on a clip
      where somebody walks through the background its pick sometimes jumps to
      the walker: mid-swing the golfer is blurred and contorted, the walker is
      upright and canonical, and video-mode tracking then stays locked on the
      wrong person. Nothing downstream can fix that, because downstream only
      ever receives the one pose MediaPipe chose.

      So the upload path asks for several candidates (numPoses 3) and this
      file chooses, per frame:

        1. Candidates below the minimum bounding-box area floor
           (minPersonAreaFraction of the frame) are background people by
           definition and cannot win selection at all. Without this floor
           there was one losing path left: the golfer blurred and contorted
           mid-swing drops below the visibility bar, a small distant walker
           standing still clears it, and the walker wins the confident
           competition outright, after which the continuity weight keeps the
           lock on them. The area floor closes that path: a person occupying
           under five percent of the frame never enters the competition, so
           the blurred golfer still wins through the largest-person fallback.
        2. Candidates above the floor whose mean core-joint visibility clears
           minSelectionConfidence compete first.
        3. Among competitors, the score is bounding-box area times a
           continuity weight toward the previously selected person, so the
           near, large golfer beats a distant walker and a one-frame flicker
           cannot steal the lock.
        4. If nobody clears the visibility bar (heavy blur at impact), the
           largest above-floor candidate wins as the fallback, because in a
           swing clip the golfer is overwhelmingly the largest person in it.
        5. If nobody clears even the area floor (golfer filmed from very far
           away), the largest candidate by area wins regardless. A floor that
           could reject every person in the clip would turn a wide framing
           into a hard failure, which is worse than a rough track.

      THE VIDEO 2 AUDIT RULES, layered on top of the tiers above. The clip
      with the background walker (red shirt, far left, 0.6 percent of the
      frame) held its lock, but the audit named three rules that make a
      future swap structurally impossible rather than merely unlikely:

        6. AREA RATIO (Rule 1). The golfer's baseline bounding-box area is
           the median over the first baselineFrameCount selected frames of
           the clip. From then on, a candidate whose area is below
           areaRatioFloor times that baseline (0.35 by default) is a
           background person BY THIS CLIP'S OWN MEASURE and cannot win the
           confident or eligible tiers, whatever the static
           minPersonAreaFraction floor says. The walker at 0.6 percent
           against a 21.6 percent golfer fails this at 36 to 1.
        7. CENTROID CONTINUITY (Rule 2). A candidate whose torso centroid
           sits more than maxCentroidJumpPerStep (0.15 normalised) from
           where the selected golfer was on the previous detection cannot
           win the real tiers either. Two refinements over the brief's
           bare rule, recorded so they are not mistaken for oversights:
           the centroid is the mean of shoulders and hips rather than the
           bounding-box centre, because the box centre swings with the
           arms mid-swing and would false-trigger the gate on the golfer
           themself; and the allowance scales with the elapsed time since
           the last detection (capped at four nominal steps, inert past
           continuityStaleMs), because the 0.15 figure is per CONSECUTIVE
           frame and a detection gap must widen it or a briefly lost
           golfer could be rejected by their own rule.
        8. ROI BOUNDING MASK (Rule 3), opt in via roiEnabled. Detection is
           physically constrained to the golfer's box expanded by
           roiMargin, so a background person outside it is never even
           seen. A CORRECTION TO THE BRIEF, recorded here: the Tasks-API
           PoseLandmarker does not accept a regionOfInterest. Its iOS
           detect calls take no ImageProcessingOptions at all, and the
           pose graph rejects the ROI field on the platforms where the
           options do exist. So the mask is implemented the only way it
           can be, as a pixel crop: the incoming buffer is cropped to the
           tracked box (grow fast, shrink slow, so a fast hand is never
           clipped at the edge), MediaPipe detects on the crop, and the
           landmarks are remapped into full-frame coordinates before
           anything downstream sees them, so selection metrics, the
           baseline area and every consumer keep one coordinate system.
           Default OFF: video-mode tracking carries state between frames
           and prefers a stable framing, so the mask is a tool for clips
           where background people are a real problem, not a default.
           When a cropped frame loses everyone the mask resets and the
           next frame searches the whole image, so a golfer who outruns
           a stale box costs one frame, not the clip.

      Rules 6 and 7 exclude from SELECTION exactly the way the area floor
      does, and only when numPoses is greater than 1, so the live path is
      untouched. Excluded candidates are never deleted: all of them still
      travel on Frame.people after the golfer, so QA diffing can see
      exactly who else the detector found and confirm the right person
      won. When every candidate in a frame fails the gates, the
      last-resort tier still yields a golfer, the anchor moves to them so
      a genuine scene change recovers, but the baseline is not fed and
      the ROI resets.

      A CORRECTION TO THE PHASE 2 BRIEF, recorded so it is not mistaken for
      an oversight. The brief asks for minPoseDetectionConfidence raised from
      0.5 to 0.7 for uploads. Raising it INSIDE the model would discard weak
      candidates before this selection ever sees them, and the largest-person
      fallback would have nothing to fall back to. Mid-swing the golfer is
      blurred and contorted and IS the weak candidate; a 0.7 model-level gate
      deletes the golfer at exactly the frames this project exists to
      measure. So the 0.7 bar lives HERE, as minSelectionConfidence, where a
      fallback can exist, and the model keeps 0.5. The knob is now exposed on
      the initialiser for callers who insist, but the upload path should not
      raise it. Tracking confidence IS raised at the model level for uploads
      (passed as 0.7), so the tracker drops a weak lock and re-detects rather
      than coasting on the wrong person.

      The live path constructs with numPoses 1 as before, selection reduces
      to a pass-through, and nothing about capture changes.
    */
    private let numPoses: Int
    private let minTrackingConfidence: Double
    private let minSelectionConfidence: Double
    private let minPoseDetectionConfidence: Double
    /*
      Minimum bounding-box area, as a fraction of the frame, for a candidate
      to be eligible for selection. 0.05 means a person must occupy at least
      five percent of the frame to be considered the golfer. Inert on the
      live path: with numPoses 1 selection is a pass-through and the floor is
      never evaluated, so capture behaviour is unchanged whatever this holds.
    */
    private let minPersonAreaFraction: Double

    /*
      Rule 1 of the Video 2 audit. Candidates below areaRatioFloor times the
      clip's own baseline golfer area cannot win the real selection tiers.
      The baseline is the median selected-golfer area over the first
      baselineFrameCount frames that produced a pick, so a walker cannot
      poison it by arriving later. Inert until the baseline exists and
      always inert on the live path (numPoses 1).
    */
    private let areaRatioFloor: Double
    private let baselineFrameCount: Int

    /*
      Rule 2 of the Video 2 audit. A candidate whose torso centroid jumped
      more than maxCentroidJumpPerStep normalised units per nominal frame
      step since the last selection cannot win the real tiers. The
      allowance scales with elapsed time (capped at four steps) and the
      gate goes inert once the anchor is older than continuityStaleMs, so
      a detection gap cannot reject the whole field. See the class note.
    */
    private let maxCentroidJumpPerStep: Double
    private let continuityStaleMs: Double

    /*
      Rule 3 of the Video 2 audit, the ROI bounding mask, implemented as a
      pixel crop because the Tasks-API PoseLandmarker takes no ROI. See
      the class note for the full reasoning and the recorded correction.
    */
    private let roiEnabled: Bool
    private let roiMargin: Double

    /*
      Invisible contrast enhancement for the detector input. Nil means the layer
      is off and the provider behaves exactly as before, which is the live
      path's default so capture is unchanged until a caller opts in. When set,
      the full frame path renders an enhanced copy into a fresh buffer and the
      ROI crop path fuses the enhancement into the crop render it already does.
      Geometry preserving, so no landmark coordinate or ROI remap changes. See
      ImagePreprocessing.swift.
    */
    private let enhancer: PoseImageEnhancer?

    private var lastSelectedCenter: (x: Double, y: Double)?
    private var lastSelectedTimestampMs: Double?
    /// Running estimate of the detection cadence, for scaling the
    /// continuity allowance across detection gaps. Starts at 60 fps.
    private var typicalStepMs: Double = 1000.0 / 60.0
    /// Selected-golfer areas collected until the baseline is established.
    private var baselineSamples: [Double] = []
    private var baselineArea: Double?
    /// The tracked mask in upright normalised space, nil when disengaged.
    private var roiRect: CGRect?
    private lazy var roiContext = CIContext(options: [.cacheIntermediates: false])

    var maxPeople: Int { numPoses }

    // MARK: - Selection statistics (Task 2 QC)

    /*
      What selection actually did across the clip, so TrackingQC can carry it
      and a QA eye can tell "one golfer, cleanly held" from "the lock was
      fought over". Accumulated on the detect call path, which the upload
      loop drives sequentially, so there is no concurrent mutation.
    */
    struct SelectionStats {
        var framesSeen = 0
        var framesWithMultipleCandidates = 0
        var subFloorCandidatesExcluded = 0
        var confidentPicks = 0
        var largestPersonFallbacks = 0
        var lastResortPicks = 0
        var golferAreaSum = 0.0
        var golferAreaMin = Double.infinity
        /// Rule 1 exclusions: candidates below areaRatioFloor of baseline.
        var areaRatioRejected = 0
        /// Rule 2 exclusions: torso centroid jumped past the allowance.
        var continuityRejected = 0
        /// Frames where Rule 3 actually cropped before detection.
        var roiCroppedFrames = 0
        /// The clip's baseline golfer area once established, 0 until then.
        var baselineGolferArea = 0.0
    }

    private var stats = SelectionStats()

    /// A snapshot of what selection did so far. The upload processor copies
    /// this into TrackingQC after the streaming pass.
    func selectionStats() -> SelectionStats { stats }

    /// Accepts either a bare name ("pose_landmarker_lite") or a full filename
    /// ("pose_landmarker_lite.task"). The extension is split off so Bundle
    /// lookups always get the (name, ext) pair, which is the form iOS matches
    /// most reliably. Defaults to the lite model that ships in Resources, so
    /// existing call sites (CaptureViewModel's default construction included)
    /// are unchanged.
    init(
        modelFileName: String = "pose_landmarker_lite.task",
        orientation: UIImage.Orientation = .up,
        numPoses: Int = 1,
        minTrackingConfidence: Double = 0.5,
        minSelectionConfidence: Double = 0.7,
        minPersonAreaFraction: Double = 0.05,
        minPoseDetectionConfidence: Double = 0.5,
        areaRatioFloor: Double = 0.35,
        baselineFrameCount: Int = 5,
        maxCentroidJumpPerStep: Double = 0.15,
        continuityStaleMs: Double = 600,
        roiEnabled: Bool = false,
        roiMargin: Double = 0.15,
        enhancer: PoseImageEnhancer? = nil
    ) {
        let ns = modelFileName as NSString
        let ext = ns.pathExtension
        if ext.isEmpty {
            self.modelName = modelFileName
            self.modelExt = "task"
        } else {
            self.modelName = ns.deletingPathExtension
            self.modelExt = ext
        }
        self.orientation = orientation
        self.numPoses = max(1, numPoses)
        self.minTrackingConfidence = minTrackingConfidence
        self.minSelectionConfidence = minSelectionConfidence
        self.minPersonAreaFraction = max(0, minPersonAreaFraction)
        self.minPoseDetectionConfidence = min(max(minPoseDetectionConfidence, 0), 1)
        self.areaRatioFloor = max(0, areaRatioFloor)
        self.baselineFrameCount = max(1, baselineFrameCount)
        self.maxCentroidJumpPerStep = max(0, maxCentroidJumpPerStep)
        self.continuityStaleMs = max(0, continuityStaleMs)
        self.roiEnabled = roiEnabled
        self.roiMargin = max(0, roiMargin)
        self.enhancer = enhancer
        setupPoseLandmarker()
    }

    /// Construct from the AppSettings.model value ("lite" / "full" / "heavy").
    /// This is the init the upload path uses, honouring the model picker that
    /// Settings has been showing all along. An unrecognised value falls back to
    /// lite rather than crashing, since the setting is a persisted string.
    convenience init(
        settingsModel: String,
        orientation: UIImage.Orientation = .up,
        numPoses: Int = 1,
        minTrackingConfidence: Double = 0.5,
        minSelectionConfidence: Double = 0.7,
        minPersonAreaFraction: Double = 0.05,
        minPoseDetectionConfidence: Double = 0.5,
        areaRatioFloor: Double = 0.35,
        baselineFrameCount: Int = 5,
        maxCentroidJumpPerStep: Double = 0.15,
        continuityStaleMs: Double = 600,
        roiEnabled: Bool = false,
        roiMargin: Double = 0.15,
        enhancer: PoseImageEnhancer? = nil
    ) {
        self.init(
            modelFileName: Self.modelFileName(forSettingsModel: settingsModel),
            orientation: orientation,
            numPoses: numPoses,
            minTrackingConfidence: minTrackingConfidence,
            minSelectionConfidence: minSelectionConfidence,
            minPersonAreaFraction: minPersonAreaFraction,
            minPoseDetectionConfidence: minPoseDetectionConfidence,
            areaRatioFloor: areaRatioFloor,
            baselineFrameCount: baselineFrameCount,
            maxCentroidJumpPerStep: maxCentroidJumpPerStep,
            continuityStaleMs: continuityStaleMs,
            roiEnabled: roiEnabled,
            roiMargin: roiMargin,
            enhancer: enhancer
        )
    }

    // MARK: - Model selection

    /// AppSettings.model value to bundled .task filename. The three values
    /// match SettingsOptions.models and the web build's poseEngine MODELS.
    static func modelFileName(forSettingsModel model: String) -> String {
        switch model {
        case "heavy": return "pose_landmarker_heavy.task"
        case "full": return "pose_landmarker_full.task"
        case "lite": return "pose_landmarker_lite.task"
        default:
            print("[PoseProvider] Unknown model setting \"\(model)\", falling back to lite")
            return "pose_landmarker_lite.task"
        }
    }

    /*
      Pre-flight check for callers that have a fallback, which today means the
      upload pipeline: it asks this before constructing, and drops to the Vision
      backend when the bundle is missing rather than hitting the fatalError in
      setup. The live path keeps its fail-loudly behaviour on purpose: a capture
      build without its model is a broken build and should say so at once.
    */
    static func isModelAvailable(settingsModel: String) -> Bool {
        let fileName = modelFileName(forSettingsModel: settingsModel) as NSString
        return resolveModelPath(name: fileName.deletingPathExtension, ext: fileName.pathExtension) != nil
    }

    /*
      TASK 4 SUPPORT. A second, independent landmarker in IMAGE mode for the
      crop refinement pass. Image mode on purpose: video mode is stateful
      with strictly increasing timestamps, and feeding it a shifted, cropped
      frame stream would corrupt the tracker; image mode treats every frame
      as its own detection, which is exactly what a crop-and-remap pass
      needs. Two candidates so the pass can pick the person whose remapped
      wrists match the full-frame golfer when someone else strays into the
      crop. Returns nil rather than trapping when the model is absent,
      because the crop pass is an optional accuracy tier, not a requirement.
    */
    static func makeImageLandmarker(settingsModel: String, numPoses: Int = 2) -> PoseLandmarker? {
        let fileName = modelFileName(forSettingsModel: settingsModel) as NSString
        guard let path = resolveModelPath(
            name: fileName.deletingPathExtension, ext: fileName.pathExtension
        ) else {
            print("[PoseProvider] makeImageLandmarker: model \"\(settingsModel)\" not in bundle")
            return nil
        }
        let options = PoseLandmarkerOptions()
        options.baseOptions.modelAssetPath = path
        options.runningMode = .image
        options.numPoses = max(1, numPoses)
        options.minPoseDetectionConfidence = 0.5
        options.minPosePresenceConfidence = 0.5
        do {
            return try PoseLandmarker(options: options)
        } catch {
            print("[PoseProvider] makeImageLandmarker failed: \(error)")
            return nil
        }
    }

    // MARK: - Model file discovery

    /*
      Resolve an absolute filesystem path to a model, trying several methods in
      order and logging each attempt. MediaPipe's native layer needs a real
      absolute path on disk, not a bare filename, so every branch here returns
      an absolute path (or nil). Static so isModelAvailable can share it.
    */
    private static func resolveModelPath(name: String, ext: String) -> String? {
        print("[PoseProvider] ---- model file discovery ----")
        print("[PoseProvider] Looking for resource: \"\(name)\" ext: \"\(ext)\"")
        print("[PoseProvider] Bundle path:   \(Bundle.main.bundlePath)")
        print("[PoseProvider] Resource path: \(Bundle.main.resourcePath ?? "nil")")

        // 1) Bundle.main.url(forResource:withExtension:) -> absolute path.
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            let path = url.path
            print("[PoseProvider] Found via Bundle.url: \(path)")
            if FileManager.default.fileExists(atPath: path) {
                return path
            } else {
                print("[PoseProvider] WARNING: url returned but file missing on disk at \(path)")
            }
        } else {
            print("[PoseProvider] Bundle.url(forResource:withExtension:) returned nil")
        }

        // 2) Bundle.main.path(forResource:ofType:) -> absolute path.
        if let path = Bundle.main.path(forResource: name, ofType: ext) {
            print("[PoseProvider] Found via Bundle.path: \(path)")
            if FileManager.default.fileExists(atPath: path) {
                return path
            } else {
                print("[PoseProvider] WARNING: path returned but file missing on disk at \(path)")
            }
        } else {
            print("[PoseProvider] Bundle.path(forResource:ofType:) returned nil")
        }

        // 3) FileManager fallback: search the resource directory recursively in
        //    case the file was copied into a subfolder ("folder reference" /
        //    blue folder) rather than a flat group.
        if let resourcePath = Bundle.main.resourcePath {
            let fullName = "\(name).\(ext)"
            let enumerator = FileManager.default.enumerator(atPath: resourcePath)
            while let rel = enumerator?.nextObject() as? String {
                // Case-insensitive match on the last path component, to also
                // catch capitalisation mismatches.
                if (rel as NSString).lastPathComponent.compare(
                        fullName, options: .caseInsensitive) == .orderedSame {
                    let abs = (resourcePath as NSString).appendingPathComponent(rel)
                    print("[PoseProvider] Found via FileManager scan: \(abs)")
                    if FileManager.default.fileExists(atPath: abs) {
                        return abs
                    }
                }
            }
            print("[PoseProvider] FileManager scan did not find \(fullName) under resource path")
        }

        return nil
    }

    private func setupPoseLandmarker() {
        guard let path = Self.resolveModelPath(name: modelName, ext: modelExt) else {
            // Nothing worked: report every location we looked at, then fail loudly.
            let attempted = """
            Model file not found: \(modelName).\(modelExt)
            Attempted discovery:
              - Bundle.url(forResource:"\(modelName)", withExtension:"\(modelExt)")
              - Bundle.path(forResource:"\(modelName)", ofType:"\(modelExt)")
              - FileManager recursive scan of resourcePath
            Bundle path:   \(Bundle.main.bundlePath)
            Resource path: \(Bundle.main.resourcePath ?? "nil")
            Callers with a fallback should check isModelAvailable(settingsModel:) first.
            """
            print("[PoseProvider] \(attempted)")
            fatalError(attempted)
        }

        print("[PoseProvider] Using absolute model path: \(path)")

        let options = PoseLandmarkerOptions()
        options.baseOptions.modelAssetPath = path   // absolute filesystem path
        options.runningMode = .video
        options.numPoses = numPoses
        // Detection confidence defaults to 0.5 deliberately, even for
        // uploads: the golfer-selection layer above needs the weak candidates
        // to exist so its largest-person fallback has something to choose.
        // Mid-swing the golfer is blurred and contorted and IS the weak
        // candidate; a 0.7 gate inside the model would delete the golfer at
        // exactly the frames this project exists to measure. The 0.7 bar,
        // and the minimum-area floor for background people, are both applied
        // at the selection layer instead, where a fallback can exist. See
        // the selection note and the recorded brief correction near the top.
        options.minPoseDetectionConfidence = Float(minPoseDetectionConfidence)
        options.minPosePresenceConfidence = 0.5
        options.minTrackingConfidence = Float(minTrackingConfidence)

        do {
            poseLandmarker = try PoseLandmarker(options: options)
            print("[PoseProvider] PoseLandmarker initialised successfully")
        } catch {
            fatalError("Failed to initialise PoseLandmarker: \(error)")
        }
    }

    // MARK: - Optional launch-time bundle check
    //
    // Call MediaPipePoseProvider.verifyModelInBundle() early (e.g. in your
    // AppDelegate / App init) to confirm the models ship in the bundle before
    // anything tries to record or upload. Purely diagnostic; safe to leave in.
    // With no arguments it now reports all three model tiers, since the upload
    // path defaults to full and Settings can select heavy.
    static func verifyModelInBundle(name: String? = nil, ext: String = "task") {
        let names = name.map { [$0] } ?? [
            "pose_landmarker_lite", "pose_landmarker_full", "pose_landmarker_heavy",
        ]
        print("[PoseProvider] verifyModelInBundle: bundle = \(Bundle.main.bundlePath)")
        for n in names {
            if let url = Bundle.main.url(forResource: n, withExtension: ext) {
                let exists = FileManager.default.fileExists(atPath: url.path)
                print("[PoseProvider] verifyModelInBundle: found \(url.path) (existsOnDisk=\(exists))")
            } else {
                print("[PoseProvider] verifyModelInBundle: NOT FOUND for \(n).\(ext)")
            }
        }
        if let resourcePath = Bundle.main.resourcePath,
           let items = try? FileManager.default.contentsOfDirectory(atPath: resourcePath) {
            let tasks = items.filter { $0.hasSuffix(".task") }
            print("[PoseProvider] .task files at resource root: \(tasks.isEmpty ? "none" : tasks.joined(separator: ", "))")
        }
    }

    // MARK: - Detection

    /// One zero placeholder per MediaPipe slot, visibility 0, mirroring
    /// VisionPoseProvider.emptySet(). This is the fix for the empty-array bug:
    /// LandmarkSet is a typealias for [Landmark], so `LandmarkSet()` used to
    /// start at count zero and the fill loop's `index < norm.count` guard broke
    /// on its very first iteration, returning empty sets on every frame.
    private static func placeholderSet() -> LandmarkSet {
        LandmarkSet(repeating: Landmark(x: 0, y: 0, visibility: 0), count: slotCount)
    }

    func detect(frame: CMSampleBuffer, timestampMs: Double) async throws -> [PersonDetection] {
        guard let poseLandmarker else { return [] }

        // Rule 3, the ROI bounding mask. When engaged, detection runs on a
        // pixel crop of the golfer's tracked box instead of the full frame,
        // and appliedRoi records the exact upright rect of that crop so the
        // landmarks can be remapped into full-frame coordinates below. Any
        // failure along the crop path falls back to the full frame, so the
        // mask can only ever narrow the search, never lose a frame.
        var appliedRoi: CGRect? = nil
        var image: MPImage? = nil
        if roiEnabled, numPoses > 1, let roi = roiRect {
            if let crop = croppedImage(from: frame, uprightRoi: roi) {
                image = crop.image
                appliedRoi = crop.uprightRect
            }
        }
        if image == nil {
            // Contrast enhancement, when engaged. The enhancer renders an
            // enhanced copy into a FRESH buffer and we hand only that to the
            // detector; the incoming sample buffer, which the preview layer and
            // overlay read, is never touched. Same orientation is passed as the
            // raw path, and the enhancement is geometry preserving, so landmark
            // coordinates and the ROI remap are identical with it on or off. Any
            // failure falls through to the untouched buffer, so a frame is never
            // lost to the filter.
            if let enhancer,
               let enhanced = enhancer.enhancedBuffer(from: frame),
               let mp = try? MPImage(pixelBuffer: enhanced, orientation: orientation) {
                image = mp
            } else {
                image = try? MPImage(sampleBuffer: frame, orientation: orientation)
            }
        }
        guard let image else { return [] }

        let result = try poseLandmarker.detect(
            videoFrame: image,
            timestampInMilliseconds: Int(timestampMs)
        )
        guard !result.landmarks.isEmpty else {
            // Any frame that lost everyone resets the mask, so the next
            // frame searches the whole image. For a cropped frame that is
            // one dropped frame as the whole cost of a golfer outrunning a
            // stale box; for a full frame it just clears state that could
            // only mislead once someone reappears.
            roiRect = nil
            return []
        }
        if appliedRoi != nil { stats.roiCroppedFrames += 1 }

        // Parse every candidate pose the landmarker returned. With numPoses 1
        // (the live path) this is one iteration and selection is a
        // pass-through, so capture behaviour is unchanged.
        var candidates: [PersonDetection] = []
        candidates.reserveCapacity(result.landmarks.count)
        for (poseIndex, normLandmarks) in result.landmarks.enumerated() {
            let worldLandmarks = poseIndex < result.worldLandmarks.count
                ? result.worldLandmarks[poseIndex] : nil

            // Pre-allocated to the full 33-slot contract, so the fill below
            // can write by index and any consumer indexing slot 23 for a hip
            // reads a real value or an honest zero placeholder, never out of
            // bounds.
            var world = Self.placeholderSet()
            var norm = Self.placeholderSet()

            for (index, lm) in normLandmarks.enumerated() {
                guard index < Self.slotCount else { break }
                // Landmarks from a cropped frame are normalised to the crop.
                // Remap into full-frame coordinates HERE, inside the fill,
                // so zero placeholders are never touched and everything
                // downstream (selection metrics, the baseline area, cleanup,
                // analysis) sees one coordinate system. World landmarks are
                // hip-relative metres and are unaffected by where in the
                // image the person was found.
                var nx = Double(lm.x)
                var ny = Double(lm.y)
                if let roi = appliedRoi {
                    nx = Double(roi.origin.x) + nx * Double(roi.size.width)
                    ny = Double(roi.origin.y) + ny * Double(roi.size.height)
                }
                norm[index] = Landmark(
                    x: nx,
                    y: ny,
                    visibility: lm.visibility?.doubleValue ?? 0
                )

                if let w = worldLandmarks, index < w.count {
                    let wl = w[index]
                    world[index] = Landmark(
                        x: Double(wl.x),
                        y: Double(wl.y),
                        z: Double(wl.z),
                        visibility: wl.visibility?.doubleValue ?? 0
                    )
                }
            }

            // No grip fusion. Both wrists are returned as measured, on the
            // live path and the upload path alike, so the skeleton shows two
            // separate wrists. Whatever wants a single grip point averages
            // the two wrist slots at the point it needs one.
            candidates.append(PersonDetection(
                norm: norm,
                world: world,
                conf: normLandmarks.first?.visibility?.doubleValue ?? 0
            ))
        }

        return selectGolfer(from: candidates, timestampMs: timestampMs)
    }

    // MARK: - Golfer selection

    /// The thirteen joints both backends report, kept local per this file's
    /// convention of not depending on Landmarks.swift for index constants.
    private static let selectionJoints: [Int] = [
        0,                  // nose
        11, 12, 13, 14, 15, 16,   // shoulders, elbows, wrists
        23, 24, 25, 26, 27, 28,   // hips, knees, ankles
    ]

    /*
      Choose the golfer among candidate detections and return them first, with
      the remaining candidates after, so detections.first is the golfer and
      the rest still travel on Frame.people for QA. See the long note at the
      top of the class for the strategy and its reasoning.
    */
    private func selectGolfer(from candidates: [PersonDetection], timestampMs: Double) -> [PersonDetection] {
        guard candidates.count > 1 else {
            if let only = candidates.first {
                let m = Self.selectionMetrics(only.norm)
                let center = m.torsoCenter ?? m.center
                // The upload path applies the audit rules even to a lone
                // candidate. If the only person the detector found fails the
                // area ratio or continuity gate, they are almost certainly a
                // background person in a frame where the golfer was missed.
                // They are still RETURNED, a hole in the track helps nobody
                // and cleanup can reject downstream, but the pick is booked
                // as a last resort and does not move the continuity anchor,
                // feed the baseline, or steer the ROI. If the golfer really
                // is gone for good, the anchor goes stale within
                // continuityStaleMs and selection accepts the new world.
                if numPoses > 1, failsAreaRatio(m.area) || failsContinuity(center: center, timestampMs: timestampMs) {
                    if failsAreaRatio(m.area) { stats.areaRatioRejected += 1 }
                    else { stats.continuityRejected += 1 }
                    roiRect = nil
                    recordPick(area: m.area, tier: .lastResort)
                } else {
                    noteSelection(
                        area: m.area, center: center, box: m.box,
                        timestampMs: timestampMs, tier: .single
                    )
                }
            }
            return candidates
        }

        var bestAny = 0
        var bestAnyScore = -Double.infinity
        var bestEligible = -1
        var bestEligibleScore = -Double.infinity
        var bestConfident = -1
        var bestConfidentScore = -Double.infinity
        var centers: [(x: Double, y: Double)?] = []
        var areas: [Double] = []
        var boxes: [CGRect?] = []
        var subFloorCount = 0
        var areaRatioCount = 0
        var continuityCount = 0

        for (k, person) in candidates.enumerated() {
            let m = Self.selectionMetrics(person.norm)
            // The torso centroid (shoulders and hips) anchors continuity.
            // The box centre swings with the arms mid-swing; the torso does
            // not, so the hard gate below cannot false-trigger on the
            // golfer's own backswing. Falls back to the box centre when the
            // torso is not visible enough to vote.
            let center = m.torsoCenter ?? m.center
            centers.append(center)
            areas.append(m.area)
            boxes.append(m.box)

            // Continuity: prefer the person nearest where the golfer was last
            // frame, so a background walker cannot steal the lock on a single
            // ambiguous frame. New clips (no history) weight everyone equally.
            var continuity = 1.0
            if let last = lastSelectedCenter, let c = center {
                let dx = c.x - last.x, dy = c.y - last.y
                continuity = 1.0 / (1.0 + 4.0 * (dx * dx + dy * dy).squareRoot())
            }
            let score = m.area * continuity

            // Last-resort tier: everyone, so an all-sub-floor frame still
            // yields a golfer rather than a hole in the track.
            if score > bestAnyScore { bestAnyScore = score; bestAny = k }

            // The area floor. A person under minPersonAreaFraction of the
            // frame is a background person and cannot win either of the real
            // tiers, however confidently they were tracked. See the
            // selection note at the top of the class.
            guard m.area >= minPersonAreaFraction else {
                subFloorCount += 1
                continue
            }

            // Rule 1: the area ratio. Measured against this clip's own
            // baseline golfer, not the frame. Inert until the baseline
            // exists and on the live path.
            if numPoses > 1, failsAreaRatio(m.area) {
                areaRatioCount += 1
                continue
            }

            // Rule 2: centroid continuity as a hard gate, on top of the
            // soft weight above. The walker cannot win however large the
            // soft score, because they are standing somewhere the golfer
            // was not.
            if numPoses > 1, failsContinuity(center: center, timestampMs: timestampMs) {
                continuityCount += 1
                continue
            }

            if score > bestEligibleScore { bestEligibleScore = score; bestEligible = k }
            if m.meanVisibility >= minSelectionConfidence, score > bestConfidentScore {
                bestConfidentScore = score
                bestConfident = k
            }
        }

        // Confident above-floor candidates compete first; when nobody clears
        // the visibility bar, the largest above-floor person is the golfer,
        // because in a swing clip the golfer is overwhelmingly the largest
        // person in frame. Only when nobody clears even the area floor does
        // the raw largest person win, so a distant framing degrades to a
        // rough track instead of failing outright.
        let chosen: Int
        let tier: PickTier
        if bestConfident >= 0 {
            chosen = bestConfident
            tier = .confident
        } else if bestEligible >= 0 {
            chosen = bestEligible
            tier = .largestFallback
        } else {
            chosen = bestAny
            tier = .lastResort
        }

        stats.framesWithMultipleCandidates += 1
        stats.subFloorCandidatesExcluded += subFloorCount
        stats.areaRatioRejected += areaRatioCount
        stats.continuityRejected += continuityCount

        if tier == .lastResort {
            // Every candidate failed the gates. The anchor still moves to
            // the pick so a genuine scene change (camera cut, golfer walked
            // to a new tee) recovers within a frame, but the pick does not
            // feed the baseline and the ROI resets to a full-frame search.
            lastSelectedCenter = centers[chosen] ?? lastSelectedCenter
            lastSelectedTimestampMs = timestampMs
            roiRect = nil
            recordPick(area: areas[chosen], tier: tier)
        } else {
            noteSelection(
                area: areas[chosen], center: centers[chosen], box: boxes[chosen],
                timestampMs: timestampMs, tier: tier
            )
        }

        var out = [candidates[chosen]]
        for (k, person) in candidates.enumerated() where k != chosen {
            out.append(person)
        }
        return out
    }

    // MARK: - Audit rule gates (Video 2)

    /// Rule 1. True when the baseline exists and the candidate is smaller
    /// than areaRatioFloor of it. Never fires before the baseline forms.
    private func failsAreaRatio(_ area: Double) -> Bool {
        guard areaRatioFloor > 0, let base = baselineArea, base > 0 else { return false }
        return area < areaRatioFloor * base
    }

    /*
      Rule 2. True when the candidate's torso centroid is farther from the
      last selected golfer than the allowance. The brief's 0.15 is a
      per-consecutive-frame figure, so the allowance scales with the elapsed
      time since the last selection, in units of the running detection
      cadence, capped at four steps. Once the anchor is older than
      continuityStaleMs the gate goes inert entirely: at that point the
      honest statement is "we no longer know where the golfer was", and a
      stale anchor must not be allowed to veto the whole field forever.
    */
    private func failsContinuity(center: (x: Double, y: Double)?, timestampMs: Double) -> Bool {
        guard maxCentroidJumpPerStep > 0,
              let last = lastSelectedCenter,
              let lastTs = lastSelectedTimestampMs,
              let c = center
        else { return false }
        let elapsed = timestampMs - lastTs
        guard elapsed > 0, elapsed <= continuityStaleMs else { return false }
        let steps = Swift.min(4.0, Swift.max(1.0, elapsed / Swift.max(typicalStepMs, 1.0)))
        let allowed = maxCentroidJumpPerStep * steps
        let dx = c.x - last.x, dy = c.y - last.y
        return (dx * dx + dy * dy).squareRoot() > allowed
    }

    /*
      Bookkeeping for an accepted pick: the detection cadence estimate, the
      continuity anchor, the baseline (until it forms), and the ROI. Last
      resort picks never come through here; they update the anchor only, in
      selectGolfer, so a frame where everyone failed cannot pollute the
      baseline or steer the mask.
    */
    private func noteSelection(
        area: Double,
        center: (x: Double, y: Double)?,
        box: CGRect?,
        timestampMs: Double,
        tier: PickTier
    ) {
        if let lastTs = lastSelectedTimestampMs {
            let step = timestampMs - lastTs
            if step > 0, step < 500 {
                typicalStepMs = typicalStepMs * 0.9 + step * 0.1
            }
        }
        lastSelectedCenter = center ?? lastSelectedCenter
        lastSelectedTimestampMs = timestampMs
        feedBaseline(area: area)
        updateRoi(with: box)
        recordPick(area: area, tier: tier)
    }

    /// Rule 1's baseline: the median selected-golfer area over the first
    /// baselineFrameCount accepted picks. Median, not mean, so one odd
    /// opening frame (golfer mid-stride into position) cannot skew it.
    private func feedBaseline(area: Double) {
        guard numPoses > 1, baselineArea == nil, area > 0 else { return }
        baselineSamples.append(area)
        if baselineSamples.count >= baselineFrameCount {
            let sorted = baselineSamples.sorted()
            baselineArea = sorted[sorted.count / 2]
            stats.baselineGolferArea = baselineArea ?? 0
        }
    }

    /*
      Rule 3's tracked mask. The target is the golfer's box expanded by
      roiMargin on every side, clamped into the frame. Edges follow the
      target asymmetrically, growing fast (a hand accelerating toward the
      crop edge must never be clipped) and shrinking slowly (a briefly
      compact pose must not starve the next frame's search). The mask only
      engages after the baseline exists, so the opening frames always see
      the full image.
    */
    private func updateRoi(with box: CGRect?) {
        guard roiEnabled, numPoses > 1, baselineArea != nil else { return }
        guard var target = box, target.width > 0, target.height > 0 else { return }
        target = target.insetBy(dx: -target.width * CGFloat(roiMargin),
                                dy: -target.height * CGFloat(roiMargin))
        target = target.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !target.isNull, target.width > 0.05, target.height > 0.05 else { return }

        guard let current = roiRect else {
            roiRect = target
            return
        }
        func follow(_ cur: CGFloat, _ tgt: CGFloat, expandingWhenSmaller: Bool) -> CGFloat {
            let expanding = expandingWhenSmaller ? (tgt < cur) : (tgt > cur)
            let alpha: CGFloat = expanding ? 0.6 : 0.08
            return cur + alpha * (tgt - cur)
        }
        let minX = follow(current.minX, target.minX, expandingWhenSmaller: true)
        let minY = follow(current.minY, target.minY, expandingWhenSmaller: true)
        let maxX = follow(current.maxX, target.maxX, expandingWhenSmaller: false)
        let maxY = follow(current.maxY, target.maxY, expandingWhenSmaller: false)
        guard maxX > minX, maxY > minY else {
            roiRect = nil
            return
        }
        roiRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private enum PickTier {
        case single
        case confident
        case largestFallback
        case lastResort
    }

    private func recordPick(area: Double, tier: PickTier) {
        stats.framesSeen += 1
        stats.golferAreaSum += area
        if area > 0 { stats.golferAreaMin = Swift.min(stats.golferAreaMin, area) }
        switch tier {
        case .single, .confident: stats.confidentPicks += 1
        case .largestFallback: stats.largestPersonFallbacks += 1
        case .lastResort: stats.lastResortPicks += 1
        }
    }

    /// The four torso joints that anchor the continuity centroid.
    private static let torsoJoints: [Int] = [11, 12, 23, 24]

    /*
      Bounding-box area and centre over the selection joints (normalised
      image units, so area is a fraction of the frame), plus mean visibility
      across them. Joints below 0.2 visibility do not shape the box, so a
      mistracked stray point cannot inflate a distant person's size.

      Also reports the torso centroid (mean of shoulders and hips, needing
      at least three of the four to vote) and the box itself as a CGRect,
      for the continuity gate and the ROI mask respectively.
    */
    private static func selectionMetrics(_ norm: LandmarkSet)
        -> (
            area: Double,
            center: (x: Double, y: Double)?,
            torsoCenter: (x: Double, y: Double)?,
            box: CGRect?,
            meanVisibility: Double
        )
    {
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        var visSum = 0.0
        var visCount = 0
        for j in selectionJoints where j < norm.count {
            let l = norm[j]
            let v = l.visibility ?? l.score ?? 0
            visSum += v
            visCount += 1
            guard v >= 0.2, l.x.isFinite, l.y.isFinite else { continue }
            minX = Swift.min(minX, l.x); maxX = Swift.max(maxX, l.x)
            minY = Swift.min(minY, l.y); maxY = Swift.max(maxY, l.y)
        }
        let meanVis = visCount > 0 ? visSum / Double(visCount) : 0

        var tx = 0.0, ty = 0.0
        var torsoCount = 0
        for j in torsoJoints where j < norm.count {
            let l = norm[j]
            let v = l.visibility ?? l.score ?? 0
            guard v >= 0.2, l.x.isFinite, l.y.isFinite else { continue }
            tx += l.x; ty += l.y
            torsoCount += 1
        }
        let torso: (x: Double, y: Double)? = torsoCount >= 3
            ? (x: tx / Double(torsoCount), y: ty / Double(torsoCount))
            : nil

        guard maxX > minX, maxY > minY else { return (0, nil, torso, nil, meanVis) }
        return (
            (maxX - minX) * (maxY - minY),
            (x: (minX + maxX) / 2, y: (minY + maxY) / 2),
            torso,
            CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
            meanVis
        )
    }

    // MARK: - ROI geometry (Rule 3)

    /*
      MediaPipe rotates the buffer internally per the orientation and hands
      landmarks back in upright normalised space, so the mask is TRACKED in
      upright space (where boxes and landmarks live) but the CROP happens in
      the buffer's own space. These two maps convert between them, one the
      inverse of the other. The 90 degree cases were derived from the
      UIImage.Orientation contract (the orientation names the rotation FROM
      the stored pixels TO the upright image); the mirrored 90 degree cases
      follow the same corner algebra and are included for completeness, but
      no real clip has produced one from a preferredTransform yet.
    */
    private static func bufferPoint(fromUpright p: CGPoint, orientation: UIImage.Orientation) -> CGPoint {
        let u = p.x, v = p.y
        switch orientation {
        case .up:            return CGPoint(x: u, y: v)
        case .down:          return CGPoint(x: 1 - u, y: 1 - v)
        case .left:          return CGPoint(x: 1 - v, y: u)
        case .right:         return CGPoint(x: v, y: 1 - u)
        case .upMirrored:    return CGPoint(x: 1 - u, y: v)
        case .downMirrored:  return CGPoint(x: u, y: 1 - v)
        case .leftMirrored:  return CGPoint(x: 1 - v, y: 1 - u)
        case .rightMirrored: return CGPoint(x: v, y: u)
        @unknown default:    return CGPoint(x: u, y: v)
        }
    }

    private static func uprightPoint(fromBuffer p: CGPoint, orientation: UIImage.Orientation) -> CGPoint {
        let x = p.x, y = p.y
        switch orientation {
        case .up:            return CGPoint(x: x, y: y)
        case .down:          return CGPoint(x: 1 - x, y: 1 - y)
        case .left:          return CGPoint(x: y, y: 1 - x)
        case .right:         return CGPoint(x: 1 - y, y: x)
        case .upMirrored:    return CGPoint(x: 1 - x, y: y)
        case .downMirrored:  return CGPoint(x: x, y: 1 - y)
        case .leftMirrored:  return CGPoint(x: 1 - y, y: 1 - x)
        case .rightMirrored: return CGPoint(x: y, y: x)
        @unknown default:    return CGPoint(x: x, y: y)
        }
    }

    /// Axis-aligned rects stay axis-aligned under every orientation above,
    /// so mapping two opposite corners and taking the span is exact.
    private static func bufferRect(fromUpright r: CGRect, orientation: UIImage.Orientation) -> CGRect {
        let a = bufferPoint(fromUpright: CGPoint(x: r.minX, y: r.minY), orientation: orientation)
        let b = bufferPoint(fromUpright: CGPoint(x: r.maxX, y: r.maxY), orientation: orientation)
        return CGRect(
            x: Swift.min(a.x, b.x), y: Swift.min(a.y, b.y),
            width: abs(a.x - b.x), height: abs(a.y - b.y)
        )
    }

    private static func uprightRect(fromBuffer r: CGRect, orientation: UIImage.Orientation) -> CGRect {
        let a = uprightPoint(fromBuffer: CGPoint(x: r.minX, y: r.minY), orientation: orientation)
        let b = uprightPoint(fromBuffer: CGPoint(x: r.maxX, y: r.maxY), orientation: orientation)
        return CGRect(
            x: Swift.min(a.x, b.x), y: Swift.min(a.y, b.y),
            width: abs(a.x - b.x), height: abs(a.y - b.y)
        )
    }

    /*
      The actual crop. Integer even-aligned pixels, clamped to the buffer,
      rendered through CoreImage into a fresh BGRA buffer (CoreImage's
      origin is bottom left, hence the vertical flip on the crop rect).
      Returns nil, meaning "detect on the full frame instead", when the
      crop would be degenerate: under 96 px a side, which would starve the
      detector, or covering nearly the whole frame, where the copy buys
      nothing. The returned upright rect is recomputed from the INTEGER
      buffer crop, not the requested one, so the landmark remap is exact
      to the pixel.
    */
    private func croppedImage(from sample: CMSampleBuffer, uprightRoi: CGRect)
        -> (image: MPImage, uprightRect: CGRect)?
    {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        let bw = CVPixelBufferGetWidth(pixelBuffer)
        let bh = CVPixelBufferGetHeight(pixelBuffer)
        guard bw > 0, bh > 0 else { return nil }

        let bufRect = Self.bufferRect(fromUpright: uprightRoi, orientation: orientation)

        var px = Int((bufRect.minX * CGFloat(bw)).rounded(.down))
        var py = Int((bufRect.minY * CGFloat(bh)).rounded(.down))
        px = Swift.max(0, Swift.min(px, bw - 2))
        py = Swift.max(0, Swift.min(py, bh - 2))
        var pw = Int((bufRect.width * CGFloat(bw)).rounded(.up))
        var ph = Int((bufRect.height * CGFloat(bh)).rounded(.up))
        pw = Swift.min(pw, bw - px)
        ph = Swift.min(ph, bh - py)
        px -= px % 2; py -= py % 2
        pw -= pw % 2; ph -= ph % 2

        guard pw >= 96, ph >= 96 else { return nil }
        guard Double(pw) * Double(ph) < 0.92 * Double(bw) * Double(bh) else { return nil }

        var created: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ] as [String: Any]
        CVPixelBufferCreate(
            kCFAllocatorDefault, pw, ph,
            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &created
        )
        guard let out = created else { return nil }

        let ciRect = CGRect(x: px, y: bh - (py + ph), width: pw, height: ph)
        var source = CIImage(cvPixelBuffer: pixelBuffer).cropped(to: ciRect)
        // Fuse the enhancement into the crop render that already happens here,
        // so it costs a sampler read rather than a pass. The crop IS the
        // golfer's box, so ROI luma normalization is meaningful and allowed on
        // this path (it is off in the default config regardless). Geometry
        // preserving, so the exactBuffer rect below and the remap are unchanged.
        if let enhancer {
            source = enhancer.enhanced(source, roiNormalize: true)
        }
        roiContext.render(source, to: out, bounds: ciRect, colorSpace: CGColorSpaceCreateDeviceRGB())

        guard let image = try? MPImage(pixelBuffer: out, orientation: orientation) else { return nil }

        let exactBuffer = CGRect(
            x: CGFloat(px) / CGFloat(bw),
            y: CGFloat(py) / CGFloat(bh),
            width: CGFloat(pw) / CGFloat(bw),
            height: CGFloat(ph) / CGFloat(bh)
        )
        return (image, Self.uprightRect(fromBuffer: exactBuffer, orientation: orientation))
    }

    func close() {
        poseLandmarker = nil
    }

    // MARK: - View detection

    /// Kept as provider API for any existing caller; the implementation lives
    /// in SwingViewClassifier in PosePrior.swift. See that file for the
    /// reasoning. (It used to serve the grip solve, which has been removed;
    /// the classifier stays because the view distinction has other readers.)
    func detectView(leftShoulder: Landmark?, rightShoulder: Landmark?) -> SwingView {
        SwingViewClassifier.detectView(leftShoulder: leftShoulder, rightShoulder: rightShoulder)
    }
}
