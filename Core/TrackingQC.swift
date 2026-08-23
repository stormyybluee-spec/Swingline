//
//  TrackingQC.swift
//  Swingline
//
//  Quality control for one processed swing.
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

    /// The per-clip visibility floor the cleanup derived. Samples below it
    /// were treated as missing. Zero when visibility data was absent and the
    /// floor never ran.
    public var trustFloor: Double = 0

    /// Per joint: fraction of grid frames where the joint was measured.
    public var jointFillFraction: [Int: Double] = [:]

    /// Per joint: mean reported visibility across measured samples.
    public var jointMeanVisibility: [Int: Double] = [:]

    /// Samples rejected as outliers and re-filled.
    public var outliersRejected: Int = 0

    /// Interior gaps of at most the short-gap limit, filled by PCHIP.
    public var shortGapsFilled: Int = 0

    /// Longer runs and clip edges filled by holding the last known value.
    public var longGapsHeld: Int = 0

    // MARK: - Smoothing

    /// Which smoothing configuration ran: "uniform" or "scheduled".
    public var smoothingMode: String = ""

    /// The scheduled low cutoff in Hz.
    public var scheduledCutoffLowHz: Double = 0

    /// The scheduled high cutoff in Hz.
    public var scheduledCutoffHighHz: Double = 0

    // MARK: - Golfer selection

    /// Frames where the detector returned more than one candidate person.
    public var framesWithMultipleCandidates: Int = 0

    /// Candidate detections excluded because their box sat under the area floor.
    public var backgroundCandidatesExcluded: Int = 0

    /// Frames where selection fell back to the largest-person rule.
    public var selectionFallbackFrames: Int = 0

    /// Mean selected golfer bounding-box area as a fraction of frame.
    public var golferAreaMean: Double = 0

    /// Minimum selected golfer bounding-box area as a fraction of frame.
    public var golferAreaMin: Double = 0

    // MARK: - Background person selection rules

    /// Candidates rejected by area-ratio gating.
    public var candidatesRejectedByAreaRatio: Int = 0

    /// Candidates rejected by continuity gating.
    public var candidatesRejectedByContinuity: Int = 0

    /// Baseline golfer bounding-box area as a fraction of frame.
    public var golferBaselineArea: Double = 0

    /// Frames where ROI crop was active.
    public var roiCroppedFrames: Int = 0

    // MARK: - Prior

    /// Frames where a bone was projected back toward its median length.
    public var priorBoneCorrections: Int = 0

    /// Frames where an implausibly folded joint was relaxed.
    public var priorRangeCorrections: Int = 0

    /// Frames where the two wrists were fused into a grip point.
    public var gripFramesFused: Int = 0

    // MARK: - Hand collapse guard

    /// Hand collapse samples rejected in LandmarkCleanup.
    public var handCollapseRejections: Int = 0

    /// Hand collapse samples corrected in PosePrior.
    public var handCollapseCorrections: Int = 0

    // MARK: - Midpoint constraint, retired

    /// Retired field kept for historical decode compatibility.
    public var midpointCorrections: Int = 0

    // MARK: - Occlusion overhaul

    /// Wrist samples rejected by the visibility bar.
    public var wristOcclusionRejections: Int = 0

    /// Weakest wrist visibility floor actually applied.
    public var wristVisibilityFloorApplied: Double = 0

    /// Frames where an occluded shoulder was projected from torso geometry.
    public var shoulderProjectionFrames: Int = 0

    /// Ankle samples clamped or blended onto their clip-measured turf level.
    public var ankleGroundAnchors: Int = 0

    /// True when foot depth was flattened to clip medians.
    public var footDepthFlattened: Bool = false

    // MARK: - Skeleton integrity pass

    /// Frames where the grip cluster anchor corrected a weak wrist.
    public var gripClusterFrames: Int = 0

    /// Frames where shoulder medial collapse was corrected.
    public var shoulderCollapseFrames: Int = 0

    // MARK: - Crop refinement

    /// Grid frames inside the attempted crop-refinement window.
    public var cropFramesAttempted: Int = 0

    /// Frames where at least one joint was refined from the crop.
    public var cropFramesRefined: Int = 0

    /// Individual joint samples merged from the crop detection.
    public var cropJointSamplesMerged: Int = 0

    // MARK: - GMM prior

    /// Frames the loaded GMM scored.
    public var gmmFramesEvaluated: Int = 0

    /// Frames corrected by the GMM prior.
    public var gmmCorrections: Int = 0

    // MARK: - Torso constraints

    /// Frames where shoulder or hip width was corrected.
    public var torsoWidthCorrections: Int = 0

    /// Frames where shoulder-to-hip width ratio was corrected.
    public var torsoRatioCorrections: Int = 0

    // MARK: - Occlusion smoothing

    /// Occlusion windows processed by the RTS smoother.
    public var occlusionWindowsSmoothed: Int = 0

    /// Unique grid frames inside smoothed occlusion windows.
    public var occlusionFramesSmoothed: Int = 0

    // MARK: - Hand path gate

    /// Frame where hand path gate opened.
    public var handPathStartFrame: Int = 0

    /// Frame where hand path gate closed.
    public var handPathStopFrame: Int = 0

    /// Number of active hand path frames.
    public var handPathActiveFrames: Int = 0

    // MARK: - Ground plane

    /// Near-plane heel and toe samples anchored onto the turf.
    public var groundPlaneSnaps: Int = 0

    /// Foot samples below turf clamped back to it.
    public var groundPenetrationsClamped: Int = 0

    /// Lead heel lift frames.
    public var heelLiftFramesLead: Int = 0

    /// Trail heel lift frames.
    public var heelLiftFramesTrail: Int = 0

    // MARK: - Round four: DTL and face-on overhaul

    /// Frames where toe pivot plant held a lifted heel's toe at turf level.
    public var toePivotPlants: Int = 0

    /// Frames where mirrored knee depth was corrected.
    public var kneeDepthFlipsCorrected: Int = 0

    /// Wrist and elbow samples rejected by arm identity checks.
    public var armIdentityRejections: Int = 0

    /// Knuckle samples rejected by background palm-lock checks.
    public var backgroundLockRejections: Int = 0

    /// Limb bone samples rejected by the impossibility floor.
    public var boneImpossibleRejections: Int = 0

    /// Routed swing view label: "faceOn" or "downTheLine".
    public var detectedViewLabel: String = ""

    // MARK: - Round five advanced fixes

    /// Address-reference grid frames available to downstream reference stages.
    public var addressReferenceFrames: Int = 0

    /// Stillness score of the captured address reference window.
    public var addressReferenceStillness: Double = 0

    /// Bone-length constants sourced from the address reference.
    public var referenceBoneLengthsUsed: Int = 0

    /// Joint-angle priors sourced from the address reference.
    public var referenceJointAnglesUsed: Int = 0

    /// Reference constants accepted by the resolver.
    public var referenceConstantsUsed: Int = 0

    /// Reference constants rejected because confidence, stability, or geometry
    /// checks failed.
    public var referenceConstantsRejected: Int = 0

    /// Occlusion RTS windows whose process noise was scaled by joint velocity.
    public var velocityAwareRTSWindows: Int = 0

    /// Individual frames inside RTS windows where velocity scaling boosted the
    /// process noise above the base value.
    public var rtsVelocityBoostedFrames: Int = 0

    /// Body-level centre-of-mass frames evaluated by the cleanup stage.
    public var comFramesEvaluated: Int = 0

    /// Body-level centre-of-mass discontinuities detected.
    public var comJumpsDetected: Int = 0

    /// Individual joint samples rejected due to centre-of-mass attribution.
    public var comRejections: Int = 0

    /// Frames where the damped Levenberg-Marquardt IK solver accepted an update.
    public var ikFramesSolved: Int = 0

    /// Individual joint samples changed by accepted IK solves.
    public var ikJointCorrections: Int = 0

    /// Frames where IK was attempted but rejected or failed.
    public var ikSolverFailures: Int = 0

    /// Mean fractional residual reduction across accepted IK frames.
    public var ikMeanResidualReduction: Double = 0

    /// Occlusion windows processed with the constant-acceleration Kalman path.
    public var constantAccelWindowsSmoothed: Int = 0

    /// Compatibility counter for the constant-acceleration Kalman path.
    /// Kept separate because AdaptiveSmoothing writes this shorter name.
    public var constantAccelWindows: Int = 0

    /// Grid-frame samples inside constant-acceleration Kalman windows.
    public var constantAccelFramesSmoothed: Int = 0

    /// Frames where the spine or trunk hypergraph corrected geometry.
    public var spineLengthCorrections: Int = 0

    /// Frames where bilateral symmetry hypergraph corrected geometry.
    public var bilateralSymmetryCorrections: Int = 0

    /// Frames where bilateral body constants were reconciled toward a shared
    /// reference-consistent value.
    public var bilateralSymmetryReconciled: Int = 0

    // MARK: - Phases

    /// Mean frame confidence within each phase window, keyed by raw phase value.
    public var phaseConfidence: [String: Double] = [:]

    public init() {}

    /*
      Mean frame confidence per phase window. The window for a phase runs from
      its index up to, but not including, the next phase's index. The last phase
      runs to the end of the clip.
    */
    public mutating func fillPhaseConfidence(frames: [Frame], phases: PhaseResult) {
        guard !frames.isEmpty else { return }

        let ordered = Phases.PHASE_KEYS
        for (k, key) in ordered.enumerated() {
            guard let start = phases.idx[key] else { continue }

            let end: Int
            if k + 1 < ordered.count,
               let next = phases.idx[ordered[k + 1]],
               next > start {
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
