//
//  LandmarkCleanup.swift
//  Swingline
//
//  Deterministic landmark cleanup for the upload pipeline. Vectors H (per-clip
//  trust floor, corrected), T (visibility as a missing-data mask), M-rules
//  (velocity and bone-length outlier rejection), E-lite (arm-geometry
//  consistency as a wrist rejection test), the hand collapse rejection
//  (kinematic wrist-to-palm guard from the Video 1 audit, see the
//  CleanupConfig note), the wrist occlusion rejection (occlusion overhaul,
//  the removed midpoint magnet's replacement on the wrist, see the
//  CleanupConfig note) and B (deterministic gap fill, PCHIP for short gaps,
//  hold for long ones).
//
//  THE ONE RULE
//
//  This engine REJECTS data, it never invents it. Every check below can only
//  mark a sample as untrustworthy; the fill stage then bridges the hole from
//  the joint's own neighbouring measurements. Nothing is ever nudged toward a
//  template, a prior, or an ideal, because the interface downstream presents
//  these numbers as measurements and they have to stay measurements.
//
//  TWO CORRECTIONS TO THE RESEARCH BRIEF, recorded so they are not mistaken
//  for oversights:
//
//  1. "Velocity above three times the clip median" cannot be applied as
//     written. The wrist's median step is set by the long quiet stretches at
//     address, and its genuine speed through impact is easily twenty times
//     that median. A naive threshold would delete the downswing, which is the
//     one part of the clip this whole project exists to measure. The factor
//     is kept, but a sample is only rejected when it also shows the
//     out-and-back signature of a tracking glitch: a large jump away followed
//     by a return, with points either side sitting close together. A real
//     fast sweep keeps travelling; a glitch comes back.
//
//  2. "Bone deviation above eight percent of clip median" is kept as the
//     floor, but the working threshold adapts upward on clips whose bone
//     lengths wobble more than that frame to frame as a baseline, so a hazy
//     clip is not hollowed out and re-filled from its own noise. Bone checks
//     run in WORLD space only: metric bone length is pose invariant, while
//     image-space length legitimately collapses under foreshortening, so an
//     image-space check would reject every forearm that points at the camera.
//
//  3. "Wrist visibility under 0.6 is missing" (the occlusion overhaul brief)
//     is kept as the intent, but with a safety valve: on a clip where the
//     tracker reports mid confidence across most of the swing, a raw 0.6
//     bar would reject the majority of the wrist's samples and the fill
//     would replace the downswing with one long positional hold, the exact
//     frozen-limb failure the trust floor's cap was lowered to stop. So the
//     bar adapts DOWN when it would reject more than a bounded fraction of
//     the wrist's measured samples, keeping the rejection aimed at the
//     worst tail (the occluded crossings the brief names) rather than at
//     the clip wholesale.
//
//  NORM AND WORLD IN LOCKSTEP
//
//  Detection runs in whichever space measures the fault best (velocity in
//  both, bones in world, arm geometry in image space), the resulting mask is
//  the union, and the wipe and the fill are applied to both spaces. The drawn
//  skeleton and the printed numbers therefore always agree about which
//  samples were measured and which were bridged.
//
//  House rule: no em dashes anywhere.
//

import Foundation

public struct CleanupConfig {

    /// Vector H. The per-clip trust floor is derived from the clip's own
    /// visibility distribution, clamped into this range so a supremely
    /// confident clip cannot set an impossible bar and a hazy one cannot
    /// disable the gate entirely.
    ///
    /// The cap came down from 0.45 after real-clip testing: on a cleanly
    /// tracked clip the derived floor reached the cap, and MediaPipe's
    /// perfectly usable estimates for an occluded trail leg (visibility 0.3
    /// to 0.45 through the downswing) were wiped wholesale and replaced with
    /// a long positional hold, which is how limbs froze and vanished around
    /// P5 to P7. A sample at 0.3 visibility is a rough measurement worth
    /// keeping and smoothing; only genuinely lost joints belong in the mask.
    public var trustFloorRange: ClosedRange<Double> = 0.12...0.28
    /// Fraction of the 25th-percentile visibility used as the floor.
    public var trustFloorScale: Double = 0.6

    /// M-rules. Velocity outlier factor over the joint's median step, plus an
    /// absolute floor per space so near-still joints do not self-reject on
    /// sensor noise. See header note 1 for the spike signature that gates it.
    public var velocityFactor: Double = 3.0
    public var minStepNorm: Double = 0.015     // fraction of image per grid step
    public var minStepWorld: Double = 0.04     // metres per grid step

    /// Bone-length tolerance floor (the brief's eight percent) and the robust
    /// adaptive factor over the bone's own deviation spread. See note 2.
    public var boneTolerance: Double = 0.08
    public var boneMadFactor: Double = 3.0

    /*
      Bone impossibility floor (round four, R5a). The proportional test
      above adapts its threshold to the clip's own wobble, which is right
      for jitter and wrong for catastrophe: on the audited face-on frames
      the occluded upper arm collapses to near zero length, those frames
      corrupt the surviving-length pool, the adaptive threshold inflates,
      and the very samples the check exists for sail through it. World
      space is metric, not projected, so no camera foreshortening can make
      a real limb bone measure under about half its own clip median: below
      the fraction here the sample is anatomically impossible, full stop,
      and no confidence figure or adaptive tolerance can excuse it. The
      per-bone cap keeps a clip whose median is itself corrupt from
      self-destructing; a capped-out clip degrades to flagged rather than
      starved, the same philosophy as the wrist valve above.
    */
    public var boneImpossibilityFloor: Bool = true
    /// A limb bone under this fraction of its clip median is impossible.
    /// 0.45: above 0.5 starts colliding with real crop-merge jitter, below
    /// 0.4 misses the audited elbow-on-shoulder frames.
    public var boneImpossibleFraction: Double = 0.45
    /// Per-clip sanity cap: at most this fraction of a bone's measured
    /// samples can be rejected by the floor.
    public var boneImpossibleMaxFraction: Double = 0.3

    /// E-lite. Elbow-angle rate limit in degrees per second; a wrist whose
    /// implied elbow angle spikes past this and snaps back is rejected.
    public var elbowAngleRateLimit: Double = 900

    /// Vector B. Interior gaps up to this many grid frames are bridged with a
    /// monotone cubic (PCHIP); anything longer, and the clip edges, hold the
    /// last known position rather than inventing a path.
    public var shortGapMax: Int = 4

    /// Visibility written onto filled samples. Short bridges inherit the
    /// weaker neighbour, scaled. Held spans sit in the renderer's dimmed band
    /// (above its 0.05 skip floor, below its 0.2 full floor), so a held limb
    /// draws faded rather than vanishing, which is the honest picture: the
    /// position is a hold, not a measurement, and the golfer can see both
    /// facts at once.
    public var shortFillVisibilityScale: Double = 0.95
    public var unknownFillVisibility: Double = 0.5
    public var heldVisibility: Double = 0.12

    /*
      The kinematic hand-collapse guard, REJECTION FORM (Video 1 fix). At
      hand speeds past the gate, motion blur makes MediaPipe collapse the
      index and pinky knuckles onto the wrist: measured wrist-to-palm
      distance 0.000 against a healthy 0.022 to 0.028 normalised. Those
      samples carry no information about where the palm actually was, so
      under this engine's ONE RULE the honest move is rejection: the two
      knuckles are flagged (never the wrist, which stays anchored to the
      forearm chain and its own bone checks) and the standard gap fill
      bridges them from healthy neighbours, which at a one-to-three frame
      impact collapse is a better trajectory than any reconstruction.

      PosePriorCorrector carries the same guard in reconstruction form as a
      backstop for whatever survives to that stage; between the two, this
      one runs first and does most of the work. The threshold scales with
      the clip's own median span so a small-in-frame golfer is judged by
      their own geometry, not an absolute constant. The speed gate keeps
      legitimate slow-motion foreshortening (a palm aimed at the lens at
      address) untouched: that collapses the 2D distance honestly, but not
      at four metres per second.
    */
    public var handCollapseRejection: Bool = true
    /// Absolute collapse ceiling in normalised space (the brief's 0.015).
    public var handCollapseDistanceNorm: Double = 0.015
    /// Relative ceiling: this fraction of the clip-median hand span.
    public var handCollapseMedianFraction: Double = 0.5
    /// Speed gate against world wrist speed, metres per second.
    public var handCollapseSpeedWorld: Double = 4.0
    /// Fallback speed gate in normalised frame units per second when the
    /// wrist carries no world channel.
    public var handCollapseSpeedNorm: Double = 1.2

    /*
      Wrist occlusion rejection (occlusion overhaul). The removed midpoint
      magnet's replacement on the wrist, in this engine's own species:
      rejection, never invention. MediaPipe pulls an occluded wrist toward
      the elbow or the palm while still reporting mid confidence, so the
      wrong position cannot be repaired, only refused. A wrist sample under
      the visibility bar is masked as missing, and the standard fill then
      does exactly what the brief asks: interior holes of one to four grid
      frames are bridged from the last and next known positions (PCHIP
      through two anchors, the shape-preserving form of the brief's linear
      interpolation, which cannot overshoot); longer holes and clip edges
      hold the last known position. Filled samples carry the honest dimmed
      visibility, so a bridged wrist draws faded rather than lying.

      Both wrists, on purpose: the brief names the lead wrist, but the
      trail wrist crosses the same occlusions mirrored, and after grip
      fusion the two are one point anyway. On the Vision backend there is
      no per-joint visibility and the stage is inert, the honest behaviour.
      See header correction 3 for the adaptive bar.
    */
    public var wristOcclusionRejection: Bool = true
    /// The brief's 0.6: a wrist sample whose visibility sits below this is
    /// rejected as missing.
    public var wristVisibilityFloor: Double = 0.6
    /// Header correction 3, the safety valve: if the raw floor would
    /// reject more than this fraction of a wrist's measured samples, the
    /// floor adapts down to the visibility quantile that rejects exactly
    /// this fraction, so the rejection trims the occluded tail without
    /// hollowing the clip into one long hold.
    public var wristRejectionMaxFraction: Double = 0.35

    /*
      Arm identity rejection (round four, R5b and R5c). The face-on audit's
      worst frames are not noise but mistaken identity: the occluded side's
      wrist reported sitting ON the other arm, the elbow cross-linked onto
      the other tricep, all at confident-looking positions no geometric
      smoother can repair.

      The naive predicate, "reject the left wrist when it is nearer the
      right elbow than the left elbow", is WRONG for golf: with two hands
      on one grip, dist(leadWrist, trailElbow) is comparable to
      dist(leadWrist, leadElbow) for most of a normal swing, so the naive
      test convicts the gripped pose it exists to protect. The golf-aware
      wrist predicate therefore requires ALL of: (1) the cross distance
      under a STRICT fraction of the own-forearm distance, strict because
      at a normal grip the two are comparable and only a wrist genuinely
      sitting on the other arm gets this close; (2) the own forearm length
      that frame outside the bone tolerance band, so the chain is already
      demonstrably broken; and (3) visibility under the bar here, so a
      hard-confident sample is left for the impossibility floor to judge
      rather than second-guessed on geometry alone. The wrist is rejected,
      never the elbow it was measured against: the wrist is the distal,
      replaceable end.

      The elbow mirror (R5c) convicts a cross-linked elbow the same way:
      distance to the OTHER side's upper-arm segment under a fraction of
      an upper-arm length, while this side's own shoulder-elbow-wrist
      chain length that frame exceeds its clip median by the excess factor
      (a real elbow cannot both touch the other tricep and keep its own
      chain plausible), and visibility under the same bar.

      On the Vision backend visibility is NaN, NaN reads trusted (the
      house convention), condition (3) never holds, and the stage is
      inert, which is honest. Both rejections are capped per joint per
      clip and counted, the round-one valve philosophy: a catastrophic
      clip degrades to flagged-and-partially-corrected, never to a
      starved timeline. The required NEGATIVE validation is on healthy
      clips: a clean gripped swing of either view must keep this counter
      at or near zero, because a rejection stage that fires on healthy
      data is worse than the disease.
    */
    public struct ArmIdentityConfig {
        public var enabled: Bool = true
        /// R5b condition 1: reject only when the wrist's distance to the
        /// OTHER elbow is under this fraction of its distance to its OWN
        /// elbow. 0.6 is deliberately strict; see the note above.
        public var wristCrossFactor: Double = 0.6
        /// R5c condition 1: elbow-to-other-upper-arm-segment distance bar,
        /// as a fraction of the other side's median upper-arm length (the
        /// median, not the frame length, because the frame the elbow is
        /// misreported in is exactly the frame lengths cannot be trusted).
        public var elbowSegmentFraction: Double = 0.25
        /// R5c condition 2: this side's shoulder-elbow-wrist chain length
        /// that frame must exceed its own clip median by this factor.
        public var elbowChainExcessFactor: Double = 1.5
        /// Condition 3 on both predicates: only samples the tracker itself
        /// was unsure of are eligible. NaN visibility reads trusted.
        public var maxVisibility: Double = 0.75
        /// Per-clip cap, per joint (each wrist, each elbow, separately).
        public var maxFractionPerJoint: Double = 0.15
        public init() {}
    }
    public var armIdentity = ArmIdentityConfig()

    /*
      Background palm-lock rejection (round four, R7). The face-on audit's
      white-hat failure: a knuckle jumps to a high-contrast background
      object and STAYS there, so the velocity-spike check above catches at
      most the single jump frame and the parked position then reads as
      perfectly stable. The onset signature is the step ratio (a knuckle
      step far past its own median while the wrist barely moved), but that
      alone is incomplete: a hand rolling over a stationary wrist at the
      finish can hit the same ratio legitimately. The completing condition
      is span: a background object is not at hand distance, so the
      rejection also requires the wrist-to-knuckle span to exceed its own
      clip-median band, which a finish roll never does because a rolling
      hand keeps hand-length span. Once a lock onset is convicted, the
      rejection persists for the following frames while the span stays
      past the band (that is the "stays there"), and releases the moment
      the span comes home. Capped per knuckle per clip, counted, and run
      BEFORE the hand collapse rejection below so a locked knuckle cannot
      pollute the collapse statistics.
    */
    public struct BackgroundLockConfig {
        public var enabled: Bool = true
        /// Onset: knuckle step over this factor of its own clip-median step.
        public var knuckleStepRatio: Double = 3.0
        /// Onset: wrist step under this factor of its own clip-median step.
        public var wristQuietRatio: Double = 0.5
        /// Onset and persistence: wrist-to-knuckle span over this factor of
        /// its clip median.
        public var spanFactor: Double = 1.6
        /// Per-clip cap, per knuckle.
        public var maxFractionPerKnuckle: Double = 0.15
        public init() {}
    }
    public var backgroundLock = BackgroundLockConfig()

    public init() {}

    /*
      View routing stub (round four, verdict 13). One factory pattern
      everywhere: PosePrior routes through profiled(_:for:), the RTS
      smoother and the scheduled Butterworth through their own forView
      factories, and cleanup through this one. It currently returns the
      base unchanged ON PURPOSE: the only per-view cleanup delta proposed
      this round, wristVisibilityFloor 0.50 on face-on, was rejected
      because the adaptive valve above already relaxes the bar on hazy
      clips, and lowering it globally per view would KEEP more confidently
      wrong samples, the exact opposite of what the face-on audit needs.
      The stub exists so the next view-specific cleanup delta has a home
      and so that decision reads as made, not missed.

      Internal, not public, because SwingView itself is declared internal
      (MediaPipePoseProvider.swift) and a method cannot be more visible
      than the types in its signature.
    */
    static func forView(_ view: SwingView?, base: CleanupConfig = CleanupConfig()) -> CleanupConfig {
        base
    }
}

public final class LandmarkCleanupEngine {

    private let config: CleanupConfig

    /// The bones checked for length stability, proximal to distal, with the
    /// joint that gets flagged when the bone breaks (the distal end by
    /// default, or the less visible end when visibility says otherwise).
    /// Limb bones only: shoulders and hips anchor everything downstream, so
    /// they are never rejected off a single bone reading.
    private static let checkedBones: [(a: Int, b: Int)] = [
        (Landmarks.LEFT_SHOULDER, Landmarks.LEFT_ELBOW),
        (Landmarks.LEFT_ELBOW, Landmarks.LEFT_WRIST),
        (Landmarks.RIGHT_SHOULDER, Landmarks.RIGHT_ELBOW),
        (Landmarks.RIGHT_ELBOW, Landmarks.RIGHT_WRIST),
        (Landmarks.LEFT_HIP, Landmarks.LEFT_KNEE),
        (Landmarks.LEFT_KNEE, Landmarks.LEFT_ANKLE),
        (Landmarks.RIGHT_HIP, Landmarks.RIGHT_KNEE),
        (Landmarks.RIGHT_KNEE, Landmarks.RIGHT_ANKLE),
    ]

    private static let arms: [(shoulder: Int, elbow: Int, wrist: Int)] = [
        (Landmarks.LEFT_SHOULDER, Landmarks.LEFT_ELBOW, Landmarks.LEFT_WRIST),
        (Landmarks.RIGHT_SHOULDER, Landmarks.RIGHT_ELBOW, Landmarks.RIGHT_WRIST),
    ]

    /// Wrist and its two knuckles per side, for the collapse rejection.
    private static let hands: [(wrist: Int, index: Int, pinky: Int)] = [
        (Landmarks.LEFT_WRIST, Landmarks.LEFT_INDEX, Landmarks.LEFT_PINKY),
        (Landmarks.RIGHT_WRIST, Landmarks.RIGHT_INDEX, Landmarks.RIGHT_PINKY),
    ]

    public init(config: CleanupConfig = CleanupConfig()) {
        self.config = config
    }

    // MARK: - Entry point

    public func run(_ timeline: inout PoseTimeline, qc: inout TrackingQC) {
        let n = timeline.frameCount
        let joints = timeline.jointCount
        guard n > 2 else { return }

        qc.gridFrames = n
        qc.gridHz = timeline.gridHz
        if qc.effectiveFps == 0 { qc.effectiveFps = timeline.inputFps }

        // Which spaces each joint actually carries data in. A joint dead in a
        // space (Vision heels, an empty normalised set) is left untouched
        // there, and its checks run in whichever space is alive.
        var aliveNorm = [Bool](repeating: false, count: joints)
        var aliveWorld = [Bool](repeating: false, count: joints)
        for j in 0..<joints {
            aliveNorm[j] = timeline.jointIsAlive(.norm, j)
            aliveWorld[j] = timeline.jointIsAlive(.world, j)
        }

        // Best-available per-sample visibility, norm preferred (that is the
        // channel the overlays gate on). NaN means the backend reported none.
        func vis(_ j: Int, _ i: Int) -> Double {
            let v = timeline.norm.visibility[j][i]
            if v.isFinite { return v }
            return timeline.world.visibility[j][i]
        }

        // QC snapshot of mean visibility per joint, before anything is wiped.
        for j in 0..<joints where aliveNorm[j] || aliveWorld[j] {
            var sum = 0.0, count = 0
            for i in 0..<n {
                let v = vis(j, i)
                if v.isFinite { sum += v; count += 1 }
            }
            if count > 0 { qc.jointMeanVisibility[j] = ((sum / Double(count)) * 1000).rounded() / 1000 }
        }

        // ---- 1. Per-clip trust floor (Vector H, corrected form) ----------

        let floor = trustFloor(timeline: timeline, vis: vis)
        qc.trustFloor = (floor * 1000).rounded() / 1000

        // The mask. True means "treat this sample as missing in both spaces".
        var missing = [[Bool]](repeating: [Bool](repeating: false, count: n), count: joints)

        for j in 0..<joints where aliveNorm[j] || aliveWorld[j] {
            for i in 0..<n {
                // Structural missingness in any alive space masks both, so the
                // two spaces cannot drift apart about what was measured.
                if aliveNorm[j], !timeline.norm.x[j][i].isFinite { missing[j][i] = true }
                if aliveWorld[j], !timeline.world.x[j][i].isFinite { missing[j][i] = true }
                // Vector T: visibility below the floor is a missing sample,
                // not a slightly worse one.
                if floor > 0 {
                    let v = vis(j, i)
                    if v.isFinite, v < floor { missing[j][i] = true }
                }
            }
        }

        // ---- 2. Velocity spikes (M-rules, out-and-back signature) --------

        var outliers = 0
        for j in 0..<joints {
            if aliveNorm[j] {
                outliers += flagVelocitySpikes(
                    x: timeline.norm.x[j], y: timeline.norm.y[j],
                    minStep: config.minStepNorm, missing: &missing[j]
                )
            }
            if aliveWorld[j] {
                outliers += flagVelocitySpikes(
                    x: timeline.world.x[j], y: timeline.world.y[j],
                    minStep: config.minStepWorld, missing: &missing[j]
                )
            }
        }

        // ---- 3. Bone-length breaks (M-rules, world space only) -----------
        //
        // Round four: the stage now carries the impossibility floor (R5a),
        // counted separately so the audit clips can show whether the old
        // proportional path or the new floor fires. See the config note.
        //
        // NOTE FOR TrackingQC: add `public var boneImpossibleRejections:
        // Int = 0` alongside outliersRejected. (Done in TrackingQC.swift,
        // round four section.)

        for bone in Self.checkedBones {
            guard bone.a < joints, bone.b < joints,
                  aliveWorld[bone.a], aliveWorld[bone.b] else { continue }
            let broken = flagBoneBreaks(
                timeline: timeline, a: bone.a, b: bone.b,
                vis: vis, missing: &missing
            )
            outliers += broken.flagged
            qc.boneImpossibleRejections += broken.viaFloor
        }

        // ---- 3b. Arm identity rejection (round four, R5b and R5c) --------
        //
        // The face-on catastrophe the audits show is not noise, it is
        // mistaken identity: an occluded side's wrist reported ON the other
        // arm, an elbow cross-linked onto the other tricep, all at
        // plausible-looking positions. Identity errors deserve rejection,
        // not correction, which is why this lives here and not in the fold
        // guard: a sample that belongs to the wrong limb carries no
        // information about the right one, and under this engine's ONE
        // RULE the honest move is to refuse it and let the fill bridge.
        // The predicate is golf aware on purpose; see the config note for
        // why the naive nearest-elbow test would convict every gripped
        // pose it exists to protect. Runs after the bone stage so the
        // forearm band it consults reflects the same statistics the bone
        // checks just judged, and before the arm-geometry stage so E-lite
        // reasons about wrists that at least belong to their own arm.
        //
        // NOTE FOR TrackingQC: add `public var armIdentityRejections: Int
        // = 0` alongside outliersRejected. (Done in TrackingQC.swift,
        // round four section.)
        if config.armIdentity.enabled {
            let identity = flagArmIdentity(
                timeline: timeline, vis: vis, missing: &missing
            )
            outliers += identity
            qc.armIdentityRejections += identity
        }

        // ---- 4. Arm-geometry breaks (E-lite, image space preferred) ------

        for arm in Self.arms {
            guard arm.wrist < joints else { continue }
            let useNorm = aliveNorm[arm.shoulder] && aliveNorm[arm.elbow] && aliveNorm[arm.wrist]
            let useWorld = aliveWorld[arm.shoulder] && aliveWorld[arm.elbow] && aliveWorld[arm.wrist]
            guard useNorm || useWorld else { continue }
            let bank = useNorm ? timeline.norm : timeline.world
            outliers += flagArmGeometryBreaks(
                bank: bank, arm: arm, times: timeline.times, missing: &missing
            )
        }

        // ---- 4b. Background palm-lock rejection (round four, R7) ---------
        //
        // See the CleanupConfig note for the white-hat failure, the onset
        // signature and why the span clause is what makes a finish roll
        // safe. Runs BEFORE the hand collapse rejection below so a knuckle
        // parked on a background object cannot pollute the collapse
        // statistics that stage judges its own frames against.
        //
        // NOTE FOR TrackingQC: add `public var backgroundLockRejections:
        // Int = 0` alongside outliersRejected. (Done in TrackingQC.swift,
        // round four section.)
        if config.backgroundLock.enabled {
            for hand in Self.hands {
                guard hand.pinky < joints, hand.index < joints, hand.wrist < joints else { continue }
                for knuckle in [hand.index, hand.pinky] {
                    let locked = flagBackgroundLock(
                        timeline: timeline,
                        wrist: hand.wrist, knuckle: knuckle,
                        aliveNorm: aliveNorm,
                        missing: &missing
                    )
                    outliers += locked
                    qc.backgroundLockRejections += locked
                }
            }
        }

        // ---- 4c. Hand collapse rejection (kinematic guard, Video 1) ------
        //
        // See the CleanupConfig note for the failure signature and why
        // rejection is the honest form here. Counted into the outlier
        // aggregate like every other rejection, and separately into
        // qc.handCollapseRejections so the impact-window failure can be
        // watched across clips on its own.
        //
        // NOTE FOR TrackingQC: add `public var handCollapseRejections: Int
        // = 0` alongside outliersRejected.
        if config.handCollapseRejection {
            for hand in Self.hands {
                guard hand.pinky < joints, hand.index < joints, hand.wrist < joints else { continue }
                let flagged = flagHandCollapse(
                    timeline: timeline,
                    hand: hand,
                    aliveNorm: aliveNorm,
                    aliveWorld: aliveWorld,
                    missing: &missing
                )
                outliers += flagged
                qc.handCollapseRejections += flagged
            }
        }

        // ---- 4d. Wrist occlusion rejection (occlusion overhaul) ----------
        //
        // See the CleanupConfig note for the failure and header correction
        // 3 for the adaptive bar. Runs LAST among the rejections so the
        // geometric checks above judged the wrist on their own signals
        // first; runs BEFORE the wipe and fill (per the brief) so the
        // standard bridge-or-hold machinery does the interpolation. Counted
        // into the outlier aggregate like every rejection, and separately
        // into qc.wristOcclusionRejections; the weakest bar actually
        // applied lands in qc.wristVisibilityFloorApplied so a clip where
        // the valve engaged says so.
        if config.wristOcclusionRejection {
            var applied = [Double]()
            for hand in Self.hands {
                guard hand.wrist < joints, aliveNorm[hand.wrist] || aliveWorld[hand.wrist] else { continue }
                let result = flagWristOcclusion(
                    wrist: hand.wrist, frameCount: n, vis: vis, missing: &missing[hand.wrist]
                )
                outliers += result.flagged
                qc.wristOcclusionRejections += result.flagged
                if let bar = result.appliedFloor { applied.append(bar) }
            }
            if let weakest = applied.min() {
                qc.wristVisibilityFloorApplied = (weakest * 1000).rounded() / 1000
            }
        }

        qc.outliersRejected += outliers

        // ---- 5. QC fill fractions, then wipe -----------------------------

        for j in 0..<joints {
            if aliveNorm[j] || aliveWorld[j] {
                let measured = (0..<n).filter { !missing[j][$0] }.count
                qc.jointFillFraction[j] = ((Double(measured) / Double(n)) * 1000).rounded() / 1000
            } else {
                qc.jointFillFraction[j] = 0
            }
        }

        for j in 0..<joints where aliveNorm[j] || aliveWorld[j] {
            for i in 0..<n where missing[j][i] {
                if aliveNorm[j] {
                    timeline.norm.x[j][i] = .nan
                    timeline.norm.y[j][i] = .nan
                    timeline.norm.z[j][i] = .nan
                    timeline.norm.visibility[j][i] = .nan
                }
                if aliveWorld[j] {
                    timeline.world.x[j][i] = .nan
                    timeline.world.y[j][i] = .nan
                    timeline.world.z[j][i] = .nan
                    timeline.world.visibility[j][i] = .nan
                }
            }
        }

        // ---- 6. Gap fill (Vector B), both spaces, counting once ----------

        for j in 0..<joints {
            var counted = false
            if aliveNorm[j] {
                fillJoint(space: .norm, joint: j, timeline: &timeline,
                          qc: &qc, countRuns: true)
                counted = true
            }
            if aliveWorld[j] {
                fillJoint(space: .world, joint: j, timeline: &timeline,
                          qc: &qc, countRuns: !counted)
            }
        }
    }

    // MARK: - Trust floor

    /*
      Vector H as corrected in the roadmap: not a fixed 0.35, and not the
      brief's muddled percentile logic, but a floor derived from the clip's own
      distribution over the thirteen joints both backends report. A clip whose
      tracker ran confident earns a higher bar; a hazy clip keeps a lower one
      so the gate rejects its worst samples without hollowing it out. Zero
      when there is no visibility data at all (the Vision backend), in which
      case the geometric checks carry the whole load.
    */
    private func trustFloor(timeline: PoseTimeline, vis: (Int, Int) -> Double) -> Double {
        var values: [Double] = []
        for j in Validity.CORE_JOINTS where j < timeline.jointCount {
            for i in 0..<timeline.frameCount {
                let v = vis(j, i)
                if v.isFinite { values.append(v) }
            }
        }
        guard values.count >= 20 else { return 0 }
        values.sort()
        let p25 = values[Int(Double(values.count - 1) * 0.25)]
        let floor = config.trustFloorScale * p25
        return min(max(floor, config.trustFloorRange.lowerBound), config.trustFloorRange.upperBound)
    }

    // MARK: - Velocity spikes

    /*
      A single-sample tracking glitch jumps away and comes straight back, so
      the points either side of it sit close together while both steps through
      it are huge. A genuine fast sweep has huge steps too, but it keeps
      going, so the flanking points are far apart. Only the first pattern is
      rejected. Returns how many samples were newly flagged.
    */
    private func flagVelocitySpikes(
        x: [Double], y: [Double], minStep: Double, missing: inout [Bool]
    ) -> Int {
        let n = x.count
        guard n > 4 else { return 0 }

        func dist(_ i: Int, _ k: Int) -> Double {
            let dx = x[i] - x[k], dy = y[i] - y[k]
            return (dx * dx + dy * dy).squareRoot()
        }

        var steps: [Double] = []
        steps.reserveCapacity(n - 1)
        for i in 1..<n where x[i].isFinite && x[i - 1].isFinite {
            steps.append(dist(i, i - 1))
        }
        guard steps.count > 4 else { return 0 }
        steps.sort()
        let median = steps[steps.count / 2]
        let threshold = max(config.velocityFactor * median, minStep)

        var flagged = 0
        for i in 1..<(n - 1) {
            guard !missing[i],
                  x[i - 1].isFinite, x[i].isFinite, x[i + 1].isFinite else { continue }
            let sIn = dist(i, i - 1)
            let sOut = dist(i + 1, i)
            guard sIn > threshold, sOut > threshold else { continue }
            // Out and back: the flanking points nearly coincide relative to
            // the excursion.
            if dist(i + 1, i - 1) < 0.5 * max(sIn, sOut) {
                missing[i] = true
                flagged += 1
            }
        }
        return flagged
    }

    // MARK: - Bone breaks

    /// Returns what was newly flagged in total, and the subset the
    /// impossibility floor alone caught (frames the proportional test
    /// excused), so QC can show which path fired on a given clip.
    private func flagBoneBreaks(
        timeline: PoseTimeline, a: Int, b: Int,
        vis: (Int, Int) -> Double, missing: inout [[Bool]]
    ) -> (flagged: Int, viaFloor: Int) {
        let n = timeline.frameCount
        let wx = timeline.world.x, wy = timeline.world.y, wz = timeline.world.z

        func length(_ i: Int) -> Double? {
            guard wx[a][i].isFinite, wx[b][i].isFinite else { return nil }
            let dx = wx[a][i] - wx[b][i]
            let dy = wy[a][i] - wy[b][i]
            let dz = (wz[a][i].isFinite && wz[b][i].isFinite) ? wz[a][i] - wz[b][i] : 0
            return (dx * dx + dy * dy + dz * dz).squareRoot()
        }

        var lengths: [(i: Int, len: Double)] = []
        for i in 0..<n {
            if let l = length(i), l > 1e-6 { lengths.append((i, l)) }
        }
        guard lengths.count > 8 else { return (0, 0) }

        let sorted = lengths.map { $0.len }.sorted()
        let median = sorted[sorted.count / 2]
        guard median > 1e-6 else { return (0, 0) }

        // Relative deviation per frame, and its own robust spread, so the
        // eight percent floor adapts upward on clips that wobble as a
        // baseline. See header note 2.
        let rel = lengths.map { abs($0.len - median) / median }
        let relSorted = rel.sorted()
        let relMedian = relSorted[relSorted.count / 2]
        let madSorted = rel.map { abs($0 - relMedian) }.sorted()
        let mad = madSorted[madSorted.count / 2]
        let threshold = max(config.boneTolerance, relMedian + config.boneMadFactor * mad)

        // Shoulders and hips anchor every measurement downstream, so a bone
        // break can never reject one of them; the blame lands on the other
        // end regardless of visibility.
        let anchors: Set<Int> = [
            Landmarks.LEFT_SHOULDER, Landmarks.RIGHT_SHOULDER,
            Landmarks.LEFT_HIP, Landmarks.RIGHT_HIP,
        ]

        var flagged = 0
        var floorFlagged = 0
        // The floor's cap is measured against the bone's own measured
        // samples, the pool this stage judges: a clip whose median is
        // corrupt cannot be hollowed past this by the floor alone.
        let floorCap = Int(Double(lengths.count) * config.boneImpossibleMaxFraction)
        for (k, entry) in lengths.enumerated() {
            let broken = rel[k] > threshold
            // Round four impossibility floor (R5a, see the config note): an
            // unconditional rejection under the impossible fraction of the
            // clip median, exempt from the adaptive tolerance above, so a
            // collapse window that corrupted the tolerance pool cannot also
            // hide behind it. Only attributed to the floor when the
            // proportional test excused the frame, so the two paths stay
            // distinguishable in QC.
            let impossible = config.boneImpossibilityFloor
                && entry.len < config.boneImpossibleFraction * median
            let viaFloor = !broken && impossible && floorFlagged < floorCap
            guard broken || viaFloor else { continue }
            // Reject the less trusted endpoint; distal when trust is equal or
            // unknown, since errors accumulate outward from the torso.
            let va = vis(a, entry.i), vb = vis(b, entry.i)
            let target: Int
            if va.isFinite, vb.isFinite, va < vb, !anchors.contains(a) {
                target = a
            } else {
                target = b
            }
            if !missing[target][entry.i] {
                missing[target][entry.i] = true
                flagged += 1
                if viaFloor { floorFlagged += 1 }
            }
        }
        return (flagged, floorFlagged)
    }

    // MARK: - Arm identity rejection (round four, R5b and R5c)

    /*
      See the CleanupConfig note for the failure, the golf-aware predicate
      and why the naive nearest-elbow test is wrong for a gripped pose.
      World space throughout: image-space proximity between the arms is a
      legitimate product of foreshortening (a DTL view stacks them), while
      a wrist metrically sitting on the other arm is a fact about
      identity. z contributes to a distance only when finite at both ends,
      the same convention as the bone checks. Returns the total newly
      flagged across both sides and both joints.
    */
    private func flagArmIdentity(
        timeline: PoseTimeline,
        vis: (Int, Int) -> Double,
        missing: inout [[Bool]]
    ) -> Int {
        let joints = timeline.jointCount
        let n = timeline.frameCount
        guard n > 8 else { return 0 }
        let armLeft = Self.arms[0]
        let armRight = Self.arms[1]
        let needed = [
            armLeft.shoulder, armLeft.elbow, armLeft.wrist,
            armRight.shoulder, armRight.elbow, armRight.wrist,
        ]
        guard needed.allSatisfy({ $0 < joints && timeline.jointIsAlive(.world, $0) })
        else { return 0 }
        let wx = timeline.world.x, wy = timeline.world.y, wz = timeline.world.z

        func dist(_ a: Int, _ b: Int, _ i: Int) -> Double? {
            guard wx[a][i].isFinite, wx[b][i].isFinite else { return nil }
            let dx = wx[a][i] - wx[b][i]
            let dy = wy[a][i] - wy[b][i]
            let dz = (wz[a][i].isFinite && wz[b][i].isFinite) ? wz[a][i] - wz[b][i] : 0
            return (dx * dx + dy * dy + dz * dz).squareRoot()
        }

        /// Distance from a joint to the segment between two others. Depth
        /// joins in only when all three ends carry it, else the test runs
        /// in the ground plane, the honest degradation.
        func distToSegment(point p: Int, a: Int, b: Int, _ i: Int) -> Double? {
            guard wx[p][i].isFinite, wx[a][i].isFinite, wx[b][i].isFinite else { return nil }
            let useZ = wz[p][i].isFinite && wz[a][i].isFinite && wz[b][i].isFinite
            let px = wx[p][i], py = wy[p][i], pz = useZ ? wz[p][i] : 0
            let ax = wx[a][i], ay = wy[a][i], az = useZ ? wz[a][i] : 0
            let bx = wx[b][i], by = wy[b][i], bz = useZ ? wz[b][i] : 0
            let abx = bx - ax, aby = by - ay, abz = bz - az
            let ab2 = abx * abx + aby * aby + abz * abz
            var t = 0.0
            if ab2 > 1e-12 {
                t = ((px - ax) * abx + (py - ay) * aby + (pz - az) * abz) / ab2
                t = Swift.min(1, Swift.max(0, t))
            }
            let cx = ax + t * abx - px
            let cy = ay + t * aby - py
            let cz = az + t * abz - pz
            return (cx * cx + cy * cy + cz * cz).squareRoot()
        }

        /// Clip median and the same adaptive tolerance the bone checks use,
        /// for one bone. Nil when the bone was too rarely measured to judge.
        func band(_ a: Int, _ b: Int) -> (median: Double, threshold: Double)? {
            var lens: [Double] = []
            lens.reserveCapacity(n)
            for i in 0..<n {
                if let l = dist(a, b, i), l > 1e-6 { lens.append(l) }
            }
            guard lens.count > 8 else { return nil }
            lens.sort()
            let median = lens[lens.count / 2]
            guard median > 1e-6 else { return nil }
            let rel = lens.map { abs($0 - median) / median }.sorted()
            let relMedian = rel[rel.count / 2]
            let mad = rel.map { abs($0 - relMedian) }.sorted()[rel.count / 2]
            return (median, Swift.max(config.boneTolerance, relMedian + config.boneMadFactor * mad))
        }

        /// Clip median of the shoulder-elbow-wrist chain length for a side.
        func chainMedian(_ arm: (shoulder: Int, elbow: Int, wrist: Int)) -> Double? {
            var lens: [Double] = []
            lens.reserveCapacity(n)
            for i in 0..<n {
                guard let u = dist(arm.shoulder, arm.elbow, i),
                      let f = dist(arm.elbow, arm.wrist, i) else { continue }
                if u + f > 1e-6 { lens.append(u + f) }
            }
            guard lens.count > 8 else { return nil }
            lens.sort()
            return lens[lens.count / 2]
        }

        let cfg = config.armIdentity
        let capPerJoint = Int(Double(n) * cfg.maxFractionPerJoint)
        var flagged = 0

        for (own, other) in [(armLeft, armRight), (armRight, armLeft)] {
            let forearmBand = band(own.elbow, own.wrist)
            let otherUpperMedian = band(other.shoulder, other.elbow)?.median
            let ownChainMedian = chainMedian(own)

            var wristFlags = 0
            var elbowFlags = 0
            for i in 0..<n {
                // R5b: the wrist genuinely sitting on the other arm.
                if wristFlags < capPerJoint, !missing[own.wrist][i],
                   let forearm = forearmBand {
                    let v = vis(own.wrist, i)
                    if v.isFinite, v < cfg.maxVisibility,
                       let dOwn = dist(own.wrist, own.elbow, i), dOwn > 1e-6,
                       let dOther = dist(own.wrist, other.elbow, i),
                       dOther < cfg.wristCrossFactor * dOwn,
                       abs(dOwn - forearm.median) / forearm.median > forearm.threshold {
                        missing[own.wrist][i] = true
                        wristFlags += 1
                        flagged += 1
                    }
                }
                // R5c: the elbow cross-linked onto the other upper arm.
                if elbowFlags < capPerJoint, !missing[own.elbow][i],
                   let otherUpper = otherUpperMedian, let chainMed = ownChainMedian {
                    let v = vis(own.elbow, i)
                    if v.isFinite, v < cfg.maxVisibility,
                       let dSeg = distToSegment(point: own.elbow, a: other.shoulder, b: other.elbow, i),
                       dSeg < cfg.elbowSegmentFraction * otherUpper,
                       let u = dist(own.shoulder, own.elbow, i),
                       let f = dist(own.elbow, own.wrist, i),
                       u + f > cfg.elbowChainExcessFactor * chainMed {
                        missing[own.elbow][i] = true
                        elbowFlags += 1
                        flagged += 1
                    }
                }
            }
        }
        return flagged
    }

    // MARK: - Arm geometry (E-lite)

    /*
      The E-lite rejection test from the roadmap: without a club tracker, the
      strongest wrist sanity check available is that the shoulder, elbow and
      wrist have to keep making sense as an arm. The interior angle at the
      elbow evolves smoothly through a swing; a wrist that teleports drives
      that angle through a rate no arm reaches and back again. Only the spike
      that reverts is rejected, and only the wrist is flagged, never the
      shoulder or elbow it was measured against. Rejection only, no invented
      positions, exactly as the roadmap disposed of full Vector E.
    */
    private func flagArmGeometryBreaks(
        bank: PoseTimeline.Channels,
        arm: (shoulder: Int, elbow: Int, wrist: Int),
        times: [Double],
        missing: inout [[Bool]]
    ) -> Int {
        let n = times.count
        guard n > 4 else { return 0 }

        func elbowAngle(_ i: Int) -> Double? {
            let sx = bank.x[arm.shoulder][i], sy = bank.y[arm.shoulder][i]
            let ex = bank.x[arm.elbow][i], ey = bank.y[arm.elbow][i]
            let wxv = bank.x[arm.wrist][i], wyv = bank.y[arm.wrist][i]
            guard sx.isFinite, ex.isFinite, wxv.isFinite else { return nil }
            let ux = sx - ex, uy = sy - ey
            let vx = wxv - ex, vy = wyv - ey
            let lu = (ux * ux + uy * uy).squareRoot()
            let lv = (vx * vx + vy * vy).squareRoot()
            guard lu > 1e-9, lv > 1e-9 else { return nil }
            let cosA = min(1, max(-1, (ux * vx + uy * vy) / (lu * lv)))
            return acos(cosA) * 180 / .pi
        }

        var flagged = 0
        for i in 1..<(n - 1) {
            guard !missing[arm.wrist][i],
                  let a0 = elbowAngle(i - 1),
                  let a1 = elbowAngle(i),
                  let a2 = elbowAngle(i + 1) else { continue }
            let dtIn = (times[i] - times[i - 1]) / 1000
            let dtOut = (times[i + 1] - times[i]) / 1000
            guard dtIn > 1e-4, dtOut > 1e-4 else { continue }
            let rateIn = abs(a1 - a0) / dtIn
            let rateOut = abs(a2 - a1) / dtOut
            guard rateIn > config.elbowAngleRateLimit,
                  rateOut > config.elbowAngleRateLimit else { continue }
            // The spike reverts: the angle either side of it barely moved.
            if abs(a2 - a0) < 0.5 * abs(a1 - a0) {
                missing[arm.wrist][i] = true
                flagged += 1
            }
        }
        return flagged
    }

    // MARK: - Background palm-lock rejection (round four, R7)

    /*
      One knuckle against its own wrist, one pass. Detection lives in image
      space like the hand collapse below: a background object is an
      image-space phenomenon, and both backends put hand points in the
      normalised channel when they have them at all. Onset requires all
      three clauses (knuckle step spike, quiet wrist, span past the band);
      the lock then persists frame to frame on the span clause alone, which
      is exactly the audited "jumps and STAYS": the parked frames have tiny
      steps and would sail through any velocity test, but they cannot fake
      a hand-length span. Release the moment the span comes home or the
      knuckle stops being measured. On the Vision backend the knuckle slots
      are dead and the stage is inert, the honest behaviour. Returns what
      was newly flagged; the per-knuckle cap leaves the counter pinned at
      its ceiling on a catastrophic clip rather than starving the timeline.
    */
    private func flagBackgroundLock(
        timeline: PoseTimeline,
        wrist: Int, knuckle: Int,
        aliveNorm: [Bool],
        missing: inout [[Bool]]
    ) -> Int {
        guard aliveNorm[wrist], aliveNorm[knuckle] else { return 0 }
        let n = timeline.frameCount
        guard n > 8 else { return 0 }
        let nb = timeline.norm

        func step(_ j: Int, _ i: Int) -> Double? {
            guard nb.x[j][i].isFinite, nb.x[j][i - 1].isFinite else { return nil }
            let dx = nb.x[j][i] - nb.x[j][i - 1]
            let dy = nb.y[j][i] - nb.y[j][i - 1]
            return (dx * dx + dy * dy).squareRoot()
        }
        func span(_ i: Int) -> Double? {
            guard nb.x[wrist][i].isFinite, nb.x[knuckle][i].isFinite else { return nil }
            let dx = nb.x[wrist][i] - nb.x[knuckle][i]
            let dy = nb.y[wrist][i] - nb.y[knuckle][i]
            return (dx * dx + dy * dy).squareRoot()
        }
        func median(_ values: [Double]) -> Double? {
            guard values.count > 8 else { return nil }
            let s = values.sorted()
            return s[s.count / 2]
        }

        var knuckleSteps: [Double] = []
        var wristSteps: [Double] = []
        var spans: [Double] = []
        knuckleSteps.reserveCapacity(n)
        wristSteps.reserveCapacity(n)
        spans.reserveCapacity(n)
        for i in 1..<n {
            if let s = step(knuckle, i) { knuckleSteps.append(s) }
            if let s = step(wrist, i) { wristSteps.append(s) }
        }
        for i in 0..<n {
            if let s = span(i) { spans.append(s) }
        }
        guard let knuckleMedianStep = median(knuckleSteps), knuckleMedianStep > 1e-9,
              let wristMedianStep = median(wristSteps), wristMedianStep > 1e-9,
              let spanMedian = median(spans), spanMedian > 1e-9
        else { return 0 }

        let cfg = config.backgroundLock
        let spanBar = cfg.spanFactor * spanMedian
        let cap = Int(Double(n) * cfg.maxFractionPerKnuckle)

        var flagged = 0
        var locked = false
        for i in 1..<n {
            if flagged >= cap { break }
            guard let d = span(i) else {
                // The knuckle stopped being measured; whatever happens next
                // is the fill's problem, not a lock.
                locked = false
                continue
            }
            if locked {
                if d > spanBar {
                    if !missing[knuckle][i] {
                        missing[knuckle][i] = true
                        flagged += 1
                    }
                } else {
                    locked = false
                }
            } else {
                guard d > spanBar,
                      let ks = step(knuckle, i), ks > cfg.knuckleStepRatio * knuckleMedianStep,
                      let ws = step(wrist, i), ws < cfg.wristQuietRatio * wristMedianStep
                else { continue }
                if !missing[knuckle][i] {
                    missing[knuckle][i] = true
                    flagged += 1
                }
                locked = true
            }
        }
        return flagged
    }

    // MARK: - Hand collapse rejection (kinematic guard, Video 1)

    /*
      Detection lives in image space, where the audited failure lives (the
      0.015 is a normalised figure) and where both backends put hand points
      when they have them at all. The speed gate prefers the world wrist
      (metres per second against the metric gate) and falls back to
      normalised units per second, because an image-space speed alone would
      read a zoom as hand speed. Flags index and pinky only, NEVER the
      wrist: the wrist is the anchored, bone-checked end of the chain and
      is exactly what the collapsed knuckles fell onto. On the Vision
      backend the knuckle slots are dead and the stage is inert, which is
      the honest behaviour.
    */
    private func flagHandCollapse(
        timeline: PoseTimeline,
        hand: (wrist: Int, index: Int, pinky: Int),
        aliveNorm: [Bool],
        aliveWorld: [Bool],
        missing: inout [[Bool]]
    ) -> Int {
        guard aliveNorm[hand.wrist], aliveNorm[hand.index], aliveNorm[hand.pinky] else { return 0 }
        let n = timeline.frameCount
        guard n > 8 else { return 0 }
        let nb = timeline.norm

        func handSpan(_ i: Int) -> Double? {
            guard nb.x[hand.wrist][i].isFinite, nb.y[hand.wrist][i].isFinite,
                  nb.x[hand.index][i].isFinite, nb.y[hand.index][i].isFinite,
                  nb.x[hand.pinky][i].isFinite, nb.y[hand.pinky][i].isFinite
            else { return nil }
            let px = (nb.x[hand.index][i] + nb.x[hand.pinky][i]) / 2
            let py = (nb.y[hand.index][i] + nb.y[hand.pinky][i]) / 2
            let dx = nb.x[hand.wrist][i] - px
            let dy = nb.y[hand.wrist][i] - py
            return (dx * dx + dy * dy).squareRoot()
        }

        var spans: [Double] = []
        spans.reserveCapacity(n)
        for i in 0..<n {
            // Round four: samples an earlier rejection already refused (the
            // background palm lock in particular, which runs immediately
            // before this stage precisely so a knuckle parked on a
            // background object cannot pollute these statistics) are not
            // measurements of the hand and stay out of the median.
            guard !missing[hand.wrist][i], !missing[hand.index][i], !missing[hand.pinky][i]
            else { continue }
            if let d = handSpan(i) { spans.append(d) }
        }
        guard spans.count > 8 else { return 0 }
        spans.sort()
        let median = spans[spans.count / 2]
        let threshold = Swift.min(
            config.handCollapseDistanceNorm,
            config.handCollapseMedianFraction * median
        )
        guard threshold > 0 else { return 0 }

        let useWorldSpeed = aliveWorld[hand.wrist]
        let bank = useWorldSpeed ? timeline.world : timeline.norm
        let gate = useWorldSpeed ? config.handCollapseSpeedWorld : config.handCollapseSpeedNorm

        func stepSpeed(_ i: Int, _ k: Int) -> Double? {
            guard bank.x[hand.wrist][i].isFinite, bank.y[hand.wrist][i].isFinite,
                  bank.x[hand.wrist][k].isFinite, bank.y[hand.wrist][k].isFinite
            else { return nil }
            let dt = abs(timeline.times[i] - timeline.times[k]) / 1000
            guard dt > 1e-4 else { return nil }
            let dx = bank.x[hand.wrist][i] - bank.x[hand.wrist][k]
            let dy = bank.y[hand.wrist][i] - bank.y[hand.wrist][k]
            var d2 = dx * dx + dy * dy
            if useWorldSpeed, bank.z[hand.wrist][i].isFinite, bank.z[hand.wrist][k].isFinite {
                let dz = bank.z[hand.wrist][i] - bank.z[hand.wrist][k]
                d2 += dz * dz
            }
            return d2.squareRoot() / dt
        }

        var flagged = 0
        for i in 0..<n {
            guard let d = handSpan(i), d < threshold else { continue }
            // Larger of the backward and forward step speeds: impact peaks
            // between samples and a one-sided difference can halve it.
            var speed: Double? = nil
            if i > 0, let s = stepSpeed(i, i - 1) { speed = s }
            if i + 1 < n, let s = stepSpeed(i, i + 1) { speed = Swift.max(speed ?? 0, s) }
            guard let speed, speed > gate else { continue }
            for j in [hand.index, hand.pinky] where !missing[j][i] {
                missing[j][i] = true
                flagged += 1
            }
        }
        return flagged
    }

    // MARK: - Wrist occlusion rejection (occlusion overhaul)

    /*
      One wrist, one pass. The bar starts at the brief's 0.6 and adapts
      down (header correction 3) when the raw bar would reject more than
      the configured fraction of the wrist's still-measured samples: the
      effective bar becomes the visibility quantile at that fraction, so
      the rejection always trims the least-seen tail of THIS clip's own
      distribution and can never hollow the clip into one long hold. On a
      well tracked clip the quantile sits above 0.6 and the brief's bar
      applies unchanged.

      Only samples the earlier checks left standing are counted and
      flagged, so the fraction is measured against what would otherwise
      survive. Returns what was flagged and the bar actually applied, nil
      when the wrist carried no visibility at all (the Vision backend).
    */
    private func flagWristOcclusion(
        wrist: Int, frameCount: Int,
        vis: (Int, Int) -> Double,
        missing: inout [Bool]
    ) -> (flagged: Int, appliedFloor: Double?) {
        var values: [Double] = []
        values.reserveCapacity(frameCount)
        for i in 0..<frameCount where !missing[i] {
            let v = vis(wrist, i)
            if v.isFinite { values.append(v) }
        }
        guard values.count > 8 else { return (0, nil) }

        values.sort()
        var bar = config.wristVisibilityFloor
        let rawRejected = values.prefix(while: { $0 < bar }).count
        let rawFraction = Double(rawRejected) / Double(values.count)
        if rawFraction > config.wristRejectionMaxFraction {
            let idx = min(
                values.count - 1,
                Int(Double(values.count) * config.wristRejectionMaxFraction)
            )
            bar = min(bar, values[idx])
        }
        guard bar > 0 else { return (0, bar) }

        var flagged = 0
        for i in 0..<frameCount where !missing[i] {
            let v = vis(wrist, i)
            guard v.isFinite, v < bar else { continue }
            missing[i] = true
            flagged += 1
        }
        return (flagged, bar)
    }

    // MARK: - Gap fill

    /*
      Coordinate channels share the joint's missing pattern by construction
      after the wipe, so runs are computed once from x and applied to x and y
      together; z has its own pattern (depth can be absent where x is
      measured) and is filled by its own runs; visibility is not interpolated,
      it is set to an honest figure for what the fill did.
    */
    private func fillJoint(
        space: PoseSpace, joint: Int,
        timeline: inout PoseTimeline,
        qc: inout TrackingQC, countRuns: Bool
    ) {
        var bank = timeline.channels(space)
        defer { timeline.setChannels(space, bank) }

        let times = timeline.times
        let runs = missingRuns(bank.x[joint])
        guard !runs.isEmpty else { return }

        for run in runs {
            let filled = fillRun(
                run: run,
                times: times,
                channels: [bank.x[joint], bank.y[joint]],
                shortMax: config.shortGapMax
            )
            // fillRun is pure; write its results back per channel.
            apply(run: run, kind: filled.kind, values: filled.values[0], to: &bank.x[joint])
            apply(run: run, kind: filled.kind, values: filled.values[1], to: &bank.y[joint])

            // Visibility for the filled span: short bridges inherit the weaker
            // neighbour scaled down, holds sit below every overlay floor.
            let visValue: Double
            switch filled.kind {
            case .shortBridge:
                let before = run.lowerBound - 1, after = run.upperBound
                let va = before >= 0 ? bank.visibility[joint][before] : .nan
                let vb = after < times.count ? bank.visibility[joint][after] : .nan
                if va.isFinite, vb.isFinite {
                    visValue = min(va, vb) * config.shortFillVisibilityScale
                } else {
                    visValue = config.unknownFillVisibility
                }
                if countRuns { qc.shortGapsFilled += 1 }
            case .held:
                visValue = config.heldVisibility
                if countRuns { qc.longGapsHeld += 1 }
            case .untouched:
                continue
            }
            for i in run { bank.visibility[joint][i] = visValue }
        }

        // Depth, by its own runs, same rules, never counted (it is the same
        // joint, already accounted for above).
        let zRuns = missingRuns(bank.z[joint])
        for run in zRuns {
            let filled = fillRun(
                run: run, times: times,
                channels: [bank.z[joint]],
                shortMax: config.shortGapMax
            )
            if filled.kind != .untouched {
                apply(run: run, kind: filled.kind, values: filled.values[0], to: &bank.z[joint])
            }
        }
    }

    private enum FillKind {
        case shortBridge
        case held
        case untouched
    }

    /// NaN runs of a channel, as index ranges.
    private func missingRuns(_ channel: [Double]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int? = nil
        for i in 0..<channel.count {
            if !channel[i].isFinite {
                if start == nil { start = i }
            } else if let s = start {
                runs.append(s..<i)
                start = nil
            }
        }
        if let s = start { runs.append(s..<channel.count) }
        return runs
    }

    /*
      Fill one run for a set of parallel channels sharing the run. Interior
      runs at or under the short-gap limit are bridged with a monotone cubic
      (PCHIP, Fritsch and Carlson slopes) through the anchors either side,
      which cannot overshoot the way a plain cubic can, so a bridged wrist
      never swings wider than its neighbours actually measured. Everything
      else, leading and trailing runs included, holds the nearest known
      position. Returns the computed values per channel; a run with no
      anchors at all (a dead joint) is untouched.
    */
    private func fillRun(
        run: Range<Int>, times: [Double], channels: [[Double]], shortMax: Int
    ) -> (kind: FillKind, values: [[Double]]) {
        let n = times.count
        let before = run.lowerBound - 1
        let after = run.upperBound
        let hasBefore = before >= 0 && channels[0][before].isFinite
        let hasAfter = after < n && channels[0][after].isFinite

        var out: [[Double]] = channels.map { _ in [Double](repeating: .nan, count: run.count) }

        if hasBefore, hasAfter, run.count <= shortMax {
            for (c, channel) in channels.enumerated() {
                // Outer anchors for slope estimation, when they exist.
                let prev = before - 1 >= 0 && channel[before - 1].isFinite ? before - 1 : nil
                let next = after + 1 < n && channel[after + 1].isFinite ? after + 1 : nil
                out[c] = pchipBridge(
                    run: run, times: times, channel: channel,
                    before: before, after: after, prev: prev, next: next
                )
            }
            return (.shortBridge, out)
        }

        if hasBefore || hasAfter {
            // Hold the last known position (or the first, for a leading run).
            let anchor = hasBefore ? before : after
            for (c, channel) in channels.enumerated() {
                let heldValue = channel[anchor].isFinite
                    ? channel[anchor]
                    : nearestFinite(channel, from: anchor)
                if let v = heldValue {
                    out[c] = [Double](repeating: v, count: run.count)
                }
            }
            return (.held, out)
        }

        return (.untouched, out)
    }

    private func nearestFinite(_ channel: [Double], from index: Int) -> Double? {
        var lo = index, hi = index
        while lo >= 0 || hi < channel.count {
            if lo >= 0, channel[lo].isFinite { return channel[lo] }
            if hi < channel.count, channel[hi].isFinite { return channel[hi] }
            lo -= 1; hi += 1
        }
        return nil
    }

    private func apply(run: Range<Int>, kind: FillKind, values: [Double], to channel: inout [Double]) {
        guard kind != .untouched else { return }
        for (k, i) in run.enumerated() where values[k].isFinite {
            channel[i] = values[k]
        }
    }

    /*
      Monotone cubic Hermite across one gap. Endpoint slopes follow Fritsch
      and Carlson: zero where the flanking secants disagree in sign, otherwise
      the weighted harmonic mean, which is the standard shape-preserving
      choice. Degrades to the secant (linear) slope when an outer anchor is
      missing.
    */
    private func pchipBridge(
        run: Range<Int>, times: [Double], channel: [Double],
        before: Int, after: Int, prev: Int?, next: Int?
    ) -> [Double] {
        let tA = times[before], vA = channel[before]
        let tB = times[after], vB = channel[after]
        let hAB = tB - tA
        guard hAB > 0 else { return [Double](repeating: vA, count: run.count) }
        let dAB = (vB - vA) / hAB

        func endpointSlope(outer: Int?, tEnd: Double, vEnd: Double, inner: Double, hInner: Double, outerFirst: Bool) -> Double {
            guard let o = outer else { return inner }
            let tO = times[o], vO = channel[o]
            let hOuter = outerFirst ? (tEnd - tO) : (tO - tEnd)
            guard hOuter > 0 else { return inner }
            let dOuter = outerFirst ? (vEnd - vO) / hOuter : (vO - vEnd) / hOuter
            if dOuter * inner <= 0 { return 0 }
            let w1 = 2 * hInner + hOuter
            let w2 = hInner + 2 * hOuter
            return (w1 + w2) / (w1 / dOuter + w2 / inner)
        }

        let mA = endpointSlope(outer: prev, tEnd: tA, vEnd: vA, inner: dAB, hInner: hAB, outerFirst: true)
        let mB = endpointSlope(outer: next, tEnd: tB, vEnd: vB, inner: dAB, hInner: hAB, outerFirst: false)

        var out = [Double](repeating: .nan, count: run.count)
        for (k, i) in run.enumerated() {
            let s = (times[i] - tA) / hAB
            let s2 = s * s, s3 = s2 * s
            let h00 = 2 * s3 - 3 * s2 + 1
            let h10 = s3 - 2 * s2 + s
            let h01 = -2 * s3 + 3 * s2
            let h11 = s3 - s2
            out[k] = h00 * vA + h10 * hAB * mA + h01 * vB + h11 * hAB * mB
        }
        return out
    }
}
