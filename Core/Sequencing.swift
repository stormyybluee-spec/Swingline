import Foundation

/*
  Kinematic sequencing, the headline metric.

  An efficient downswing fires from the ground up. The pelvis reaches its peak
  rotational speed first, then the torso, then the lead arm, then the club,
  each segment peaking slightly after the one below it. Energy passes up the
  chain like a whip. Beginners reliably fire out of order, usually leading with
  the shoulders and arms while the pelvis stays passive, which is why they lose
  distance no matter how hard they swing.

  Two things are measured here, and they are different questions:
    order    did the segments peak in the right sequence at all
    gaps     did each peak land a sensible distance after the one before it

  A golfer can get the order right and still leak power by firing everything at
  once, which shows up as gaps close to zero.

  Translated from packages/core/src/sequencing.ts.
*/

public enum Sequencing {

    public static let SEGMENTS: [SegmentKey] = [.pelvis, .torso, .arm, .club]

    public static let SEGMENT_LABELS: [SegmentKey: String] = [
        .pelvis: "Hips",
        .torso: "Chest",
        .arm: "Lead arm",
        .club: "Hands",
    ]

    /* Tour players separate consecutive peaks by roughly 20 to 60 milliseconds.
       Below about 10ms the segments are effectively firing together. */
    private static let GAP_GOOD: (Double, Double) = (18, 65)
    private static let GAP_OK: (Double, Double) = (8, 95)

    public static func analyseSequence(_ series: SwingSeries, _ phases: PhaseResult) -> SequenceResult? {
        let t = series.t
        let tracksLookup: [SegmentKey: [Double]] = [
            .pelvis: series.pelvisSpeed,
            .torso: series.torsoSpeed,
            .arm: series.armSpeed,
            .club: series.handSpeed,
        ]
        let idx = phases.idx

        /* The measurement window runs from the top of the backswing to just past
           impact. Peaks outside the downswing are not part of the sequence. */
        let from = max(0, idx[.p4]! - 2)
        let to = min(series.n - 1, idx[.p7]! + 3)
        if to - from < 3 { return nil }

        var peaks: [SegmentKey: SequencePeak] = [:]
        for key in SEGMENTS {
            let i = Geometry.argMax(tracksLookup[key]!, from: from, to: to)
            let refined = refinePeak(tracksLookup[key]!, t, i)
            peaks[key] = SequencePeak(index: i, time: refined.time, value: refined.value, relative: 0)
        }

        /* Times relative to impact, which is how a coach reads a sequence graph. */
        let impactT = t[idx[.p7]!]
        for key in SEGMENTS {
            peaks[key]!.relative = peaks[key]!.time - impactT
        }

        let observedOrder = SEGMENTS.sorted { peaks[$0]!.time < peaks[$1]!.time }
        let orderCorrect = observedOrder == SEGMENTS

        var gaps: [SequenceGap] = []
        for i in 1..<SEGMENTS.count {
            let a = SEGMENTS[i - 1]
            let b = SEGMENTS[i]
            gaps.append(SequenceGap(from: a, to: b, ms: peaks[b]!.time - peaks[a]!.time))
        }

        /* Count how far the observed order sits from the ideal, using the number of
           adjacent swaps needed. One swap is a small fault, three is a different
           swing entirely. */
        let inversions = countInversions(observedOrder.map { SEGMENTS.firstIndex(of: $0)! })

        let goodGaps = gaps.filter { $0.ms >= GAP_GOOD.0 && $0.ms <= GAP_GOOD.1 }.count
        let okGaps = gaps.filter { $0.ms >= GAP_OK.0 && $0.ms <= GAP_OK.1 }.count

        /* The single most common beginner pattern worth naming on its own: the
           upper body leading the lower body out of the top. */
        let upperBodyFirst = peaks[.torso]!.time < peaks[.pelvis]!.time
        let armsFirst = peaks[.arm]!.time < peaks[.torso]!.time
        let allAtOnce = gaps.allSatisfy { abs($0.ms) < GAP_OK.0 }

        return SequenceResult(
            peaks: peaks,
            gaps: gaps,
            observedOrder: observedOrder,
            orderCorrect: orderCorrect,
            inversions: inversions,
            goodGaps: goodGaps,
            okGaps: okGaps,
            upperBodyFirst: upperBodyFirst,
            armsFirst: armsFirst,
            allAtOnce: allAtOnce,
            /* Peak speeds should also rise up the chain. A pelvis spinning faster
               than the hands means the whip never cracked. */
            speedsAscend: peaks[.pelvis]!.value < peaks[.torso]!.value * 3 && peaks[.club]!.value > 0
        )
    }

    /*
      Sub frame peak timing.

      At sixty frames a second one frame is about seventeen milliseconds, and the
      handover gaps this whole measurement is about are twenty to sixty. Reading
      peak times straight off the sample grid therefore has an error of roughly one
      gap width, which is enough to swap two segments in the order and report a
      clean swing as a faulty one.

      Fitting a parabola through the peak sample and its two neighbours recovers
      the true peak to a fraction of a frame. Standard practice anywhere a peak
      time matters more than a peak value, and it costs three multiplications.
    */
    private static func refinePeak(_ values: [Double], _ times: [Double], _ i: Int) -> (time: Double, value: Double) {
        guard i - 1 >= 0, i + 1 < values.count else { return (times[i], values[i]) }
        let lo = values[i - 1]
        let mid = values[i]
        let hi = values[i + 1]
        let denom = lo - 2 * mid + hi
        if abs(denom) < 1e-9 { return (times[i], mid) }
        let delta = max(-0.5, min(0.5, (0.5 * (lo - hi)) / denom))
        let halfStep = (times[i + 1] - times[i - 1]) / 2
        return (times[i] + delta * halfStep, mid - 0.25 * (lo - hi) * delta)
    }

    private static func countInversions(_ arr: [Int]) -> Int {
        var count = 0
        for i in 0..<arr.count {
            for j in (i + 1)..<arr.count {
                if arr[i] > arr[j] { count += 1 }
            }
        }
        return count
    }

    /*
      X-Factor and X-Factor stretch.

      X-Factor is the angular separation between the shoulder line and the hip line
      at the top of the backswing. The stretch is the more interesting number: the
      separation that keeps growing for a beat after the downswing has already
      started, because the hips have begun turning through while the chest is still
      finishing its backswing. That extra loading is where the speed comes from,
      and it is exactly what a beginner throws away by unwinding everything at once.
    */
    public static func analyseXFactor(_ series: SwingSeries, _ phases: PhaseResult) -> XFactorResult {
        let xFactor = series.xFactor
        let t = series.t
        let idx = phases.idx

        /*
          Direction matters here, and taking an absolute value throws it away.

          If the chest overtakes the hips on the way down, which is exactly what an
          over the top move is, the signed separation crosses zero and then grows
          again in the opposite direction. Measured on the absolute value that reads
          as a big, healthy stretch, when it is in fact the specific fault the metric
          exists to catch. So separation is measured along whichever direction it was
          loaded in at the top, and anything past zero counts as negative.
        */
        let p4 = idx[.p4]!
        let p1 = idx[.p1]!
        let p7 = idx[.p7]!
        let loadDirection: Double = xFactor[p4] < 0 ? -1 : (xFactor[p4] > 0 ? 1 : 1)
        let along: (Int) -> Double = { xFactor[$0] * loadDirection }
        let atTop = along(p4)

        /* The first 120ms of the downswing is where continued separation shows up. */
        let windowEnd = findIndexAfterTime(t, t[p4], 120, p7)
        var peak = atTop
        var peakIndex = p4
        if p4 <= windowEnd {
            for i in p4...windowEnd {
                if along(i) > peak {
                    peak = along(i)
                    peakIndex = i
                }
            }
        }

        let stretch = peak - atTop
        let shoulderTurn = abs(series.torso[p4] - series.torso[p1])
        let hipTurn = abs(series.pelvis[p4] - series.pelvis[p1])

        /* How early the shoulders start unwinding. A reversal before the hips have
           moved is the classic over the top starting point. */
        let reversalIndex = findReversal(series.torso, p4, p7)
        let earlyReversalMs: Double? = reversalIndex >= 0 ? t[reversalIndex] - t[p4] : nil

        return XFactorResult(
            atTop: atTop,
            peak: peak,
            peakIndex: peakIndex,
            stretch: stretch,
            shoulderTurn: shoulderTurn,
            hipTurn: hipTurn,
            earlyReversalMs: earlyReversalMs
        )
    }

    private static func findIndexAfterTime(_ t: [Double], _ startTime: Double, _ ms: Double, _ cap: Int) -> Int {
        for i in 0..<t.count {
            if t[i] >= startTime + ms { return min(i, cap) }
        }
        return cap
    }

    private static func findReversal(_ signal: [Double], _ from: Int, _ to: Int) -> Int {
        guard from + 1 < signal.count else { return -1 }
        let direction = signum(signal[min(from + 1, signal.count - 1)] - signal[from])
        var i = from + 1
        while i <= to && i < signal.count {
            if signum(signal[i] - signal[i - 1]) != direction { return i }
            i += 1
        }
        return -1
    }

    private static func signum(_ x: Double) -> Double {
        x > 0 ? 1 : (x < 0 ? -1 : 0)
    }
}
