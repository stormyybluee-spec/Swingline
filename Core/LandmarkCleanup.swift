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

    public init() {}
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

        for bone in Self.checkedBones {
            guard bone.a < joints, bone.b < joints,
                  aliveWorld[bone.a], aliveWorld[bone.b] else { continue }
            outliers += flagBoneBreaks(
                timeline: timeline, a: bone.a, b: bone.b,
                vis: vis, missing: &missing
            )
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

        // ---- 4b. Hand collapse rejection (kinematic guard, Video 1) ------
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

        // ---- 4c. Wrist occlusion rejection (occlusion overhaul) ----------
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

    private func flagBoneBreaks(
        timeline: PoseTimeline, a: Int, b: Int,
        vis: (Int, Int) -> Double, missing: inout [[Bool]]
    ) -> Int {
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
        guard lengths.count > 8 else { return 0 }

        let sorted = lengths.map { $0.len }.sorted()
        let median = sorted[sorted.count / 2]
        guard median > 1e-6 else { return 0 }

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
        for (k, entry) in lengths.enumerated() where rel[k] > threshold {
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
