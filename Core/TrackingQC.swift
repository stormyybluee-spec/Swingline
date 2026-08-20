//
//  TrackingQC.swift
//  Swingline
//
//  Quality control for one processed swing.
//
//  The post-processing pipeline corrects data, and a pipeline that corrects
//  data can hide problems. This record is the antidote: every stage writes
//  down what it saw and what it changed, so a swing whose skeleton looks
//  clean but was one third gap fill says so, a future UI badge has something
//  real to show, and the dataset logger stores honest provenance next to the
//  cleaned timelines it feeds to future learned priors.
//
//  PHASE 2+ ADDITIONS. Four new sections, one per feature that can now touch
//  the data: golfer selection (which person won and how), the lead-arm
//  midpoint constraint, the crop refinement pass, and the GMM prior. Every
//  new field defaults to its zero value, so a QC record written by the
//  previous build decodes unchanged and simply reads "feature never ran".
//
//  VIDEO 1 & 2 AUDIT ADDITIONS. Six new fields to track the hand collapse
//  guard and the background person selection rules. Fields are added with
//  sensible defaults so old encoded records still decode if they are ever
//  read from disk.
//
//  ONFORM PARITY ADDITIONS. One section per new stage of the final accuracy
//  overhaul: the torso width and ratio constraints (Fix 1), the occlusion
//  window RTS smoother (Fix 2), the hand path gate (Fix 3), and the ground
//  plane stage (Fix 4). Zero defaults throughout, so records written by
//  every previous build decode unchanged and read "feature never ran".
//
//  SKELETON INTEGRITY ADDITIONS. Two counters for the frame-audit fixes in
//  PosePrior: the grip cluster anchor (a weak, held wrist drawn back to
//  grip distance from its confidently tracked partner) and the shoulder
//  medial collapse guard (a shoulder convicted on geometry, not
//  visibility, and re-placed by the rigid-torso projection). Zero defaults
//  throughout, same decode guarantee as every section above.
//
//  OCCLUSION OVERHAUL ADDITIONS. The midpoint magnet is removed from the
//  pipeline; its counter stays below so historical records decode and new
//  ones honestly read zero. Its replacements each get a field: the wrist
//  occlusion rejection in LandmarkCleanup (count plus the bar actually
//  applied, so a clip where the adaptive valve engaged says so), the
//  shoulder occlusion projection in PosePrior, and the extended ground
//  stage's ankle anchor and foot depth flattening. Zero and false defaults
//  throughout, same decode guarantee as every section above.
//
//  Codable so it can ride on UploadProcessor.Result, be logged to disk, and
//  eventually be persisted with the record if a schema bump wants it.
//
//  House rule: no em dashes anywhere.
//

import Foundation

public struct TrackingQC: Codable, Hashable {

    // MARK: - Provenance

    /// Which detector produced the raw landmarks: "mediapipe" or "vision".
    public var backend: String = ""
    /// The model tier used, when the backend has one ("lite", "full", "heavy").
    public var model: String = ""

    // MARK: - Sampling

    /// Frames that came out of the detector with a person in them.
    public var framesIn: Int = 0
    /// Frames on the uniform grid after resampling.
    public var gridFrames: Int = 0
    /// The measured input cadence, frames per second.
    public var effectiveFps: Double = 0
    /// The uniform grid rate the pipeline ran at.
    public var gridHz: Double = 0

    // MARK: - Cleanup

    /// The per-clip visibility floor the cleanup derived (Vector H). Samples
    /// below it were treated as missing. Zero when visibility data was absent
    /// (the Vision backend) and the floor never ran.
    public var trustFloor: Double = 0
    /// Per joint: fraction of grid frames where the joint was actually
    /// measured, as opposed to gap filled or held. 1.0 is a fully tracked
    /// joint; 0.0 is a joint the backend never reported (Vision heels).
    public var jointFillFraction: [Int: Double] = [:]
    /// Per joint: mean reported visibility across measured samples. Empty for
    /// backends with no per-joint confidence.
    public var jointMeanVisibility: [Int: Double] = [:]
    /// Samples rejected as outliers (velocity spikes, bone-length breaks,
    /// arm-geometry breaks) and re-filled.
    public var outliersRejected: Int = 0
    /// Interior gaps of at most the short-gap limit, filled by PCHIP.
    public var shortGapsFilled: Int = 0
    /// Longer runs (and clip edges) filled by holding the last known value.
    public var longGapsHeld: Int = 0

    // MARK: - Smoothing (Task 1)

    /// Which smoothing configuration ran: "uniform" (the pass-1 and fallback
    /// form) or "scheduled" (the speed and phase scheduled Phase 2 form).
    public var smoothingMode: String = ""
    /// The band the schedule ran across, in Hz, low end (quietest joint at
    /// the quietest moment) to high end (wrists through impact). Zero when
    /// the smoothing was uniform.
    public var scheduledCutoffLowHz: Double = 0
    public var scheduledCutoffHighHz: Double = 0

    // MARK: - Golfer selection (Task 2)

    /// Frames where the detector returned more than one candidate person.
    public var framesWithMultipleCandidates: Int = 0
    /// Candidate detections excluded from selection because their bounding
    /// box sat under the minimum area floor (background people).
    public var backgroundCandidatesExcluded: Int = 0
    /// Frames where nobody cleared the visibility bar and the golfer was
    /// chosen by the largest-person fallback (either tier).
    public var selectionFallbackFrames: Int = 0
    /// Mean and minimum bounding-box area of the selected golfer, as a
    /// fraction of the frame. A low minimum on an otherwise large mean is
    /// the signature of a one-frame jump onto a background person.
    public var golferAreaMean: Double = 0
    public var golferAreaMin: Double = 0

    // MARK: - Video 2 Audit: Background Person Selection Rules

    /// Candidates rejected because their bounding box area fell below the
    /// minimum area ratio threshold (0.35 × golfer baseline area).
    public var candidatesRejectedByAreaRatio: Int = 0
    /// Candidates rejected because their torso centroid jumped more than
    /// 0.15 normalized units per frame step from the previous selection.
    public var candidatesRejectedByContinuity: Int = 0
    /// The baseline bounding box area of the golfer (as a fraction of frame)
    /// computed from the first 5 confident picks. Used as the reference for
    /// the area ratio threshold.
    public var golferBaselineArea: Double = 0
    /// Frames where the ROI crop was active (pipeline constrained detection
    /// to the golfer's bounding box + 15% margin).
    public var roiCroppedFrames: Int = 0

    // MARK: - Prior

    /// Frames where a bone was projected back toward the clip's median length.
    public var priorBoneCorrections: Int = 0
    /// Frames where an implausibly folded joint was relaxed toward its own
    /// trajectory.
    public var priorRangeCorrections: Int = 0
    /// Frames where the two wrists were fused into a grip point.
    public var gripFramesFused: Int = 0

    // MARK: - Video 1 Audit: Hand Collapse Guard

    /// Frames where the hand collapse guard in LandmarkCleanup flagged the
    /// index and pinky knuckles as missing (rejection form). These frames
    /// were bridged by PCHIP gap filling.
    public var handCollapseRejections: Int = 0
    /// Frames where the hand collapse guard in PosePrior corrected the palm
    /// centre position (reconstruction form). The palm was pushed back out
    /// along the forearm direction to the clip-median separation.
    public var handCollapseCorrections: Int = 0

    // MARK: - Midpoint constraint (Task 3, RETIRED)

    /// RETIRED by the occlusion overhaul: the midpoint magnet is removed
    /// from the pipeline. The field stays so records written while it ran
    /// still decode and still say what happened to them; new records
    /// honestly read zero, this file's own "feature never ran" convention.
    public var midpointCorrections: Int = 0

    // MARK: - Occlusion overhaul

    /// Wrist samples rejected by the visibility bar in LandmarkCleanup and
    /// bridged or held by the standard gap fill.
    public var wristOcclusionRejections: Int = 0
    /// The weakest visibility bar actually applied across the two wrists.
    /// Equal to the configured 0.6 on a well tracked clip; lower when the
    /// adaptive valve engaged to keep the clip from being hollowed out.
    /// Zero when the stage never ran (no visibility data, or disabled).
    public var wristVisibilityFloorApplied: Double = 0
    /// Frames where an occluded shoulder was re-placed from the visible
    /// shoulder, the hips and the clip's rigid-torso geometry.
    public var shoulderProjectionFrames: Int = 0
    /// Ankle samples clamped or blended onto the ankle's own clip-measured
    /// level above the turf.
    public var ankleGroundAnchors: Int = 0
    /// True when foot depth was flattened to clip medians this run.
    public var footDepthFlattened: Bool = false

    // MARK: - Skeleton integrity pass

    /// Frames where the grip cluster anchor (Fix G) drew a weak wrist (a
    /// hold or a deeply dimmed sample) back to grip distance from its
    /// confidently tracked partner. A large number on a DTL clip is the
    /// occluded crossing wrist story told honestly; zero on a face-on
    /// clip is the hoped-for reading.
    public var gripClusterFrames: Int = 0
    /// Frames where the shoulder medial collapse guard convicted a
    /// shoulder on geometry (a one sided shoulder to hip ratio spike plus
    /// a one sided rigid-torso disagreement) and the projection re-placed
    /// it regardless of its reported visibility. A subset, conceptually,
    /// of the failures shoulderProjectionFrames counts, kept separate so
    /// a clip where the visibility bar missed everything says so.
    public var shoulderCollapseFrames: Int = 0

    // MARK: - Crop refinement (Task 4)

    /// Grid frames inside the P4 to P8 window the crop pass attempted.
    public var cropFramesAttempted: Int = 0
    /// Frames where at least one joint was actually refined from the crop.
    public var cropFramesRefined: Int = 0
    /// Individual joint samples merged from the crop detection.
    public var cropJointSamplesMerged: Int = 0

    // MARK: - GMM prior (Task 5)

    /// Frames the loaded GMM scored. Zero when no model file shipped, which
    /// is the honest state until the dataset exists and training has run.
    public var gmmFramesEvaluated: Int = 0
    /// Frames pulled toward a plausible configuration because their
    /// log-likelihood sat below the trained threshold.
    public var gmmCorrections: Int = 0

    // MARK: - Torso constraints (OnForm parity, Fix 1)

    /// Frames where a world shoulder or hip width was projected back toward
    /// its clip median (past the ten percent tolerance).
    public var torsoWidthCorrections: Int = 0
    /// Frames, in either space, where the shoulder to hip width ratio was
    /// corrected toward its clip median. This is the glitch detector: honest
    /// foreshortening shrinks both widths together and never trips it.
    public var torsoRatioCorrections: Int = 0

    // MARK: - Occlusion smoothing (OnForm parity, Fix 2)

    /// Occlusion windows (per joint, per space) the RTS smoother processed:
    /// runs where visibility sat under 0.3 long enough to matter.
    public var occlusionWindowsSmoothed: Int = 0
    /// Unique grid frames inside those windows' occluded cores. A large
    /// number here on a DTL clip is the lead arm story told honestly.
    public var occlusionFramesSmoothed: Int = 0

    // MARK: - Hand path gate (OnForm parity, Fix 3)

    /// Where the velocity trigger opened the hand path and where the quiet
    /// run past P8 closed it, as grid frame indices. activeFrames of zero
    /// means the gate never ran or never opened; the samples themselves
    /// travel on Result.handPath.
    public var handPathStartFrame: Int = 0
    public var handPathStopFrame: Int = 0
    public var handPathActiveFrames: Int = 0

    // MARK: - Ground plane (OnForm parity, Fix 4)

    /// Near-plane heel and toe samples anchored onto the turf.
    public var groundPlaneSnaps: Int = 0
    /// Foot samples that sat below the turf and were clamped back to it.
    public var groundPenetrationsClamped: Int = 0
    /// Frames where the lead or trail heel sat clearly above its plane: the
    /// heel lift, detected and respected rather than fought.
    public var heelLiftFramesLead: Int = 0
    public var heelLiftFramesTrail: Int = 0

    // MARK: - Phases

    /// Mean frame confidence within each phase window, keyed by the phase raw
    /// value ("p1" through "p10"). Filled after analysis, since phases do not
    /// exist until the refined frames have been segmented.
    public var phaseConfidence: [String: Double] = [:]

    public init() {}

    /*
      Mean frame confidence per phase window. The window for a phase runs from
      its index up to (not including) the next phase's index; the last phase
      runs to the end of the clip. Uses the same Frame.conf the validity gate
      reads, so the two agree about what confidence means.
    */
    public mutating func fillPhaseConfidence(frames: [Frame], phases: PhaseResult) {
        guard !frames.isEmpty else { return }
        let ordered = Phases.PHASE_KEYS
        for (k, key) in ordered.enumerated() {
            guard let start = phases.idx[key] else { continue }
            let end: Int
            if k + 1 < ordered.count, let next = phases.idx[ordered[k + 1]], next > start {
                end = min(next, frames.count)
            } else {
                end = frames.count
            }
            let lo = max(0, min(start, frames.count - 1))
            let hi = max(lo + 1, min(end, frames.count))
            let window = frames[lo..<hi]
            let mean = window.reduce(0.0) { $0 + $1.conf } / Double(window.count)
            phaseConfidence[key.rawValue] = (mean * 1000).rounded() / 1000
        }
    }
}
