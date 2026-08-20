import Foundation

/*
  Swing phase segmentation, P1 through P10.

  These are the real coaching positions, the ones a golfer who has had a lesson
  already knows by name. No invented stage names anywhere in this product.

    P1  Address
    P2  Club shaft parallel to the ground, takeaway
    P3  Lead arm parallel to the ground, backswing
    P4  Top of the backswing
    P5  Lead arm parallel to the ground, downswing
    P6  Club shaft parallel to the ground, delivery
    P7  Impact
    P8  Trail arm parallel to the ground, release
    P9  Club shaft parallel to the ground, follow through
    P10 Finish

  The whole segmentation hangs off one anchor: the quiet moment at the top.
  Hand speed drops to a near stop there as the swing reverses direction, and
  that trough is detectable with no training data, no labels, and no model. It
  is the most reliable landmark in the entire swing. Everything else is found
  by searching outward from it.

  Positions the app cannot see without tracking the club itself, P2, P6 and P9,
  are estimated from hand height and flagged with lower confidence. The
  interface never presents an estimate as a measurement.

  Translated from packages/core/src/phases.ts.
*/

public enum Phases {

    public static let PHASE_KEYS: [PhaseKey] = [.p1, .p2, .p3, .p4, .p5, .p6, .p7, .p8, .p9, .p10]

    public static let PHASE_LABELS: [PhaseKey: String] = [
        .p1: "Address",
        .p2: "Takeaway",
        .p3: "Lead arm parallel",
        .p4: "Top",
        .p5: "Transition",
        .p6: "Delivery",
        .p7: "Impact",
        .p8: "Release",
        .p9: "Follow through",
        .p10: "Finish",
    ]

    public struct StageGroup {
        public var key: StageKey
        public var label: String
        public var phases: [PhaseKey]
    }

    /* The five stages the interface actually shows. P1 through P10 lives behind
       the full breakdown for the golfers who want it. */
    public static let STAGE_GROUPS: [StageGroup] = [
        StageGroup(key: .address, label: "Address", phases: [.p1]),
        StageGroup(key: .takeaway, label: "Takeaway", phases: [.p2, .p3]),
        StageGroup(key: .top, label: "Top", phases: [.p4]),
        StageGroup(key: .downswing, label: "Downswing", phases: [.p5, .p6, .p7]),
        StageGroup(key: .finish, label: "Finish", phases: [.p8, .p9, .p10]),
    ]

    public static func segment(_ series: SwingSeries, _ frames: [Frame]) -> PhaseResult? {
        let handSpeed = series.handSpeed
        let handY = series.handY
        let n = series.n
        let t = series.t
        let S = series.sides
        if n < 8 { return nil }

        let peakSpeed = handSpeed.max() ?? 0
        if peakSpeed < 0.15 { return nil }

        /* Impact: the fastest the hands ever travel, refined to the lowest hand
           position within a couple of frames of that maximum. */
        let speedPeak = Geometry.argMax(handSpeed)
        let P7 = refineLowest(handY, speedPeak, 3)

        /*
          Motion onset: the first sustained rise in hand speed. Everything before it
          is the golfer standing at address, where hand speed is also near zero.

          This has to be established before the top can be found. A trough search
          that is allowed to run over the address frames will always prefer them,
          because a golfer standing still is quieter than a golfer changing direction,
          and the top then lands hundreds of milliseconds too early and takes every
          rotation measurement with it.
        */
        /*
          Thresholds relative to both the peak and the noise floor.

          A fraction of peak speed alone is not enough. A golfer with a very slow,
          deliberate takeaway and a fast downswing never crosses a threshold set at
          twelve percent of peak, so onset lands at the start of the downswing and the
          entire backswing disappears from the measurement. Anchoring partly to the
          quietest part of the clip keeps the trigger honest across both a lazy
          takeaway and a violent one.
        */
        let sorted = handSpeed.sorted()
        let noiseFloor = sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count) * 0.2)]
        let moving = max(peakSpeed * 0.05, noiseFloor * 3)
        var onset = 0
        for i in 0..<P7 {
            if handSpeed[i] > moving { onset = i; break }
        }

        /* Top of the backswing: the quiet moment where the swing reverses. */
        let searchFrom = min(onset + 3, max(1, P7 - 3))
        let P4 = Geometry.argMin(handSpeed, from: searchFrom, to: max(searchFrom + 1, P7 - 2))

        /*
          Takeaway and address.

          Found by walking forward from the start of the clip, not backward from the
          top. The top is itself a minimum in hand speed, so a backward search
          terminates on its first step and address collapses onto the top, which
          silently zeroes the backswing duration, the tempo ratio and every rotation
          measured from address. Direction of travel matters here.
        */
        let quiet = max(peakSpeed * 0.03, noiseFloor * 1.5)
        var P2 = onset

        var P1 = 0
        var i = P2
        while i >= 0 {
            if handSpeed[i] < quiet { P1 = i; break }
            i -= 1
        }

        /* A takeaway that never settles below the quiet threshold means the clip
           started mid motion. Fall back to the first frame rather than inventing an
           address position that was never recorded. */
        if P2 <= P1 { P2 = min(P4 - 1, P1 + 1) }

        /* Finish: the hands come to rest again and stay there. */
        var P10 = n - 1
        if P7 + 3 < n - 3 {
            for i in (P7 + 3)..<(n - 3) {
                if handSpeed[i] < quiet && handSpeed[i + 1] < quiet && handSpeed[i + 2] < quiet {
                    P10 = i
                    break
                }
            }
        }

        /* Lead arm parallel to the ground, once going back and once coming down. */
        let P3 = mostHorizontalArm(frames, S.leadShoulder, S.leadWrist, P2, P4)
        let P5 = mostHorizontalArm(frames, S.leadShoulder, S.leadWrist, P4, P7)
        let P8 = mostHorizontalArm(frames, S.trailShoulder, S.trailWrist, P7, P10)

        /* Shaft parallel positions, estimated from hand height relative to the hip
           and shoulder. Lower confidence, and labelled as such downstream. */
        let hipHeight = handY[P1] + 0.12
        let P6 = crossHeight(handY, P5, P7, hipHeight, direction: .down)
        let shoulderHeight = handY[P1] + 0.45
        let P9 = crossHeight(handY, P8, P10, shoulderHeight, direction: .up)

        var idx: [PhaseKey: Int] = [:]
        idx[.p1] = P1
        idx[.p2] = Int(Geometry.clamp(Double(P2), Double(P1), Double(P4)))
        idx[.p3] = Int(Geometry.clamp(Double(P3), Double(P2), Double(P4)))
        idx[.p4] = P4
        idx[.p5] = Int(Geometry.clamp(Double(P5), Double(P4), Double(P7)))
        idx[.p6] = Int(Geometry.clamp(Double(P6), Double(P5), Double(P7)))
        idx[.p7] = P7
        idx[.p8] = Int(Geometry.clamp(Double(P8), Double(P7), Double(P10)))
        idx[.p9] = Int(Geometry.clamp(Double(P9), Double(P8), Double(P10)))
        idx[.p10] = P10

        let backswingMs = t[idx[.p4]!] - t[idx[.p1]!]
        let downswingMs = t[idx[.p7]!] - t[idx[.p4]!]

        var times: [PhaseKey: Double] = [:]
        for key in PHASE_KEYS { times[key] = t[idx[key]!] }

        return PhaseResult(
            idx: idx,
            times: times,
            backswingMs: backswingMs,
            downswingMs: downswingMs,
            /* The classic tempo ratio golf instruction is built around. Tour average
               sits close to three to one, backswing to downswing. */
            tempoRatio: downswingMs > 0 ? backswingMs / downswingMs : 0,
            confidence: [
                .p1: 0.9, .p2: 0.55, .p3: 0.8, .p4: 0.95, .p5: 0.8,
                .p6: 0.5, .p7: 0.9, .p8: 0.7, .p9: 0.5, .p10: 0.85,
            ]
        )
    }

    private static func refineLowest(_ handY: [Double], _ centre: Int, _ radius: Int) -> Int {
        var best = centre
        var i = max(0, centre - radius)
        let upper = min(handY.count - 1, centre + radius)
        while i <= upper {
            if handY[i] < handY[best] { best = i }
            i += 1
        }
        return best
    }

    /* The frame in a window where a limb sits closest to horizontal. */
    private static func mostHorizontalArm(_ frames: [Frame], _ shoulderIdx: Int, _ wristIdx: Int, _ from: Int, _ to: Int) -> Int {
        var best = from
        var bestErr = Double.infinity
        var i = from
        while i <= to && i < frames.count {
            let w = frames[i].world
            let arm = Geometry.v.sub(w[wristIdx].vec, w[shoulderIdx].vec)
            let len = Geometry.v.len(arm) == 0 ? 1e-6 : Geometry.v.len(arm)
            let err = abs(arm.y / len)
            if err < bestErr { bestErr = err; best = i }
            i += 1
        }
        return best
    }

    private enum CrossDirection { case up, down }

    /* First crossing of a height threshold inside a window. */
    private static func crossHeight(_ handY: [Double], _ from: Int, _ to: Int, _ target: Double, direction: CrossDirection) -> Int {
        var i = from
        while i <= to && i < handY.count - 1 {
            let a = handY[i]
            let b = handY[i + 1]
            if direction == .down && a >= target && b <= target { return i }
            if direction == .up && a <= target && b >= target { return i }
            i += 1
        }
        return Int(((Double(from) + Double(to)) / 2).rounded())
    }

    /* Which of the five visible stages a given frame belongs to, used to drive
       the stage scrubber on the analysis screen. */
    public static func stageAt(_ phases: PhaseResult, _ frameIndex: Int) -> StageKey {
        let i = phases.idx
        if frameIndex < i[.p2]! { return .address }
        if frameIndex < i[.p4]! { return .takeaway }
        if frameIndex < i[.p5]! { return .top }
        if frameIndex <= i[.p7]! { return .downswing }
        return .finish
    }

    public static let HEAD_INDEX = Landmarks.NOSE
}
