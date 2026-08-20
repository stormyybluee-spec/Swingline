//
//  PosePrior.swift
//  Swingline
//
//  The analytic pose prior, the dataset logger that feeds the future
//  learned priors, and the GMM prior inference foundation (Task 5). The
//  grip fusion this file used to finish with has been removed; both wrists
//  are carried separately now, and the only survivor of that machinery is
//  the small SwingViewClassifier (face-on versus down-the-line), which
//  other files still read.
//
//  OCCLUSION OVERHAUL (this pass). The midpoint magnet (Task 3 / Fix 5) is
//  REMOVED ENTIRELY, config and all: even in its path-only form its pulls
//  were corrections built on a visibility signal the research says cannot
//  be trusted, and testing agreed. Its replacement lives where each failure
//  actually is:
//
//    The wrist is handled by REJECTION in LandmarkCleanupEngine (wrist
//    occlusion rejection, visibility under 0.6 masks the sample, the
//    standard gap fill bridges 1 to 4 frame holes and holds longer ones),
//    which obeys that engine's ONE RULE instead of inventing pulls here.
//
//    The occluded SHOULDER gets its own stage in this file (shoulder
//    occlusion projection, below): MediaPipe guesses an occluded trail
//    shoulder inward with rotational errors the literature puts at 36 to
//    42 degrees, and the projection re-places it from the visible
//    shoulder, the hips and the clip's own rigid-torso geometry.
//
//    The ANKLE gets a stronger ground stage (extended Fix 4): foot depth
//    is flattened to the clip median because MediaPipe's z is noise at
//    the feet, and the ankle is anchored near its own measured height
//    above the turf so it can neither sink into the ground nor hover.
//
//  The corrector still captures leadHandPathNormX/Y for HandPathBuilder,
//  now as the corrected lead wrist track itself (post cleanup, post
//  shoulder projection, pre fusion), so UploadProcessor's wiring is
//  unchanged and the drawn trace follows the measured, occlusion-hardened
//  wrist rather than a magnet's implication.
//
//  A NOTE ON PROVENANCE, recorded so it cannot be mistaken for an oversight:
//  the original PosePrior.swift was not attached to this round (the same
//  situation Validity.swift was in last round). Its public surface is fully
//  recoverable from the call sites in MediaPipePoseProvider
//  (SwingViewClassifier.detectView), UploadProcessor
//  (PosePriorCorrector.analytic(dominantHand:).run(_:qc:),
//  SwingDatasetLogger.log(frames:qc:source:)) and the TrackingQC field names
//  (priorBoneCorrections, priorRangeCorrections, gripFramesFused), and this
//  file implements exactly that surface. DIFF THIS AGAINST YOUR ORIGINAL
//  before merging: thresholds inside the reconstructed stages (bone blend,
//  fold angle, view-detection ratio) are this file's choices, and if your
//  original tuned them differently, your numbers win.
//
//  WHERE THE LINE SITS
//
//  LandmarkCleanupEngine rejects data and bridges holes from the joint's own
//  measurements: it never invents. This file is the one place mild invention
//  is permitted, and every stage here is bounded so the invention stays mild:
//  bone projection moves a joint along a direction that was measured, toward
//  a length this golfer's own clip established; the fold guard relaxes an
//  impossible angle toward the joint's own trajectory; the shoulder
//  projection re-places an occluded shoulder from anchors that were
//  measured this frame and a torso geometry this golfer's own clip
//  established, at half weight; the GMM step is trust-region capped and
//  only runs when a trained model actually ships. Every correction is
//  counted in TrackingQC, because a pipeline that corrects data quietly is
//  a pipeline that lies.
//
//  ONFORM PARITY ADDITIONS (final accuracy overhaul), as amended by the
//  occlusion overhaul, each recorded at its implementation site:
//
//    Fix 1, torso width and ratio constraints. Shoulder width (11 to 12) and
//    hip width (23 to 24) are body constants; the tracker's are not,
//    especially down the line where depth noise makes the projected widths
//    drift. World widths are projected toward the clip medians, and in BOTH
//    spaces the shoulder to hip RATIO is held near its clip median, which is
//    the criterion that separates a tracking glitch (one width collapses,
//    the other does not, ratio spikes) from honest foreshortening (both
//    widths shrink together, ratio survives).
//
//    Shoulder occlusion projection (occlusion overhaul, Fix S). An occluded
//    shoulder, visibility under 0.6, is re-placed from the visible
//    shoulder, the hip centre and the clip's own rigid-torso geometry, at
//    half weight. Runs BEFORE the torso width stage on purpose: that
//    stage's symmetric scaling would otherwise split an inward-collapsed
//    shoulder's error with the good shoulder, moving a well measured joint
//    to pay for a badly measured one.
//
//    Fix 4, ground plane, extended. Per-side turf levels are estimated from
//    the clip's own heel and toe positions; feet may never sink below them,
//    near-plane heels and toes are gently anchored to them, and a heel
//    clearly above its plane is counted as a heel lift instead of being
//    fought. NEW: foot depth (heel, toe, ankle z) is flattened to the clip
//    median per joint per side, because MediaPipe's z is unreliable at the
//    feet and is what dragged ankles through the turf; and the ankle is
//    anchored near its own clip-measured height above the plane, so it can
//    neither sink nor float while a genuine heel lift still moves it
//    freely.
//
//    Fix 5 is GONE. The midpoint magnet is removed entirely; see the file
//    header for where each of its jobs went.
//
//  ORDER OF OPERATIONS (conflict C3 from the roadmap)
//
//    1. bone-length projection        world space, pose-invariant lengths
//    1a. shoulder projection          both spaces, occluded shoulder only
//                                     (Fix S), before the torso stage so
//                                     symmetric width scaling never splits
//                                     an occlusion error with the good side
//    1b. torso width and ratio        world widths, both-space ratios (Fix 1)
//    2. impossible-fold relaxation    world space
//    2b. ground plane                 both spaces, feet only (Fix 4,
//                                     extended: depth flattening and the
//                                     ankle anchor)
//    3. hand collapse guard           both spaces, both hands. The Gemini
//                                     audit of Video 1: at impact, with the
//                                     hands past 4 m/s, MediaPipe collapses
//                                     the index and pinky knuckles ONTO the
//                                     wrist (distance 0.000 against a
//                                     healthy 0.022 to 0.028), which no
//                                     anatomy permits at any speed. The
//                                     guard restores the golfer's own
//                                     clip-median separation along the
//                                     measured forearm direction.
//    5. GMM prior (Task 5)            norm space, mirrored to world, optional
//
//  Grip fusion (once step 6, "LAST, per conflict C3") is REMOVED. Both
//  wrists are now carried and drawn separately, so the corrector's last act
//  is capturing the lead wrist for the hand path rather than collapsing the
//  two wrists into a grip. The view classifier that fusion used to need
//  survives as SwingViewClassifier, below.
//
//  House rule: no em dashes anywhere.
//

import Foundation

// MARK: - Swing view classifier

/*
  Which way the camera looks, from shoulder depth separation. This used to be
  a member of GripPointFusion, which fused the two wrists into one grip point
  as the pipeline's last step. Grip fusion has been removed: both wrists are
  now carried and drawn separately, on every backend and both paths. The view
  classifier survives the removal because other files still read the
  distinction (the overlay's face-on versus down-the-line handling among
  them), so it keeps its own small home here under an honest name. Any code
  that referred to GripPointFusion.detectView should now name
  SwingViewClassifier.detectView; the provider's detectView method already
  does.
*/
enum SwingViewClassifier {

    /*
      Face on, the shoulders sit at similar depth; down the line they are
      separated in depth by close to their full anatomical width. The 0.6
      ratio splits the two regimes with room for an angled camera on either
      side.
    */
    static func detectView(leftShoulder: Landmark?, rightShoulder: Landmark?) -> SwingView {
        guard let l = leftShoulder, let r = rightShoulder,
              let zl = l.z, let zr = r.z, zl.isFinite, zr.isFinite,
              l.x.isFinite, r.x.isFinite else { return .faceOn }
        let dx = l.x - r.x, dy = l.y - r.y
        let planar = (dx * dx + dy * dy).squareRoot()
        guard planar > 1e-6 else { return .faceOn }
        return abs(zl - zr) > 0.6 * planar ? .downTheLine : .faceOn
    }
}

// MARK: - Shoulder occlusion projection (Fix S, occlusion overhaul)

/*
  The known MediaPipe failure this replaces the magnet's job on the torso
  with: when a shoulder is occluded (the trail shoulder crossing behind the
  chin and lead arm through the downswing, on a right hander the RIGHT
  shoulder), the tracker does not report it missing, it GUESSES, and the
  guess collapses inward toward the body, with shoulder rotation errors the
  sports biomechanics literature measures at 36 to 42 degrees. No amount of
  smoothing fixes a confident wrong guess, so this stage re-derives the
  occluded shoulder from things that were actually measured.

  THE RIGID TORSO MODEL. In each space's image plane, the torso is treated
  as rigid: relative to the hip centre, each shoulder sits at a fixed radius
  and at a fixed angular offset from the OTHER shoulder's direction. Both
  constants are read from this golfer's own clip, as medians over frames
  where both shoulders and both hips were confidently seen. When one
  shoulder drops under the visibility bar while the other shoulder and both
  hips are confidently seen, the visible shoulder's measured direction from
  the hip centre plus the remembered angular offset and radius imply where
  the occluded shoulder has to be, and the occluded shoulder is blended
  halfway toward that implication.

  Why the VISIBLE shoulder carries the rotation rather than the hip line:
  shoulders rotate further than hips through a swing (the X factor is one of
  this app's own metrics), so projecting from hip direction alone would drag
  measured shoulder rotation toward hip rotation and corrupt the very angle
  the fix exists to protect. The visible shoulder IS the measured shoulder
  rotation; the model only transports it across the torso.

  The model is exact for in-plane rotation and approximate under
  foreshortening, which is why the blend is 0.5 and not 1.0: a soft
  correction per the brief, so residual model error is split with whatever
  signal the tracker still has. Runs per space with that space's own
  geometry and medians, so norm and world move in lockstep in rule and
  count. Depth is left untouched: the model is an image-plane statement and
  inventing z would be a lie. On the Vision backend there is no per-joint
  visibility, nothing ever reads as occluded, and the stage is inert, which
  is the honest behaviour.
*/
public struct ShoulderProjectionConfig {
    public var enabled: Bool = true
    /// A shoulder below this visibility is treated as occluded (the
    /// brief's 0.6).
    public var occludedBelow: Double = 0.6
    /// The anchors (the other shoulder and both hips) must all clear this
    /// bar for a projection to fire, and for a frame to feed the clip
    /// medians. An anchor below it could move a joint it cannot vouch for.
    public var anchorMinVisibility: Double = 0.6
    /// Fraction of the way the occluded shoulder moves toward the
    /// rigid-torso implication (the brief's 0.5, a soft correction).
    public var blend: Double = 0.5

    public init() {}
}

// MARK: - Hand collapse guard (kinematic distance guard, Video 1 fix)

/*
  The failure this guards against, from the Gemini audit of Video 1: in the
  impact window, with the hands moving faster than about 4 m/s, motion blur
  makes MediaPipe collapse the index (19) and pinky (17) knuckles onto the
  wrist (15). The measured wrist-to-palm distance drops from a healthy 0.022
  to 0.028 normalised to exactly 0.000, and downstream wrist-angle and
  release metrics read garbage at the one instant that matters most.

  A knuckle at zero distance from the wrist is not a pose, it is a failure
  signature, so the correction here is the same species of mild invention
  the bone projection already performs: the palm centre is pushed back out
  along a direction that was MEASURED (elbow to wrist, this very frame) to
  a separation this golfer's own clip established (the clip median), and
  the two knuckles keep their own lateral spread, they translate together.
  Both hands, both spaces, each space in its own units, counted in QC.

  Two deliberate deviations from the brief's bare numbers, recorded here:

    The 0.015 collapse threshold is normalised units and cannot be applied
    raw to a golfer filmed small in a wide frame, whose HEALTHY hand span
    might be under 0.015. The working threshold is the smallest of the
    absolute 0.015 (norm space only), half the clip-median hand span, and
    the anatomical minimum below. A tiny golfer therefore gets a
    proportionally tiny threshold instead of wall-to-wall false positives.

    The speed gate prefers the world channel (metres per second, the
    brief's 4.0) and falls back to normalised units per second when world
    is absent, because a purely image-space gate would misread a camera
    zoom as hand speed. The gate also protects legitimate foreshortening:
    a palm aimed square at the lens collapses the 2D distance honestly,
    but that happens at address and takeaway speeds, not at 4 m/s.
*/
public struct HandCollapseGuardConfig {
    public var enabled: Bool = true
    /// Absolute collapse ceiling in normalised space (the brief's 0.015).
    public var collapseDistanceNorm: Double = 0.015
    /// Relative ceiling: this fraction of the clip-median hand span.
    public var collapseMedianFraction: Double = 0.5
    /// Speed gate when world landmarks carry the wrist, metres per second.
    public var minHandSpeedWorld: Double = 4.0
    /// Fallback speed gate in normalised frame units per second.
    public var minHandSpeedNorm: Double = 1.2
    /// Anatomical minimum separation as a fraction of the clip-median
    /// forearm (wrist to knuckles runs about a third of a forearm).
    public var minSeparationForearmFraction: Double = 0.22
    /// Restoration target as a forearm fraction when the clip never
    /// produced a healthy median of its own.
    public var defaultSeparationForearmFraction: Double = 0.30

    public init() {}
}

// MARK: - Ground plane (Fix 4)

/*
  Feet obey the turf. The tracker's do not: heels float a few pixels above
  the ground at address, sink below it through the downswing, and jitter
  around it in the finish hold, none of which a planted foot can do. The fix
  estimates where the turf actually is from the clip's own feet and applies
  three rules, per side, per space, in that space's own units:

    1. Nothing sinks below the plane. A heel, toe or ankle past the plane is
       clamped back to it, fully, because turf is not negotiable.
    2. A heel or toe hovering within the snap zone is gently pulled onto the
       plane, which kills the float and the near-ground jitter without ever
       fighting a real lift.
    3. A heel clearly above the plane is a HEEL LIFT, a real event the
       constraint must respect: it is counted (lead and trail separately,
       the trail heel lifting through impact is the one the brief named)
       and left strictly alone.

  The plane is estimated per side rather than as one line, so a tilted
  camera or a sloped lie does not break it: each foot's turf level is the
  toward-ground 75th percentile of that foot's own heel and toe positions
  across the clip, which is robust both to lifted-heel frames (they sit on
  the away-from-ground side of the distribution) and to the occasional
  tracking outlier below it. Which y direction means "up" is read from the
  data (the hips sit above the feet) rather than assumed, so the stage
  cannot be broken by a coordinate convention.

  All scales are fractions of the clip-median shin length, the same
  golfer-relative yardstick the hand collapse guard uses, so a golfer
  filmed small is judged by their own geometry.

  OCCLUSION OVERHAUL EXTENSIONS, two, both aimed at the sinking ankle:

  DEPTH FLATTENING. MediaPipe's z is at its least reliable at the feet, and
  a noisy foot depth is what let the 3D ankle wander through the turf while
  its 2D position looked sane. Per the brief, foot depth is not used as a
  measurement at all: each foot joint's z (heel, toe, ankle, per side, per
  space) is replaced with that joint's own clip-median z. ONE RECORDED
  DEVIATION from the brief's literal "z = 0": in world space z is measured
  from the hip centre, so a literal zero would teleport the feet onto the
  hip depth plane, an actual (and wrong) claim. The clip median is the
  faithful form of "use 2D only": a constant, so depth noise can move
  nothing, while the 3D view keeps anatomically placed feet.

  THE ANKLE ANCHOR. The ankle joint sits a fixed height above the sole, so
  its resting level is ABOVE the turf, and snapping it onto the turf (the
  brief's literal ankle.y = groundY) would flatten every planted foot. The
  anchor instead measures the ankle's own toward-ground level from the clip
  (same robust percentile as the turf estimate) and holds the ankle near
  THAT level: below it past tolerance is clamped up, near it is gently
  blended on, clearly above it (a heel lift raises the ankle too) is left
  strictly alone. The turf-level penetration clamp remains as the hard
  backstop underneath.
*/
public struct GroundPlaneConfig {
    public var enabled: Bool = true
    /// Heels and toes within this height above the plane are anchored to
    /// it, as a fraction of the clip-median shin length.
    public var snapZoneShinFraction: Double = 0.06
    /// How strongly a snap-zone point is pulled onto the plane. A blend,
    /// not a teleport, so the anchoring cannot itself become a step.
    public var snapBlend: Double = 0.7
    /// A heel higher above the plane than this fraction of the shin counts
    /// as a lifted heel and is never touched.
    public var liftThresholdShinFraction: Double = 0.12
    /// Magnet/feet task: a point is only clamped as a penetration when it
    /// sits deeper than this fraction of the shin below the plane. The plane
    /// is a median estimate with its own noise, so a toe a hair under it on
    /// a planted foot is within tolerance and left alone; clamping those
    /// tiny excursions was what flattened the foot's angle frame to frame.
    /// Real penetrations, several centimetres of shin below ground, still
    /// clamp.
    public var penetrationToleranceShinFraction: Double = 0.03

    /// Occlusion overhaul: replace each foot joint's z with its own clip
    /// median, per side, per space. See the config note for why the median
    /// and not the brief's literal zero.
    public var flattenFootDepth: Bool = true
    /// Occlusion overhaul: hold the ankle near its own clip-measured level
    /// above the turf. Off restores the previous behaviour (turf clamp
    /// only) for diffing.
    public var ankleAnchorEnabled: Bool = true
    /// The ankle's snap zone around its own level, as a shin fraction. A
    /// touch wider than the heel and toe zone because the ankle's level is
    /// itself an estimate stacked on the turf estimate.
    public var ankleSnapZoneShinFraction: Double = 0.08
    /// How strongly a near-level ankle is pulled onto its level. Softer
    /// than the heel and toe snap: the ankle carries the shin, and an
    /// aggressive pull there would kick visibly up the leg.
    public var ankleSnapBlend: Double = 0.5

    public init() {}
}

// MARK: - GMM pose prior (TASK 5, inference side)

/*
  Foundation for the learned pose prior, Vectors C, Q and L. The dataset that
  trains it accumulates via SwingDatasetLogger below; the training script
  (train_pose_gmm.py) exports means, variances and weights as JSON; this type
  loads that JSON and scores each frame's joint configuration.

  Poses are scored in a canonical frame: hip-centre subtracted, divided by
  shoulder width, so a tall golfer near the camera and a short one far away
  produce the same configuration vector. A frame whose log-likelihood falls
  below the trained threshold is pulled a bounded step toward the mean of its
  most responsible component. The step is a trust region twice over: only a
  quarter of the gap per frame, and never more than a fifth of a shoulder
  width per joint, so the prior can rescue a wrist that teleported into the
  golfer's chest but cannot redraw a swing into the training set's average.

  Diagonal covariances only in v1, matching the training script's default: a
  full 66 by 66 covariance per component needs matrix solves this file does
  not want to hand-roll, and the diagonal model already answers "is this a
  human golf pose" well enough to gate corrections.

  Ships disabled by construction: loadFromBundle returns nil until a
  pose_gmm.json actually exists in the bundle, and the corrector simply skips
  the stage. Zero in qc.gmmFramesEvaluated is the honest record of that.
*/
public struct GMMPosePrior {

    struct Normalization: Decodable {
        var centerA: Int
        var centerB: Int
        var scaleA: Int
        var scaleB: Int
        var minScale: Double
    }

    struct Model: Decodable {
        var version: Int
        var jointCount: Int
        var covarianceType: String
        var weights: [Double]
        var means: [[Double]]
        var variances: [[Double]]
        var logLikelihoodThreshold: Double
        var normalization: Normalization
    }

    public struct Config {
        public var pullWeight: Double = 0.25
        /// Per-joint step cap in canonical units (shoulder widths).
        public var maxJointStep: Double = 0.2
        /// A frame missing more canonical dimensions than this is skipped
        /// rather than scored against filled-in guesses.
        public var maxMissingJoints: Int = 4
        public init() {}
    }

    private let model: Model
    private let logWeights: [Double]
    private let logNormalizers: [Double]  // per component: -0.5 * (D ln 2pi + sum ln var)
    private let mixtureMean: [Double]
    private let config: Config

    public static func loadFromBundle(resource: String = "pose_gmm", config: Config = Config()) -> GMMPosePrior? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json") else { return nil }
        return GMMPosePrior(url: url, config: config)
    }

    public init?(url: URL, config: Config = Config()) {
        guard let data = try? Data(contentsOf: url),
              let model = try? JSONDecoder().decode(Model.self, from: data),
              model.covarianceType == "diag",
              !model.weights.isEmpty,
              model.weights.count == model.means.count,
              model.weights.count == model.variances.count,
              model.means.allSatisfy({ $0.count == model.jointCount * 2 }),
              model.variances.allSatisfy({ $0.count == model.jointCount * 2 })
        else {
            print("[PosePrior] pose_gmm.json missing, malformed, or not diagonal; GMM stage disabled")
            return nil
        }
        self.model = model
        self.config = config

        let d = Double(model.jointCount * 2)
        self.logWeights = model.weights.map { Foundation.log(max($0, 1e-12)) }
        self.logNormalizers = model.variances.map { v in
            -0.5 * (d * Foundation.log(2 * Double.pi) + v.reduce(0) { $0 + Foundation.log(max($1, 1e-12)) })
        }
        var mean = [Double](repeating: 0, count: model.jointCount * 2)
        for (k, m) in model.means.enumerated() {
            for j in 0..<mean.count { mean[j] += model.weights[k] * m[j] }
        }
        self.mixtureMean = mean

        print("[PosePrior] GMM prior loaded: \(model.weights.count) components, threshold \(model.logLikelihoodThreshold)")
    }

    /// Score every frame; pull the improbable ones. Norm space is the scored
    /// space (the space the model was trained on); the same canonical delta,
    /// scaled by this frame's world shoulder width, is mirrored into world so
    /// the drawn skeleton and the printed numbers keep moving together.
    func run(_ timeline: inout PoseTimeline, qc: inout TrackingQC) {
        let joints = min(model.jointCount, timeline.jointCount)
        guard joints > 0 else { return }
        let norm = model.normalization
        guard max(norm.centerA, norm.centerB, norm.scaleA, norm.scaleB) < timeline.jointCount else { return }

        for i in 0..<timeline.frameCount {
            // Canonical frame from the normalised image landmarks.
            guard let hipX = finitePair(timeline.norm.x[norm.centerA][i], timeline.norm.x[norm.centerB][i]),
                  let hipY = finitePair(timeline.norm.y[norm.centerA][i], timeline.norm.y[norm.centerB][i]),
                  timeline.norm.x[norm.scaleA][i].isFinite, timeline.norm.x[norm.scaleB][i].isFinite
            else { continue }
            let sdx = timeline.norm.x[norm.scaleA][i] - timeline.norm.x[norm.scaleB][i]
            let sdy = timeline.norm.y[norm.scaleA][i] - timeline.norm.y[norm.scaleB][i]
            let scale = max((sdx * sdx + sdy * sdy).squareRoot(), norm.minScale)

            var c = [Double](repeating: 0, count: model.jointCount * 2)
            var measuredDim = [Bool](repeating: false, count: model.jointCount)
            var missing = 0
            for j in 0..<model.jointCount {
                if j < joints, timeline.norm.x[j][i].isFinite, timeline.norm.y[j][i].isFinite {
                    c[2 * j] = (timeline.norm.x[j][i] - hipX) / scale
                    c[2 * j + 1] = (timeline.norm.y[j][i] - hipY) / scale
                    measuredDim[j] = true
                } else {
                    // A never-measured joint is scored at the mixture mean so
                    // it neither drags the likelihood down nor gets written.
                    c[2 * j] = mixtureMean[2 * j]
                    c[2 * j + 1] = mixtureMean[2 * j + 1]
                    missing += 1
                }
            }
            guard missing <= config.maxMissingJoints else { continue }

            qc.gmmFramesEvaluated += 1
            let (logLik, bestComponent) = score(c)
            guard logLik < model.logLikelihoodThreshold else { continue }

            // Trust-region step toward the most responsible component.
            let target = model.means[bestComponent]
            let worldScale = worldShoulderWidth(timeline, i: i)
            var corrected = false
            for j in 0..<model.jointCount where measuredDim[j] && j < joints {
                var dx = (target[2 * j] - c[2 * j]) * config.pullWeight
                var dy = (target[2 * j + 1] - c[2 * j + 1]) * config.pullWeight
                let mag = (dx * dx + dy * dy).squareRoot()
                if mag > config.maxJointStep {
                    let k = config.maxJointStep / mag
                    dx *= k
                    dy *= k
                }
                guard abs(dx) > 1e-9 || abs(dy) > 1e-9 else { continue }
                // Back out of the canonical frame into image space.
                timeline.norm.x[j][i] += dx * scale
                timeline.norm.y[j][i] += dy * scale
                // Lockstep: the same canonical step, in metres.
                if let ws = worldScale,
                   timeline.world.x[j][i].isFinite, timeline.world.y[j][i].isFinite {
                    timeline.world.x[j][i] += dx * ws
                    timeline.world.y[j][i] += dy * ws
                }
                corrected = true
            }
            if corrected { qc.gmmCorrections += 1 }
        }
    }

    private func finitePair(_ a: Double, _ b: Double) -> Double? {
        guard a.isFinite, b.isFinite else { return nil }
        return (a + b) / 2
    }

    private func worldShoulderWidth(_ timeline: PoseTimeline, i: Int) -> Double? {
        let a = Landmarks.LEFT_SHOULDER, b = Landmarks.RIGHT_SHOULDER
        guard timeline.world.x[a][i].isFinite, timeline.world.x[b][i].isFinite else { return nil }
        let dx = timeline.world.x[a][i] - timeline.world.x[b][i]
        let dy = timeline.world.y[a][i] - timeline.world.y[b][i]
        let dz = (timeline.world.z[a][i].isFinite && timeline.world.z[b][i].isFinite)
            ? timeline.world.z[a][i] - timeline.world.z[b][i] : 0
        let w = (dx * dx + dy * dy + dz * dz).squareRoot()
        return w > 0.05 ? w : nil
    }

    /// Total log-likelihood under the mixture, and the index of the most
    /// responsible component (which for shared data is the component with
    /// the largest weighted density).
    private func score(_ x: [Double]) -> (logLikelihood: Double, bestComponent: Int) {
        var componentLogs = [Double](repeating: 0, count: model.weights.count)
        var best = 0
        for k in 0..<model.weights.count {
            var quad = 0.0
            let mean = model.means[k], varc = model.variances[k]
            for d in 0..<x.count {
                let r = x[d] - mean[d]
                quad += r * r / max(varc[d], 1e-12)
            }
            componentLogs[k] = logWeights[k] + logNormalizers[k] - 0.5 * quad
            if componentLogs[k] > componentLogs[best] { best = k }
        }
        // logsumexp for the total.
        let m = componentLogs[best]
        let total = m + Foundation.log(componentLogs.reduce(0) { $0 + exp($1 - m) })
        return (total, best)
    }
}

// MARK: - The corrector

public final class PosePriorCorrector {

    public struct Config {
        /// Bone-length projection: relative deviation past this triggers a
        /// projection, and the length moves this fraction of the way back to
        /// the clip median. A blend, not a snap, so a genuinely odd frame is
        /// nudged rather than redrawn.
        public var boneTolerance: Double = 0.10
        public var boneBlend: Double = 0.3
        /// Fold guard: an interior elbow or knee angle below this is not a
        /// human arm or leg, whatever the tracker says.
        public var foldMinAngleDeg: Double = 8
        public var foldBlend: Double = 0.3
        /// Fix 1: torso width and ratio constraints. World shoulder and hip
        /// widths past the tolerance are projected toward the clip median;
        /// in both spaces a shoulder to hip ratio past the tolerance is
        /// corrected. The brief's ten percent, the bone stage's blend.
        public var torsoWidthTolerance: Double = 0.10
        public var torsoRatioTolerance: Double = 0.10
        public var torsoBlend: Double = 0.6
        /// Fix 4 (extended): the ground plane stage's knobs.
        public var ground = GroundPlaneConfig()
        /// Fix S: the shoulder occlusion projection's knobs.
        public var shoulder = ShoulderProjectionConfig()
        /// Kinematic wrist-to-palm distance guard (Video 1 impact fix).
        public var handCollapse = HandCollapseGuardConfig()
        public init() {}
    }

    private let config: Config
    private let sides: Sides
    private let gmm: GMMPosePrior?

    /*
      The lead wrist's normalised track, aligned to the timeline grid, NaN
      where the wrist was never measured. Kept on the corrector so
      HandPathBuilder's wiring is unchanged. With both the midpoint magnet
      and grip fusion now gone, this is simply the corrected lead wrist: it
      is the measured wrist through every stage of the corrector, and no
      later step turns it into a fused grip, so what the trace draws and
      what the skeleton draws are the same point.
    */
    public private(set) var leadHandPathNormX: [Double] = []
    public private(set) var leadHandPathNormY: [Double] = []

    public init(config: Config = Config(), dominantHand: DominantHand, gmm: GMMPosePrior?) {
        self.config = config
        self.sides = Landmarks.sides(dominantHand)
        self.gmm = gmm
    }

    /// The v1 analytic corrector the upload pipeline constructs. The GMM
    /// stage rides along automatically once a trained pose_gmm.json ships in
    /// the bundle, and costs nothing until then.
    public static func analytic(dominantHand: DominantHand) -> PosePriorCorrector {
        PosePriorCorrector(dominantHand: dominantHand, gmm: GMMPosePrior.loadFromBundle())
    }

    public func run(_ timeline: inout PoseTimeline, qc: inout TrackingQC) {
        guard timeline.frameCount > 2 else { return }
        projectBoneLengths(&timeline, qc: &qc)
        projectOccludedShoulders(&timeline, qc: &qc)    // Fix S, BEFORE the torso
                                                        // stage so its symmetric
                                                        // scaling never splits an
                                                        // occlusion error with
                                                        // the good shoulder
        enforceBiomechanicalRatios(&timeline, qc: &qc)  // Fix 1, after the bones
        relaxImpossibleFolds(&timeline, qc: &qc)
        applyGroundConstraints(&timeline, qc: &qc)      // Fix 4 extended, feet only
        enforceHandSeparation(&timeline, qc: &qc)       // Video 1 fix
        gmm?.run(&timeline, qc: &qc)                    // TASK 5, when a model ships

        // The hand path anchor: the corrected lead wrist. With grip fusion
        // removed there is no fusion step after this, so the wrist stays the
        // measured lead wrist all the way to the frames the pipeline emits;
        // this capture simply mirrors it onto the corrector for any caller
        // (the hand path builder) that reads the anchor rather than the
        // frame. Value-type arrays, so these are true copies.
        let leadWrist = sides.leadWrist
        if leadWrist < timeline.jointCount {
            leadHandPathNormX = timeline.norm.x[leadWrist]
            leadHandPathNormY = timeline.norm.y[leadWrist]
        } else {
            leadHandPathNormX = []
            leadHandPathNormY = []
        }
    }

    // MARK: - Bone-length projection

    /// Limb bones, proximal to distal, so a corrected elbow is already in
    /// place when the elbow-to-wrist bone is checked.
    private static let bones: [(a: Int, b: Int)] = [
        (Landmarks.LEFT_SHOULDER, Landmarks.LEFT_ELBOW),
        (Landmarks.LEFT_ELBOW, Landmarks.LEFT_WRIST),
        (Landmarks.RIGHT_SHOULDER, Landmarks.RIGHT_ELBOW),
        (Landmarks.RIGHT_ELBOW, Landmarks.RIGHT_WRIST),
        (Landmarks.LEFT_HIP, Landmarks.LEFT_KNEE),
        (Landmarks.LEFT_KNEE, Landmarks.LEFT_ANKLE),
        (Landmarks.RIGHT_HIP, Landmarks.RIGHT_KNEE),
        (Landmarks.RIGHT_KNEE, Landmarks.RIGHT_ANKLE),
    ]

    /*
      Bones do not change length mid swing; the tracker's do. Each limb
      bone's clip-median metric length is taken as this golfer's true length,
      and any frame whose bone deviates past tolerance has its DISTAL end
      slid along the measured bone direction toward that length. The
      direction was measured, only the length is corrected, and only
      partially. WORLD SPACE ONLY, on purpose: metric bone length is pose
      invariant, while image-space length legitimately collapses under
      foreshortening, so projecting the normalised set to a median image
      length would break every forearm that points at the camera. The two
      spaces cannot disagree about missingness because nothing here creates
      or removes samples.
    */
    private func projectBoneLengths(_ timeline: inout PoseTimeline, qc: inout TrackingQC) {
        var correctedFrames = Set<Int>()

        for bone in Self.bones {
            guard bone.b < timeline.jointCount else { continue }
            let n = timeline.frameCount

            func length(_ i: Int) -> Double? {
                let ax = timeline.world.x[bone.a][i], ay = timeline.world.y[bone.a][i]
                let bx = timeline.world.x[bone.b][i], by = timeline.world.y[bone.b][i]
                guard ax.isFinite, bx.isFinite else { return nil }
                let az = timeline.world.z[bone.a][i], bz = timeline.world.z[bone.b][i]
                let dz = (az.isFinite && bz.isFinite) ? az - bz : 0
                let dx = ax - bx, dy = ay - by
                let l = (dx * dx + dy * dy + dz * dz).squareRoot()
                return l > 1e-6 ? l : nil
            }

            var lengths: [Double] = []
            for i in 0..<n { if let l = length(i) { lengths.append(l) } }
            guard lengths.count > 8 else { continue }
            lengths.sort()
            let median = lengths[lengths.count / 2]
            guard median > 1e-6 else { continue }

            for i in 0..<n {
                guard let l = length(i), abs(l - median) / median > config.boneTolerance else { continue }
                let target = Geometry.lerp(l, median, config.boneBlend)
                let k = target / l
                let ax = timeline.world.x[bone.a][i], ay = timeline.world.y[bone.a][i]
                let az = timeline.world.z[bone.a][i]
                timeline.world.x[bone.b][i] = ax + (timeline.world.x[bone.b][i] - ax) * k
                timeline.world.y[bone.b][i] = ay + (timeline.world.y[bone.b][i] - ay) * k
                if az.isFinite, timeline.world.z[bone.b][i].isFinite {
                    timeline.world.z[bone.b][i] = az + (timeline.world.z[bone.b][i] - az) * k
                }
                correctedFrames.insert(i)
            }
        }
        qc.priorBoneCorrections += correctedFrames.count
    }

    // MARK: - Shoulder occlusion projection (Fix S)

    /*
      See ShoulderProjectionConfig for the model and its reasoning. Per
      space, per shoulder, in that space's own image-plane geometry:

        1. Learn the rigid torso from confident frames: for each shoulder,
           the median radius from the hip centre and the circular-median
           angular offset from the hip-to-other-shoulder direction.
        2. On a frame where one shoulder sits under the occlusion bar while
           the other shoulder and both hips clear the anchor bar, place the
           occluded shoulder at the learned radius and offset from the
           visible shoulder's measured direction, and blend it halfway
           there.

      Depth is never touched. Frames are counted once into
      qc.shoulderProjectionFrames however many spaces or shoulders fired,
      matching how the bone projection counts.
    */
    private func projectOccludedShoulders(_ timeline: inout PoseTimeline, qc: inout TrackingQC) {
        let c = config.shoulder
        guard c.enabled, timeline.frameCount > 8 else { return }

        let ls = Landmarks.LEFT_SHOULDER, rs = Landmarks.RIGHT_SHOULDER
        let lh = Landmarks.LEFT_HIP, rh = Landmarks.RIGHT_HIP
        guard max(ls, rs, lh, rh) < timeline.jointCount else { return }

        let n = timeline.frameCount
        var correctedFrames = Set<Int>()

        for space in [PoseSpace.norm, PoseSpace.world] {
            var bank = timeline.channels(space)

            // House convention: NaN visibility means the backend reported
            // none, which reads as trusted, so the stage is inert on the
            // Vision backend.
            func vis(_ j: Int, _ i: Int) -> Double {
                let v = bank.visibility[j][i]
                return v.isFinite ? v : 1
            }
            func finite2(_ j: Int, _ i: Int) -> Bool {
                bank.x[j][i].isFinite && bank.y[j][i].isFinite
            }
            func hipCentre(_ i: Int) -> (x: Double, y: Double)? {
                guard finite2(lh, i), finite2(rh, i) else { return nil }
                return ((bank.x[lh][i] + bank.x[rh][i]) / 2,
                        (bank.y[lh][i] + bank.y[rh][i]) / 2)
            }

            // Both orientations of the same model: (occluded, anchor).
            for (occl, anchor) in [(ls, rs), (rs, ls)] {

                // 1. Learn the rigid torso from confident frames.
                var radii: [Double] = []
                var sinSum = 0.0, cosSum = 0.0
                var deltas: [Double] = []
                for i in 0..<n {
                    guard finite2(occl, i), finite2(anchor, i), let h = hipCentre(i),
                          vis(occl, i) >= c.anchorMinVisibility,
                          vis(anchor, i) >= c.anchorMinVisibility,
                          vis(lh, i) >= c.anchorMinVisibility,
                          vis(rh, i) >= c.anchorMinVisibility else { continue }
                    let ox = bank.x[occl][i] - h.x, oy = bank.y[occl][i] - h.y
                    let ax = bank.x[anchor][i] - h.x, ay = bank.y[anchor][i] - h.y
                    let r = (ox * ox + oy * oy).squareRoot()
                    guard r > 1e-6, (ax * ax + ay * ay).squareRoot() > 1e-6 else { continue }
                    let delta = atan2(oy, ox) - atan2(ay, ax)
                    radii.append(r)
                    deltas.append(delta)
                    sinSum += sin(delta)
                    cosSum += cos(delta)
                }
                guard radii.count > 8 else { continue }

                radii.sort()
                let medianRadius = radii[radii.count / 2]
                guard medianRadius > 1e-6 else { continue }

                // Circular median of the angular offset: wrap every sample
                // into the half-turn window around the circular mean, then
                // take the ordinary median, which is robust to the odd
                // mistracked frame the mean alone is not.
                let circularMean = atan2(sinSum, cosSum)
                var wrapped = deltas.map { d -> Double in
                    var w = d - circularMean
                    while w > .pi { w -= 2 * .pi }
                    while w < -.pi { w += 2 * .pi }
                    return w
                }
                wrapped.sort()
                let medianDelta = circularMean + wrapped[wrapped.count / 2]

                // 2. Project on occluded frames with confident anchors.
                for i in 0..<n {
                    guard finite2(occl, i), finite2(anchor, i), let h = hipCentre(i),
                          vis(occl, i) < c.occludedBelow,
                          vis(anchor, i) >= c.anchorMinVisibility,
                          vis(lh, i) >= c.anchorMinVisibility,
                          vis(rh, i) >= c.anchorMinVisibility else { continue }
                    let ax = bank.x[anchor][i] - h.x, ay = bank.y[anchor][i] - h.y
                    guard (ax * ax + ay * ay).squareRoot() > 1e-6 else { continue }
                    let theta = atan2(ay, ax) + medianDelta
                    let impliedX = h.x + medianRadius * cos(theta)
                    let impliedY = h.y + medianRadius * sin(theta)
                    bank.x[occl][i] += c.blend * (impliedX - bank.x[occl][i])
                    bank.y[occl][i] += c.blend * (impliedY - bank.y[occl][i])
                    correctedFrames.insert(i)
                }
            }
            timeline.setChannels(space, bank)
        }

        qc.shoulderProjectionFrames += correctedFrames.count
    }

    // MARK: - Torso width and ratio constraints (Fix 1)

    /*
      Shoulder width (11 to 12) and hip width (23 to 24) are body constants
      the raw tracker does not honour, and down the line the depth channel's
      noise makes them drift visibly through the rotation. Two rules:

      WORLD WIDTHS toward the median. Metric widths are pose invariant, the
      same argument the limb bone projection makes, so any frame whose world
      shoulder or hip width deviates past tolerance is scaled back toward the
      clip median. The scaling is SYMMETRIC about the segment midpoint, which
      is the difference from the limb projection: a limb bone has a proximal
      anchor and a distal end to move, but shoulders and hips have neither,
      and moving one side only would shove the whole torso sideways. The
      midpoint (the body centre line) stays exactly where it was measured.

      THE RATIO in both spaces. Image-space widths legitimately collapse
      under foreshortening, so an absolute norm-space width constraint would
      fight every real rotation, the same trap the bone projection's header
      warns about. But when the torso rotates, BOTH projected widths shrink
      together and their ratio survives; when the tracker glitches, one
      width collapses and the other does not, and the ratio spikes. So the
      ratio is the criterion that sees the glitch and ignores the rotation.
      A frame past tolerance is corrected toward the median ratio while
      PRESERVING the product of the two widths, so the frame's overall
      foreshortening level is kept and only the disagreement between the
      two widths is repaired:

          s' = sqrt(s * h * R_median)      h' = sqrt(s * h / R_median)

      then blended partially, the house style: nudged, not redrawn.
    */
    private func enforceBiomechanicalRatios(_ timeline: inout PoseTimeline, qc: inout TrackingQC) {
        let ls = Landmarks.LEFT_SHOULDER, rs = Landmarks.RIGHT_SHOULDER
        let lh = Landmarks.LEFT_HIP, rh = Landmarks.RIGHT_HIP
        guard max(ls, rs, lh, rh) < timeline.jointCount else { return }
        let n = timeline.frameCount

        func width(_ bank: PoseTimeline.Channels, _ a: Int, _ b: Int, _ i: Int, threeD: Bool) -> Double? {
            guard bank.x[a][i].isFinite, bank.y[a][i].isFinite,
                  bank.x[b][i].isFinite, bank.y[b][i].isFinite else { return nil }
            let dx = bank.x[a][i] - bank.x[b][i]
            let dy = bank.y[a][i] - bank.y[b][i]
            var d2 = dx * dx + dy * dy
            if threeD, bank.z[a][i].isFinite, bank.z[b][i].isFinite {
                let dz = bank.z[a][i] - bank.z[b][i]
                d2 += dz * dz
            }
            let w = d2.squareRoot()
            return w > 1e-6 ? w : nil
        }

        /// Scale the segment (a, b) about its midpoint by k, in this bank.
        /// Depth participates only when both ends carry it, so a 2D space
        /// stays 2D, the hand collapse guard's rule.
        func scaleAboutMidpoint(
            _ bank: inout PoseTimeline.Channels, _ a: Int, _ b: Int, _ i: Int, k: Double, threeD: Bool
        ) {
            let mx = (bank.x[a][i] + bank.x[b][i]) / 2
            let my = (bank.y[a][i] + bank.y[b][i]) / 2
            for j in [a, b] {
                bank.x[j][i] = mx + (bank.x[j][i] - mx) * k
                bank.y[j][i] = my + (bank.y[j][i] - my) * k
            }
            if threeD, bank.z[a][i].isFinite, bank.z[b][i].isFinite {
                let mz = (bank.z[a][i] + bank.z[b][i]) / 2
                for j in [a, b] {
                    bank.z[j][i] = mz + (bank.z[j][i] - mz) * k
                }
            }
        }

        func median(_ values: [Double]) -> Double? {
            guard values.count > 8 else { return nil }
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }

        // Rule 1: world widths toward their own clip medians.
        var widthFrames = Set<Int>()
        var worldBank = timeline.channels(.world)
        for pair in [(ls, rs), (lh, rh)] {
            var widths: [Double] = []
            for i in 0..<n { if let w = width(worldBank, pair.0, pair.1, i, threeD: true) { widths.append(w) } }
            guard let med = median(widths), med > 1e-6 else { continue }
            for i in 0..<n {
                guard let w = width(worldBank, pair.0, pair.1, i, threeD: true),
                      abs(w - med) / med > config.torsoWidthTolerance else { continue }
                let target = Geometry.lerp(w, med, config.torsoBlend)
                scaleAboutMidpoint(&worldBank, pair.0, pair.1, i, k: target / w, threeD: true)
                widthFrames.insert(i)
            }
        }
        timeline.setChannels(.world, worldBank)
        qc.torsoWidthCorrections += widthFrames.count

        // Rule 2: the ratio, each space with its own geometry and median.
        // World is 3D here and norm is 2D, matching how each space defines
        // a width everywhere else in this file.
        var ratioFrames = Set<Int>()
        for space in [PoseSpace.norm, PoseSpace.world] {
            let threeD = space == .world
            var bank = timeline.channels(space)

            var ratios: [Double] = []
            for i in 0..<n {
                guard let s = width(bank, ls, rs, i, threeD: threeD),
                      let h = width(bank, lh, rh, i, threeD: threeD) else { continue }
                ratios.append(s / h)
            }
            guard let medRatio = median(ratios), medRatio > 1e-6 else { continue }

            for i in 0..<n {
                guard let s = width(bank, ls, rs, i, threeD: threeD),
                      let h = width(bank, lh, rh, i, threeD: threeD) else { continue }
                let ratio = s / h
                guard abs(ratio - medRatio) / medRatio > config.torsoRatioTolerance else { continue }

                // Product-preserving targets, then the partial blend.
                let product = s * h
                let idealS = (product * medRatio).squareRoot()
                let idealH = (product / medRatio).squareRoot()
                let targetS = Geometry.lerp(s, idealS, config.torsoBlend)
                let targetH = Geometry.lerp(h, idealH, config.torsoBlend)
                scaleAboutMidpoint(&bank, ls, rs, i, k: targetS / s, threeD: threeD)
                scaleAboutMidpoint(&bank, lh, rh, i, k: targetH / h, threeD: threeD)
                ratioFrames.insert(i)
            }
            timeline.setChannels(space, bank)
        }
        qc.torsoRatioCorrections += ratioFrames.count
    }

    // MARK: - Ground plane (Fix 4)

    /// The turf, one estimate per side per space. Levels are y values in
    /// that space; up is +1 when height above ground grows with y and -1
    /// when it grows against y (image space, where up is smaller y).
    struct GroundPlaneEstimate {
        var leftLevel: Double
        var rightLevel: Double
        /// Multiply (level - y) by this to get height above the plane.
        var up: Double
        /// The clip-median shin length in this space's units, the yardstick
        /// every threshold scales from.
        var shin: Double
        /// The ankle's own resting level per side (occlusion overhaul): the
        /// toward-ground percentile of that ankle's y across the clip, the
        /// same robust estimate the turf uses. Nil when the ankle never
        /// produced enough samples, in which case the anchor does not run
        /// on that side and the turf clamp alone protects it.
        var leftAnkleLevel: Double?
        var rightAnkleLevel: Double?
    }

    /*
      Estimate the plane for one space from the clip's own feet. Returns nil
      when the clip never produced enough foot samples to trust, in which
      case the constraint stage simply does not run, the honest fallback.
    */
    func estimateGroundPlane(_ bank: PoseTimeline.Channels, frameCount: Int, jointCount: Int) -> GroundPlaneEstimate? {
        let feet: [(heel: Int, toe: Int, ankle: Int, knee: Int, hip: Int)] = [
            (Landmarks.LEFT_HEEL, Landmarks.LEFT_FOOT_INDEX, Landmarks.LEFT_ANKLE, Landmarks.LEFT_KNEE, Landmarks.LEFT_HIP),
            (Landmarks.RIGHT_HEEL, Landmarks.RIGHT_FOOT_INDEX, Landmarks.RIGHT_ANKLE, Landmarks.RIGHT_KNEE, Landmarks.RIGHT_HIP),
        ]
        guard feet.allSatisfy({ max($0.heel, $0.toe, $0.ankle, $0.knee, $0.hip) < jointCount }) else { return nil }

        func finite(_ j: Int, _ i: Int) -> Bool { bank.x[j][i].isFinite && bank.y[j][i].isFinite }

        // The shin yardstick and the hip reference, pooled over both sides.
        var shins: [Double] = []
        var hipYs: [Double] = []
        var footYsPooled: [Double] = []
        for side in feet {
            for i in 0..<frameCount {
                if finite(side.knee, i), finite(side.ankle, i) {
                    let dx = bank.x[side.knee][i] - bank.x[side.ankle][i]
                    let dy = bank.y[side.knee][i] - bank.y[side.ankle][i]
                    let l = (dx * dx + dy * dy).squareRoot()
                    if l > 1e-6 { shins.append(l) }
                }
                if finite(side.hip, i) { hipYs.append(bank.y[side.hip][i]) }
                if finite(side.heel, i) { footYsPooled.append(bank.y[side.heel][i]) }
            }
        }
        guard shins.count > 8, hipYs.count > 8, footYsPooled.count > 8 else { return nil }
        shins.sort(); hipYs.sort(); footYsPooled.sort()
        let shin = shins[shins.count / 2]
        let hipMedianY = hipYs[hipYs.count / 2]
        let footMedianY = footYsPooled[footYsPooled.count / 2]
        guard shin > 1e-6, abs(hipMedianY - footMedianY) > 1e-6 else { return nil }

        // Which way is up: the hips sit above the feet, whatever the axis
        // convention. In image space hips have SMALLER y, so up = -1 there.
        let up: Double = hipMedianY < footMedianY ? -1 : 1

        // Per side turf level: the toward-ground 75th percentile of that
        // foot's pooled heel and toe y. Lifted-heel frames sit on the
        // away-from-ground side of the distribution and cannot raise it;
        // the last quartile absorbs the occasional below-turf outlier.
        func level(_ side: (heel: Int, toe: Int, ankle: Int, knee: Int, hip: Int)) -> Double? {
            var ys: [Double] = []
            for i in 0..<frameCount {
                if finite(side.heel, i) { ys.append(bank.y[side.heel][i]) }
                if finite(side.toe, i) { ys.append(bank.y[side.toe][i]) }
            }
            guard ys.count > 8 else { return nil }
            // Sort so that the ground end comes last, then take the 75th
            // percentile toward it.
            ys.sort { up < 0 ? $0 < $1 : $0 > $1 }
            return ys[min(ys.count - 1, (ys.count * 3) / 4)]
        }
        guard let left = level(feet[0]), let right = level(feet[1]) else { return nil }

        // The ankle's own resting level, same robust construction as the
        // turf: toward-ground 75th percentile of that ankle's y. Planted
        // frames dominate the toward-ground end; lifted frames sit on the
        // far side and cannot pull the level up; the last quartile absorbs
        // the occasional sunk outlier this whole extension exists to stop.
        func ankleLevel(_ side: (heel: Int, toe: Int, ankle: Int, knee: Int, hip: Int)) -> Double? {
            var ys: [Double] = []
            for i in 0..<frameCount where finite(side.ankle, i) {
                ys.append(bank.y[side.ankle][i])
            }
            guard ys.count > 8 else { return nil }
            ys.sort { up < 0 ? $0 < $1 : $0 > $1 }
            return ys[min(ys.count - 1, (ys.count * 3) / 4)]
        }

        return GroundPlaneEstimate(
            leftLevel: left, rightLevel: right, up: up, shin: shin,
            leftAnkleLevel: ankleLevel(feet[0]), rightAnkleLevel: ankleLevel(feet[1])
        )
    }

    /*
      Apply the three rules from the GroundPlaneConfig note, per space with
      that space's own estimate and units, feet only, everything counted.
      Runs after the fold relaxation and before the hand stages because feet
      share no geometry with hands and the folds should see measured ankles.
    */
    private func applyGroundConstraints(_ timeline: inout PoseTimeline, qc: inout TrackingQC) {
        let c = config.ground
        guard c.enabled, timeline.frameCount > 8 else { return }

        let leadIsLeft = sides.leadWrist == Landmarks.LEFT_WRIST
        var snaps = 0
        var penetrations = 0
        var ankleAnchors = 0
        var liftLead = Set<Int>()
        var liftTrail = Set<Int>()
        var flattenedDepth = false

        for space in [PoseSpace.norm, PoseSpace.world] {
            var bank = timeline.channels(space)

            // Occlusion overhaul, depth flattening FIRST: MediaPipe's foot
            // depth is not a measurement worth keeping, so every foot
            // joint's z becomes its own clip median before any rule runs.
            // Never-measured samples stay NaN; a constant is written only
            // where a (noisy) value was, so the two spaces cannot disagree
            // about missingness. See the config note for why the median
            // and not the brief's literal zero.
            if c.flattenFootDepth {
                let footJoints = [
                    Landmarks.LEFT_HEEL, Landmarks.LEFT_FOOT_INDEX, Landmarks.LEFT_ANKLE,
                    Landmarks.RIGHT_HEEL, Landmarks.RIGHT_FOOT_INDEX, Landmarks.RIGHT_ANKLE,
                ]
                for j in footJoints where j < timeline.jointCount {
                    var zs: [Double] = []
                    for i in 0..<timeline.frameCount where bank.z[j][i].isFinite {
                        zs.append(bank.z[j][i])
                    }
                    guard zs.count > 8 else { continue }
                    zs.sort()
                    let medianZ = zs[zs.count / 2]
                    for i in 0..<timeline.frameCount where bank.z[j][i].isFinite {
                        bank.z[j][i] = medianZ
                    }
                    flattenedDepth = true
                }
            }

            guard let plane = estimateGroundPlane(bank, frameCount: timeline.frameCount, jointCount: timeline.jointCount) else {
                timeline.setChannels(space, bank)
                continue
            }

            let snapZone = c.snapZoneShinFraction * plane.shin
            let ankleZone = c.ankleSnapZoneShinFraction * plane.shin
            let liftBar = c.liftThresholdShinFraction * plane.shin
            let penetrationBar = c.penetrationToleranceShinFraction * plane.shin

            let footSides: [(heel: Int, toe: Int, ankle: Int, level: Double, ankleLevel: Double?, isLeft: Bool)] = [
                (Landmarks.LEFT_HEEL, Landmarks.LEFT_FOOT_INDEX, Landmarks.LEFT_ANKLE,
                 plane.leftLevel, plane.leftAnkleLevel, true),
                (Landmarks.RIGHT_HEEL, Landmarks.RIGHT_FOOT_INDEX, Landmarks.RIGHT_ANKLE,
                 plane.rightLevel, plane.rightAnkleLevel, false),
            ]

            for side in footSides {
                let anchoredAnkle: Double? = {
                    guard c.ankleAnchorEnabled, let level = side.ankleLevel else { return nil }
                    // Degenerate guard: an ankle level that landed below
                    // the turf estimate is noise stacked on noise, and an
                    // anchor there would pin the ankle underground. The
                    // plain turf clamp owns the ankle instead.
                    let heightAboveTurf = (side.level - level) * plane.up
                    return heightAboveTurf >= 0 ? level : nil
                }()

                for i in 0..<timeline.frameCount {
                    func heightAbove(_ j: Int, level: Double) -> Double? {
                        guard bank.y[j][i].isFinite else { return nil }
                        return (level - bank.y[j][i]) * plane.up
                    }

                    // Rule 1: nothing sinks below the turf. Heel and toe
                    // always; the ankle too when its own anchor is not
                    // running (rule 1b then owns it, with a stricter
                    // level). Only a penetration past the tolerance is
                    // clamped, so plane noise does not flatten a foot that
                    // is really planted.
                    var rule1Joints = [side.heel, side.toe]
                    if anchoredAnkle == nil { rule1Joints.append(side.ankle) }
                    for j in rule1Joints {
                        guard let h = heightAbove(j, level: side.level), h < -penetrationBar else { continue }
                        bank.y[j][i] = side.level
                        penetrations += 1
                    }

                    // Rule 1b (occlusion overhaul): the ankle anchor. The
                    // ankle is held near ITS OWN resting level, which sits
                    // above the turf by the joint's real height. Below the
                    // level past tolerance clamps up (this is the sinking
                    // ankle, caught before it reaches the turf); within
                    // the zone either side blends on (kills the hover and
                    // the jitter); clearly above is a lift and untouched.
                    if let level = anchoredAnkle,
                       let h = heightAbove(side.ankle, level: level) {
                        if h < -penetrationBar {
                            bank.y[side.ankle][i] = level
                            ankleAnchors += 1
                        } else if abs(h) <= ankleZone {
                            bank.y[side.ankle][i] = Geometry.lerp(bank.y[side.ankle][i], level, c.ankleSnapBlend)
                            ankleAnchors += 1
                        }
                    }

                    // Rule 2: anchor near-plane heels and toes. Ankles are
                    // exempt here: their anchor is rule 1b, at their own
                    // level, never the turf.
                    for j in [side.heel, side.toe] {
                        guard let h = heightAbove(j, level: side.level), h > 0, h <= snapZone else { continue }
                        bank.y[j][i] = Geometry.lerp(bank.y[j][i], side.level, c.snapBlend)
                        snaps += 1
                    }

                    // Rule 3: a clearly lifted heel is a real event. Count
                    // it, per lead and trail, and touch nothing. Counted
                    // once per frame across spaces via the sets.
                    if let h = heightAbove(side.heel, level: side.level), h > liftBar {
                        if side.isLeft == leadIsLeft { liftLead.insert(i) } else { liftTrail.insert(i) }
                    }
                }
            }
            timeline.setChannels(space, bank)
        }

        qc.groundPlaneSnaps += snaps
        qc.groundPenetrationsClamped += penetrations
        qc.ankleGroundAnchors += ankleAnchors
        qc.heelLiftFramesLead += liftLead.count
        qc.heelLiftFramesTrail += liftTrail.count
        if flattenedDepth { qc.footDepthFlattened = true }
    }

    // MARK: - Impossible folds

    private static let hingeJoints: [(a: Int, mid: Int, b: Int)] = [
        (Landmarks.LEFT_SHOULDER, Landmarks.LEFT_ELBOW, Landmarks.LEFT_WRIST),
        (Landmarks.RIGHT_SHOULDER, Landmarks.RIGHT_ELBOW, Landmarks.RIGHT_WRIST),
        (Landmarks.LEFT_HIP, Landmarks.LEFT_KNEE, Landmarks.LEFT_ANKLE),
        (Landmarks.RIGHT_HIP, Landmarks.RIGHT_KNEE, Landmarks.RIGHT_ANKLE),
    ]

    /*
      No elbow or knee closes past a few degrees. A frame where the tracker
      says one did is a distal joint sitting on the wrong side of its hinge,
      and the honest fix is to relax that joint toward its own trajectory,
      the mean of its temporal neighbours, rather than toward any template.
    */
    private func relaxImpossibleFolds(_ timeline: inout PoseTimeline, qc: inout TrackingQC) {
        var correctedFrames = Set<Int>()
        let n = timeline.frameCount

        for hinge in Self.hingeJoints {
            guard hinge.b < timeline.jointCount else { continue }

            func vec(_ j: Int, _ i: Int) -> Vec3? {
                guard timeline.world.x[j][i].isFinite, timeline.world.y[j][i].isFinite else { return nil }
                let z = timeline.world.z[j][i]
                return Vec3(x: timeline.world.x[j][i], y: timeline.world.y[j][i], z: z.isFinite ? z : nil)
            }

            for i in 1..<(n - 1) {
                guard let a = vec(hinge.a, i), let m = vec(hinge.mid, i), let b = vec(hinge.b, i) else { continue }
                let angle = Geometry.jointAngle(a, m, b)
                guard angle < config.foldMinAngleDeg else { continue }
                guard let prev = vec(hinge.b, i - 1), let next = vec(hinge.b, i + 1) else { continue }
                let target = Geometry.v.mid(prev, next)
                timeline.world.x[hinge.b][i] = Geometry.lerp(b.x, target.x, config.foldBlend)
                timeline.world.y[hinge.b][i] = Geometry.lerp(b.y, target.y, config.foldBlend)
                if let bz = b.z, let tz = target.z, timeline.world.z[hinge.b][i].isFinite {
                    timeline.world.z[hinge.b][i] = Geometry.lerp(bz, tz, config.foldBlend)
                }
                correctedFrames.insert(i)
            }
        }
        qc.priorRangeCorrections += correctedFrames.count
    }

    // MARK: - Hand collapse guard (Video 1 impact fix)

    /// Both hands. The trail hand releases through impact, but a knuckle at
    /// zero distance from its own wrist is impossible on either side, and
    /// the guard's fire condition (collapsed AND fast) cannot trigger on a
    /// legitimate release, where the span stays healthy.
    private static let guardedArms: [(elbow: Int, wrist: Int, index: Int, pinky: Int)] = [
        (Landmarks.LEFT_ELBOW, Landmarks.LEFT_WRIST, Landmarks.LEFT_INDEX, Landmarks.LEFT_PINKY),
        (Landmarks.RIGHT_ELBOW, Landmarks.RIGHT_WRIST, Landmarks.RIGHT_INDEX, Landmarks.RIGHT_PINKY),
    ]

    /*
      See HandCollapseGuardConfig for the failure signature and the recorded
      deviations from the brief. One physical speed gate per arm (world
      preferred, norm fallback), then each space is corrected with its own
      medians, directions and units, so norm and world never trade
      geometry. Corrections count once per frame into
      qc.handCollapseCorrections however many arms or spaces fired,
      matching how the bone projection counts.

      NOTE FOR TrackingQC: this stage introduces the counter
      handCollapseCorrections. Add `public var handCollapseCorrections: Int
      = 0` to TrackingQC alongside the other prior counters.
    */
    private func enforceHandSeparation(_ timeline: inout PoseTimeline, qc: inout TrackingQC) {
        let c = config.handCollapse
        guard c.enabled, timeline.frameCount > 8 else { return }

        var correctedFrames = Set<Int>()

        for arm in Self.guardedArms {
            guard max(arm.elbow, arm.wrist, arm.index, arm.pinky) < timeline.jointCount else { continue }
            let fast = fastHandFrames(timeline, wrist: arm.wrist, config: c)

            for space in [PoseSpace.norm, PoseSpace.world] {
                var bank = timeline.channels(space)
                separateCollapsedHand(
                    &bank,
                    arm: arm,
                    isNormSpace: space == .norm,
                    fast: fast,
                    config: c,
                    correctedFrames: &correctedFrames
                )
                timeline.setChannels(space, bank)
            }
        }

        qc.handCollapseCorrections += correctedFrames.count
    }

    /*
      One answer per frame to "was this hand moving fast enough for the blur
      failure": world speed against the metric gate when the wrist carries
      world data around that frame, image-space speed against the norm gate
      otherwise. The larger of the backward and forward step speeds is used
      because impact peaks BETWEEN samples at 60 fps and a one-sided
      difference can halve it.
    */
    private func fastHandFrames(
        _ timeline: PoseTimeline, wrist: Int, config c: HandCollapseGuardConfig
    ) -> [Bool] {
        let n = timeline.frameCount
        var fast = [Bool](repeating: false, count: n)

        func stepSpeed(_ bank: PoseTimeline.Channels, _ i: Int, _ k: Int, threeD: Bool) -> Double? {
            guard bank.x[wrist][i].isFinite, bank.y[wrist][i].isFinite,
                  bank.x[wrist][k].isFinite, bank.y[wrist][k].isFinite
            else { return nil }
            let dt = abs(timeline.times[i] - timeline.times[k]) / 1000
            guard dt > 1e-4 else { return nil }
            let dx = bank.x[wrist][i] - bank.x[wrist][k]
            let dy = bank.y[wrist][i] - bank.y[wrist][k]
            var d2 = dx * dx + dy * dy
            if threeD, bank.z[wrist][i].isFinite, bank.z[wrist][k].isFinite {
                let dz = bank.z[wrist][i] - bank.z[wrist][k]
                d2 += dz * dz
            }
            return d2.squareRoot() / dt
        }

        for i in 0..<n {
            var worldSpeed: Double? = nil
            if i > 0, let s = stepSpeed(timeline.world, i, i - 1, threeD: true) { worldSpeed = s }
            if i + 1 < n, let s = stepSpeed(timeline.world, i, i + 1, threeD: true) {
                worldSpeed = Swift.max(worldSpeed ?? 0, s)
            }
            if let ws = worldSpeed {
                fast[i] = ws > c.minHandSpeedWorld
                continue
            }
            var normSpeed: Double? = nil
            if i > 0, let s = stepSpeed(timeline.norm, i, i - 1, threeD: false) { normSpeed = s }
            if i + 1 < n, let s = stepSpeed(timeline.norm, i, i + 1, threeD: false) {
                normSpeed = Swift.max(normSpeed ?? 0, s)
            }
            if let ns = normSpeed { fast[i] = ns > c.minHandSpeedNorm }
        }
        return fast
    }

    private func separateCollapsedHand(
        _ bank: inout PoseTimeline.Channels,
        arm: (elbow: Int, wrist: Int, index: Int, pinky: Int),
        isNormSpace: Bool,
        fast: [Bool],
        config c: HandCollapseGuardConfig,
        correctedFrames: inout Set<Int>
    ) {
        let n = fast.count

        func finite2(_ j: Int, _ i: Int) -> Bool {
            bank.x[j][i].isFinite && bank.y[j][i].isFinite
        }
        func palm(_ i: Int) -> (x: Double, y: Double, z: Double)? {
            guard finite2(arm.index, i), finite2(arm.pinky, i) else { return nil }
            let zi = bank.z[arm.index][i], zp = bank.z[arm.pinky][i]
            let z = (zi.isFinite && zp.isFinite) ? (zi + zp) / 2 : Double.nan
            return (
                x: (bank.x[arm.index][i] + bank.x[arm.pinky][i]) / 2,
                y: (bank.y[arm.index][i] + bank.y[arm.pinky][i]) / 2,
                z: z
            )
        }
        func dist(_ ax: Double, _ ay: Double, _ az: Double,
                  _ bx: Double, _ by: Double, _ bz: Double) -> Double {
            let dx = ax - bx, dy = ay - by
            let dz = (az.isFinite && bz.isFinite) ? az - bz : 0
            return (dx * dx + dy * dy + dz * dz).squareRoot()
        }

        // Clip medians in this space's own units: the hand span (wrist to
        // palm centre) and the forearm. Collapsed frames are a handful out
        // of hundreds, so the median shrugs them off.
        var handSpans: [Double] = []
        var forearms: [Double] = []
        for i in 0..<n {
            if finite2(arm.wrist, i), let p = palm(i) {
                handSpans.append(dist(
                    bank.x[arm.wrist][i], bank.y[arm.wrist][i], bank.z[arm.wrist][i],
                    p.x, p.y, p.z
                ))
            }
            if finite2(arm.elbow, i), finite2(arm.wrist, i) {
                let f = dist(
                    bank.x[arm.elbow][i], bank.y[arm.elbow][i], bank.z[arm.elbow][i],
                    bank.x[arm.wrist][i], bank.y[arm.wrist][i], bank.z[arm.wrist][i]
                )
                if f > 1e-6 { forearms.append(f) }
            }
        }
        guard handSpans.count > 8, forearms.count > 8 else { return }
        handSpans.sort()
        forearms.sort()
        let medianHand = handSpans[handSpans.count / 2]
        let medianForearm = forearms[forearms.count / 2]
        guard medianForearm > 1e-6 else { return }

        // The anatomical minimum the brief asked for, defined against the
        // clip-median forearm, then the working collapse threshold: never
        // wider than the minimum, the absolute 0.015 (norm space only), or
        // half this golfer's own healthy span.
        let minSeparation = c.minSeparationForearmFraction * medianForearm
        var threshold = minSeparation
        if isNormSpace { threshold = Swift.min(threshold, c.collapseDistanceNorm) }
        if medianHand > 1e-9 {
            threshold = Swift.min(threshold, c.collapseMedianFraction * medianHand)
        }
        guard threshold > 0 else { return }

        // What "restored" means: the golfer's own healthy median span when
        // the clip produced one, the anatomical fraction of the forearm
        // when it did not, never below the minimum either way.
        var target = medianHand > threshold
            ? medianHand
            : c.defaultSeparationForearmFraction * medianForearm
        target = Swift.max(target, minSeparation)

        for i in 0..<n where fast[i] {
            guard finite2(arm.wrist, i), finite2(arm.elbow, i), let p = palm(i) else { continue }
            let wx = bank.x[arm.wrist][i], wy = bank.y[arm.wrist][i], wz = bank.z[arm.wrist][i]
            let d = dist(wx, wy, wz, p.x, p.y, p.z)
            guard d < threshold else { continue }

            // Forearm direction, measured this frame. Depth participates
            // only when both ends carry it, so a 2D space stays 2D.
            let ex = bank.x[arm.elbow][i], ey = bank.y[arm.elbow][i], ez = bank.z[arm.elbow][i]
            var dx = wx - ex, dy = wy - ey
            let useZ = wz.isFinite && ez.isFinite && p.z.isFinite
            var dz = useZ ? wz - ez : 0
            let len = (dx * dx + dy * dy + dz * dz).squareRoot()
            guard len > 1e-6 else { continue }
            dx /= len; dy /= len; dz /= len

            // Translate the two knuckles together so their measured spread
            // survives; only the palm CENTRE is repositioned.
            let moveX = (wx + dx * target) - p.x
            let moveY = (wy + dy * target) - p.y
            for j in [arm.index, arm.pinky] where finite2(j, i) {
                bank.x[j][i] += moveX
                bank.y[j][i] += moveY
            }
            if useZ {
                let moveZ = (wz + dz * target) - p.z
                for j in [arm.index, arm.pinky] where bank.z[j][i].isFinite {
                    bank.z[j][i] += moveZ
                }
            }
            correctedFrames.insert(i)
        }
    }
}

// MARK: - Dataset logger (TASK 5, the data side)

/*
  Every learned prior in the deferred column (C, Q, F, L, N and the ML half
  of M) is blocked on one thing: a dataset of cleaned, tracked swings that
  does not exist yet. This logger makes it exist, one shipped upload at a
  time. It writes the refined normalised timeline plus its QC record to
  Application Support, fire and forget, capped so it can never eat the disk.

  Schema, version 2, one JSON file per swing:

    {
      "version": 2,
      "source": "upload",
      "createdAt": "2026-08-18T12:00:00Z",
      "gridHz": 60,
      "qc": { ...TrackingQC, Codable... },
      "frames": [ { "t": 0, "xy": [66 doubles], "vis": [33 doubles] }, ... ]
    }

  xy is the 33-joint normalised (x, y) pairs in landmark order; vis is
  visibility with -1 standing in for "backend reported none", because JSON
  cannot carry NaN. The QC record travelling alongside is what lets the
  training script keep only honestly tracked frames, so the future GMM never
  learns from gap fill.
*/
public enum SwingDatasetLogger {

    /// Oldest logs beyond this count are pruned on each write.
    public static var maxStoredSwings = 200

    private static let queue = DispatchQueue(label: "swingline.dataset-logger", qos: .utility)

    private struct FrameEntry: Encodable {
        var t: Double
        var xy: [Double]
        var vis: [Double]
    }

    private struct Entry: Encodable {
        var version = 2
        var source: String
        var createdAt: String
        var gridHz: Double
        var qc: TrackingQC
        var frames: [FrameEntry]
    }

    public static func log(frames: [Frame], qc: TrackingQC, source: String) {
        guard !frames.isEmpty else { return }
        queue.async {
            write(frames: frames, qc: qc, source: source)
        }
    }

    /// Where the dataset lives, for the export path that hands it to the
    /// training script. Created on demand.
    public static func directory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = base.appendingPathComponent("SwingDataset", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func write(frames: [Frame], qc: TrackingQC, source: String) {
        func round4(_ x: Double) -> Double { (x * 10000).rounded() / 10000 }

        var entries: [FrameEntry] = []
        entries.reserveCapacity(frames.count)
        for f in frames {
            var xy = [Double](repeating: 0, count: 66)
            var vis = [Double](repeating: -1, count: 33)
            for j in 0..<min(33, f.norm.count) {
                let l = f.norm[j]
                xy[2 * j] = l.x.isFinite ? round4(l.x) : 0
                xy[2 * j + 1] = l.y.isFinite ? round4(l.y) : 0
                if let v = l.visibility ?? l.score, v.isFinite {
                    vis[j] = (v * 1000).rounded() / 1000
                }
            }
            entries.append(FrameEntry(t: f.t, xy: xy, vis: vis))
        }

        let formatter = ISO8601DateFormatter()
        let entry = Entry(
            source: source,
            createdAt: formatter.string(from: Date()),
            gridHz: qc.gridHz,
            qc: qc,
            frames: entries
        )

        do {
            let dir = try directory()
            let name = "swing-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).json"
            let data = try JSONEncoder().encode(entry)
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
            prune(dir)
        } catch {
            // A failed log must never surface to the golfer; the swing
            // itself is untouched. Note it and move on.
            print("[SwingDatasetLogger] write failed: \(error)")
        }
    }

    private static func prune(_ dir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }
        let logs = files.filter { $0.pathExtension == "json" }
        guard logs.count > maxStoredSwings else { return }
        let dated = logs.compactMap { url -> (URL, Date)? in
            let d = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            return d.map { (url, $0) }
        }.sorted { $0.1 < $1.1 }
        for (url, _) in dated.prefix(dated.count - maxStoredSwings) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
