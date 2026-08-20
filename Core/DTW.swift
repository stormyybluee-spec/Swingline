import Foundation

/*
  Dynamic Time Warping with full backtracking.

  Two swings recorded on different days are never the same length and never the
  same tempo. Playing them back side by side on a shared clock compares the top
  of one swing against the middle of the other's downswing, which produces a
  comparison that looks rigorous and means nothing.

  DTW finds the alignment that minimises total distance between the two
  sequences while keeping time moving forward in both. The backtracked path is
  what the Then vs Now overlay plays back on, and what the delta chart is drawn
  against, so the comparison is honest about tempo instead of pretending it
  does not exist.

  A Sakoe Chiba band caps how far the alignment may drift. Without it, a swing
  can warp onto a completely different phase and still score well.

  Translated from packages/core/src/dtw.ts. Float64Array in the original
  becomes a plain [Double], Swift arrays of Double are already contiguously
  stored, there is no separate typed array concept needed here.
*/

public enum DTW {

    public static func euclidean(_ p: [Double], _ q: [Double]) -> Double {
        var sum = 0.0
        for k in 0..<p.count {
            let d = p[k] - q[k]
            sum += d * d
        }
        return sum.squareRoot()
    }

    public static func dtw(_ a: [FeatureVector], _ b: [FeatureVector], band: Double = 0.25, distance: ([Double], [Double]) -> Double = euclidean) -> DtwResult {
        let n = a.count
        let m = b.count
        if n == 0 || m == 0 { return DtwResult(cost: .infinity, path: [], normalised: .infinity) }

        let w = max(Int((Double(max(n, m)) * band).rounded(.down)), abs(n - m) + 1)
        var D = [Double](repeating: .infinity, count: (n + 1) * (m + 1))
        func at(_ i: Int, _ j: Int) -> Int { i * (m + 1) + j }
        D[at(0, 0)] = 0

        for i in 1...n {
            let jStart = max(1, i - w)
            let jEnd = min(m, i + w)
            if jStart > jEnd { continue }
            for j in jStart...jEnd {
                let cost = distance(a[i - 1], b[j - 1])
                let best = min(D[at(i - 1, j)], D[at(i, j - 1)], D[at(i - 1, j - 1)])
                D[at(i, j)] = cost + best
            }
        }

        /* Walk the matrix backwards to recover the alignment itself. */
        var path: [(Int, Int)] = []
        var i = n
        var j = m
        while i > 0 && j > 0 {
            path.append((i - 1, j - 1))
            let diag = D[at(i - 1, j - 1)]
            let up = D[at(i - 1, j)]
            let left = D[at(i, j - 1)]
            if diag <= up && diag <= left { i -= 1; j -= 1 }
            else if up <= left { i -= 1 }
            else { j -= 1 }
        }
        path.reverse()

        return DtwResult(
            cost: D[at(n, m)],
            path: path,
            normalised: D[at(n, m)] / Double(path.isEmpty ? 1 : path.count)
        )
    }

    /*
      Feature vectors for alignment. Angles are scaled so that no single channel
      dominates the distance purely because it happens to be measured in a larger
      unit. Pressure sits on a 0 to 1 scale already, so it is multiplied up to sit
      in the same neighbourhood as the scaled rotations.
    */
    public static func featureVectors(_ series: SwingSeries) -> [FeatureVector] {
        var out: [FeatureVector] = []
        out.reserveCapacity(series.n)
        for i in 0..<series.n {
            out.append([
                series.pelvis[i] / 90,
                series.torso[i] / 90,
                series.xFactor[i] / 60,
                series.handY[i] * 2,
                series.pressure[i] * 1.5,
            ])
        }
        return out
    }

    /* Minimal shape deltaTrace needs per series. analyseSwing's SwingSeries has
       all of these, this narrower shape exists so deltaTrace can also be called
       against two compact, stored series without needing a full SwingSeries. */
    public struct DeltaSeriesInput {
        public var pelvis: [Double]
        public var torso: [Double]
        public var xFactor: [Double]
        public var pressure: [Double]
        public var handY: [Double]

        public init(pelvis: [Double], torso: [Double], xFactor: [Double], pressure: [Double], handY: [Double]) {
            self.pelvis = pelvis
            self.torso = torso
            self.xFactor = xFactor
            self.pressure = pressure
            self.handY = handY
        }

        fileprivate subscript(key: String) -> [Double] {
            switch key {
            case "pelvis": return pelvis
            case "torso": return torso
            case "xFactor": return xFactor
            case "pressure": return pressure
            case "handY": return handY
            default: return []
            }
        }
    }

    /*
      The delta chart, borrowed straight from motorsport telemetry.

      A single similarity number tells a golfer nothing they can act on. A racing
      driver does not want to hear that their lap was 0.4 seconds slower, they want
      to see the corner where the time went. This does the same thing for a swing,
      it walks the aligned path and reports, at every point through the swing, how
      far apart the two attempts were on each channel. Shaded area, not one number.
    */
    public static func deltaTrace(_ seriesA: DeltaSeriesInput, _ seriesB: DeltaSeriesInput, _ alignment: DtwResult) -> DeltaTrace {
        let channels: [DeltaChannel] = [
            DeltaChannel(key: "pelvis", label: "Hip turn", category: .sequencing, scale: 1),
            DeltaChannel(key: "torso", label: "Shoulder turn", category: .rotation, scale: 1),
            DeltaChannel(key: "xFactor", label: "Separation", category: .rotation, scale: 1),
            DeltaChannel(key: "pressure", label: "Pressure", category: .balance, scale: 100),
            DeltaChannel(key: "handY", label: "Hand height", category: .finish, scale: 100),
        ]

        var points: [DeltaPoint] = []
        points.reserveCapacity(alignment.path.count)
        for (step, pair) in alignment.path.enumerated() {
            let (i, j) = pair
            let progress = Double(step) / Double(alignment.path.count - 1 == 0 ? 1 : alignment.path.count - 1)
            var deltas: [String: Double] = [:]
            for ch in channels {
                deltas[ch.key] = (seriesB[ch.key][j] - seriesA[ch.key][i]) * ch.scale
            }
            points.append(DeltaPoint(progress: progress, i: i, j: j, deltas: deltas))
        }

        /* Where the two swings diverge most, expressed as a share of the way
           through the swing so the interface can point straight at it. */
        var worst: [String: DeltaWorst] = [:]
        for ch in channels {
            var peak = 0.0
            var at = 0.0
            for p in points {
                let d = abs(p.deltas[ch.key] ?? 0)
                if d > peak { peak = d; at = p.progress }
            }
            worst[ch.key] = DeltaWorst(magnitude: peak, progress: at, label: ch.label, category: ch.category)
        }

        return DeltaTrace(channels: channels, points: points, worst: worst)
    }

    /* Resample the warped path down to a fixed number of playback steps, so the
       Then vs Now overlay runs at a steady frame rate rather than stuttering
       wherever the alignment happened to be dense. */
    public static func playbackPairs(_ alignment: DtwResult, steps: Int = 90) -> [(Int, Int)] {
        let path = alignment.path
        if path.isEmpty { return [] }
        var out: [(Int, Int)] = []
        out.reserveCapacity(steps)
        for s in 0..<steps {
            let pos = (Double(s) / Double(steps - 1)) * Double(path.count - 1)
            out.append(path[Int(pos.rounded())])
        }
        return out
    }
}
