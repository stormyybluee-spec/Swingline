import Foundation

/*
  Vector maths and one dimensional signal processing.

  Pose data from a phone camera is noisy. Every derived quantity in this app,
  angular speed above all, is a derivative, and differentiating noise produces
  garbage. So the rule here is: smooth before you differentiate, always.

  Translated from packages/core/src/geometry.ts. Kept as an enum namespace,
  see CoreTypes.swift's header comment for why that pattern is used across
  all 14 files rather than a single shared namespace or nothing at all.
*/

public enum Geometry {

    /* v was a plain object of functions in the original, grouping vector
       ops without being a real type. Kept as a nested, lowercase enum
       namespace to preserve the exact call site shape, Geometry.v.sub(a, b),
       even though a lowercase type name is unconventional Swift style. */
    public enum v {
        public static func sub(_ a: Vec3, _ b: Vec3) -> Vec3 {
            Vec3(x: a.x - b.x, y: a.y - b.y, z: (a.z ?? 0) - (b.z ?? 0))
        }
        public static func add(_ a: Vec3, _ b: Vec3) -> Vec3 {
            Vec3(x: a.x + b.x, y: a.y + b.y, z: (a.z ?? 0) + (b.z ?? 0))
        }
        public static func scale(_ a: Vec3, _ k: Double) -> Vec3 {
            Vec3(x: a.x * k, y: a.y * k, z: (a.z ?? 0) * k)
        }
        public static func mid(_ a: Vec3, _ b: Vec3) -> Vec3 {
            Vec3(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, z: ((a.z ?? 0) + (b.z ?? 0)) / 2)
        }
        public static func dot(_ a: Vec3, _ b: Vec3) -> Double {
            a.x * b.x + a.y * b.y + (a.z ?? 0) * (b.z ?? 0)
        }
        public static func len(_ a: Vec3) -> Double {
            (a.x * a.x + a.y * a.y + (a.z ?? 0) * (a.z ?? 0)).squareRoot()
        }
        public static func dist(_ a: Vec3, _ b: Vec3) -> Double {
            let dx = a.x - b.x, dy = a.y - b.y, dz = (a.z ?? 0) - (b.z ?? 0)
            return (dx * dx + dy * dy + dz * dz).squareRoot()
        }
        public static func norm(_ a: Vec3) -> Vec3 {
            let l = len(a) == 0 ? 1e-9 : len(a)
            return Vec3(x: a.x / l, y: a.y / l, z: (a.z ?? 0) / l)
        }
        public static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
            Vec3(
                x: a.y * (b.z ?? 0) - (a.z ?? 0) * b.y,
                y: (a.z ?? 0) * b.x - a.x * (b.z ?? 0),
                z: a.x * b.y - a.y * b.x
            )
        }
    }

    public static func deg(_ radians: Double) -> Double { (radians * 180) / Double.pi }
    public static func rad(_ degrees: Double) -> Double { (degrees * Double.pi) / 180 }
    public static func clamp(_ n: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, n)) }
    public static func lerp(_ a: Double, _ b: Double, _ k: Double) -> Double { a + (b - a) * k }

    /* Angle between two vectors, always 0 to 180 degrees. */
    public static func angleBetween(_ a: Vec3, _ b: Vec3) -> Double {
        let c = clamp(v.dot(v.norm(a), v.norm(b)), -1, 1)
        return deg(acos(c))
    }

    /* Interior angle at joint b, for example the elbow given shoulder and wrist. */
    public static func jointAngle(_ a: Vec3, _ b: Vec3, _ c: Vec3) -> Double {
        angleBetween(v.sub(a, b), v.sub(c, b))
    }

    /*
      The angle at joint b, in degrees, between the b to a and b to c segments.
      This is the name the foot task asks for; it is jointAngle under a clearer
      label for the foot case, where b is the ankle, a the heel and c the toe,
      so the returned value is how open the heel to ankle to toe wedge is. A
      flat, planted foot holds this near constant; as the heel lifts and the
      foot rolls onto the toe the wedge closes, so the number moving is the
      roll being tracked. Returns zero if either segment has no length, which
      is the only honest reading when two of the three points coincide.
    */
    public static func angleBetweenJoints(a: Vec3, b: Vec3, c: Vec3) -> Double {
        let ba = v.sub(a, b), bc = v.sub(c, b)
        if v.len(ba) < 1e-6 || v.len(bc) < 1e-6 { return 0 }
        return angleBetween(ba, bc)
    }

    /*
      How far the foot has rolled onto the toe, in degrees, from the heel to toe
      line's tilt away from level. Zero is a flat foot whose heel and toe sit at
      the same height; the number grows as the heel climbs above the toe. This
      is the reading the follow through wants: a right foot up on its toe reads
      high, a planted foot reads near zero, and unlike the raw ankle to heel to
      toe wedge it does not also move when the ankle flexes.

      up is the unit vector that points away from the ground in this space
      (world y is down, so up is usually 0, minus 1, 0). The tilt is signed by
      whether the heel is above or below the toe along up, so a dropped heel
      reads negative rather than folding back to positive.
    */
    public static func footRollAngle(heel: Vec3, toe: Vec3, up: Vec3) -> Double {
        let sole = v.sub(toe, heel)
        let l = v.len(sole)
        if l < 1e-6 { return 0 }
        let u = v.norm(up)
        // Height of the heel above the toe along up, as a fraction of sole
        // length, is the sine of the tilt. Heel above toe means the sole
        // vector (toe minus heel) points downward along up, hence the minus.
        let rise = clamp(-v.dot(sole, u) / l, -1, 1)
        return deg(asin(rise))
    }

    /*
      Rotation of a body line about the vertical axis, projected onto the ground
      plane. This is what "hip turn" and "shoulder turn" actually mean.
      MediaPipe world space is x right, y down, z toward the camera, so the ground
      plane is x by z.
    */
    public static func transverseAngle(_ vec: Vec3) -> Double {
        deg(atan2(vec.z ?? 0, vec.x))
    }

    /* Tilt of a vector away from vertical, in degrees. Used for spine angle. */
    public static func tiltFromVertical(_ vec: Vec3) -> Double {
        angleBetween(vec, Vec3(x: 0, y: -1, z: 0))
    }

    /*
      Wrap a difference in degrees into the range minus 180 to plus 180.

      This is the fix for a bug that put 341 degrees of shoulder to hip separation
      on screen. Separation was computed as the difference between two independently
      unwrapped angle series. At address both lines point the same way, and if that
      direction sits near the plus or minus 180 boundary one series can settle on
      +179 while the other settles on -179 even though the two lines are physically
      parallel. Unwrapping each series on its own cannot see that their baselines
      are a full turn apart, so the difference came out near 360 instead of near 0.

      Any angular difference between two separately tracked bodies has to be wrapped
      before it means anything.
    */
    public static func wrapDeg(_ d: Double) -> Double {
        (((d + 180).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)) - 180
    }

    /*
      Build a continuous angle series with a physical speed limit.

      Plain unwrapping trusts every sample. If pose noise flips an angle across the
      wrap boundary, unwrapping faithfully records a 360 degree jump that never
      happened and carries the error forward for the rest of the swing.

      A human segment cannot rotate faster than roughly fourteen hundred degrees a
      second, so any implied step larger than that within one frame is noise rather
      than motion, and gets clamped. Real rotation passes through untouched, wrap
      artefacts cannot.
    */
    public static func continuousAngle(_ series: [Double], _ timesMs: [Double], maxRateDegPerSec: Double = 1400) -> [Double] {
        var out = [Double](repeating: 0, count: series.count)
        if series.isEmpty { return out }
        out[0] = series[0]
        for i in 1..<series.count {
            let dt = max(1.0 / 240.0, (timesMs[i] - timesMs[i - 1]) / 1000)
            let step = clamp(wrapDeg(series[i] - out[i - 1]), -maxRateDegPerSec * dt, maxRateDegPerSec * dt)
            out[i] = out[i - 1] + step
        }
        return out
    }

    /*
      Unwrap a series of angles in degrees so that a turn through the plus or
      minus 180 boundary reads as continuous motion rather than a 360 degree jump.
      Without this, peak angular speed lands on a wrapping artefact and the whole
      sequencing result is wrong.
    */
    public static func unwrap(_ series: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: series.count)
        if series.isEmpty { return out }
        var offset = 0.0
        out[0] = series[0]
        for i in 1..<series.count {
            let d = series[i] - series[i - 1]
            if d > 180 { offset -= 360 }
            else if d < -180 { offset += 360 }
            out[i] = series[i] + offset
        }
        return out
    }

    /* Centred moving average. Cheap, stable, and enough at 30 to 60 frames a second. */
    public static func smooth(_ series: [Double], window: Int = 5) -> [Double] {
        if window <= 1 || series.count < 3 { return series }
        let half = window / 2
        var out = [Double](repeating: 0, count: series.count)
        for i in 0..<series.count {
            var sum = 0.0
            var n = 0
            var k = i - half
            while k <= i + half {
                if k >= 0 && k < series.count {
                    sum += series[k]
                    n += 1
                }
                k += 1
            }
            out[i] = sum / Double(n)
        }
        return out
    }

    /*
      Median filter.

      A moving average smears an impulse across its whole window rather than
      removing it, which is why a single wild frame from a pose tracker survives
      every amount of averaging and goes on to define a peak. A median ignores an
      outlier entirely as long as it is outnumbered, so one bad frame in five simply
      disappears while genuine edges stay sharp.

      This runs before any smoothing or differentiation, because an impulse that
      reaches the derivative has already done its damage.
    */
    public static func medianFilter(_ series: [Double], window: Int = 5) -> [Double] {
        if series.count < window { return series }
        let half = window / 2
        var out = [Double](repeating: 0, count: series.count)
        for i in 0..<series.count {
            var buffer: [Double] = []
            var k = i - half
            while k <= i + half {
                let clampedIndex = max(0, min(series.count - 1, k))
                buffer.append(series[clampedIndex])
                k += 1
            }
            buffer.sort()
            out[i] = buffer[half]
        }
        return out
    }

    /*
      Savitzky Golay smoothing, quadratic, over any odd window. Preserves peak
      height far better than a moving average, which matters because the height
      and timing of the angular speed peaks is the entire kinematic sequence
      measurement. Falls back to a moving average on short series.

      The window used to be fixed at seven samples. Seven samples is a different
      amount of time on every device, and that was the bug: see frameWindowFor
      below.

      Coefficients are generated rather than tabulated. For a quadratic fit
      evaluated at the centre of a symmetric window of half width m, the smoothing
      weight at offset i is

          3 * (3m^2 + 3m - 1 - 5i^2) / ((2m + 3)(2m + 1)(2m - 1))

      which reproduces the familiar [-2 3 6 7 6 3 -2] / 21 at m = 3.
    */
    private static func sgWeights(_ half: Int) -> [Double] {
        let m = Double(half)
        let denom = (2 * m + 3) * (2 * m + 1) * (2 * m - 1)
        var w = [Double](repeating: 0, count: 2 * half + 1)
        for i in -half...half {
            let fi = Double(i)
            w[i + half] = (3 * (3 * m * m + 3 * m - 1 - 5 * fi * fi)) / denom
        }
        return w
    }

    private static var sgCache: [Int: [Double]] = [:]
    private static func sgWeightsCached(_ half: Int) -> [Double] {
        if let cached = sgCache[half] { return cached }
        let w = sgWeights(half)
        sgCache[half] = w
        return w
    }

    public static func savitzkyGolay(_ series: [Double], window: Int = 7) -> [Double] {
        var n = max(5, window)
        if n % 2 == 0 { n += 1 }
        if series.count < n { return smooth(series, window: 3) }

        let half = (n - 1) / 2
        let w = sgWeightsCached(half)
        var out = [Double](repeating: 0, count: series.count)

        for i in 0..<series.count {
            if i < half || i >= series.count - half {
                out[i] = series[i]
                continue
            }
            var sum = 0.0
            for k in 0..<n { sum += w[k] * series[i - half + k] }
            out[i] = sum
        }
        return out
    }

    /*
      Frame rate independence.

      Every filter window in this engine used to be counted in frames. A five frame
      median spans 167ms at 30fps and 417ms at 12fps. The downswing is around 250ms
      end to end, so on a slow device the filter window grew longer than the event
      it was supposed to preserve and flattened the impact dip the swing finder
      exists to find. Below roughly 15fps the detector stopped finding anything at
      all, which is almost certainly why uploads failed while live capture worked.

      The fix is to say how much time a window should cover and let the frame count
      follow from the timestamps actually delivered. A 150ms window is a 150ms
      window on every device. It contains fewer samples on a slow one, which is
      honest, rather than silently covering a different span of the swing.

      Median rather than mean interval, because browser frame delivery drops frames
      and a single long gap would drag a mean upward and undo the whole point.
    */
    public static func medianInterval(_ times: [Double]) -> Double {
        if times.count < 2 { return 0 }
        var gaps: [Double] = []
        for i in 1..<times.count {
            let d = times[i] - times[i - 1]
            if d > 0 && d.isFinite { gaps.append(d) }
        }
        if gaps.isEmpty { return 0 }
        gaps.sort()
        return gaps[gaps.count / 2]
    }

    public static func effectiveFps(_ times: [Double]) -> Double {
        let dt = medianInterval(times)
        return dt > 0 ? 1000 / dt : 0
    }

    // Sample standard deviation. Used by the adaptive smoother to size its
    // window against how noisy the signal actually is.
    public static func std(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        return sqrt(variance)
    }

    /*
      Savitzky Golay smoothing with a window that adapts to frame rate and to the
      local noise of the signal.

      A fixed window in milliseconds already holds across frame rates, which is
      why the rest of the engine uses savitzkyGolayMs. This goes one step further
      for the metrics that are most sensitive to tracking jitter: a slower or
      noisier capture gets a wider window, a clean high rate capture a narrower
      one, so detail is kept where the data supports it and jitter is removed
      where it does not.

      The noise ratio is the fraction of the signal that a heavy reference smooth
      throws away. A clean signal loses almost nothing so the window stays near
      its frame rate baseline; a jittery one loses a lot so the window widens, up
      to the maximum. times are in milliseconds, the same as everywhere else.

      Not yet wired into buildSeries. Swapping a metric's savitzkyGolayMs call for
      this one is a one line change per metric, but it alters that metric's output
      and so belongs behind a verification against real captures, not a blind
      global swap.
    */
    public static func adaptiveSavitzkyGolay(
        _ series: [Double],
        times: [TimeInterval],
        minWindowMs: Double = 60,
        maxWindowMs: Double = 250
    ) -> [Double] {
        guard series.count == times.count, series.count > 5 else { return series }

        let fps = effectiveFps(times)

        let baseWindow: Double
        if fps >= 50 {
            baseWindow = 80.0
        } else if fps <= 25 {
            baseWindow = 180.0
        } else {
            baseWindow = 80.0 + (50.0 - fps) * (100.0 / 25.0)
        }

        let heavyWindowMs = Swift.min(maxWindowMs, 250.0)
        let heavySmooth = savitzkyGolayMs(series, times, heavyWindowMs)
        let residual = zip(series, heavySmooth).map { $0 - $1 }
        let sigmaR = std(residual)
        let sigmaX = std(series)
        let noiseRatio = sigmaR / (sigmaX + 1e-6)

        var windowMs = baseWindow * (1.0 + 0.5 * noiseRatio)
        windowMs = Swift.min(Swift.max(windowMs, minWindowMs), maxWindowMs)

        return savitzkyGolayMs(series, times, windowMs)
    }

    /*
      Frame count for a requested span in milliseconds, always odd so the window
      stays centred, and clamped at both ends.

      The lower clamp of 3 keeps a median filter doing something. The upper clamp
      stops a very high frame rate capture from building a window so wide that the
      cost of running it outweighs what it removes.
    */
    public static func frameWindowFor(_ times: [Double], _ ms: Double, min minBound: Int = 3, max maxBound: Int = 31) -> Int {
        let dt = medianInterval(times)
        if dt == 0 { return minBound }
        var n = Int((ms / dt).rounded())
        if n % 2 == 0 { n += 1 }
        if n < minBound { n = minBound }
        if n > maxBound { n = maxBound }
        return n
    }

    public static func medianFilterMs(_ series: [Double], _ times: [Double], _ ms: Double, min: Int = 3, max: Int = 31) -> [Double] {
        medianFilter(series, window: frameWindowFor(times, ms, min: min, max: max))
    }

    public static func savitzkyGolayMs(_ series: [Double], _ times: [Double], _ ms: Double, min: Int = 5, max: Int = 31) -> [Double] {
        savitzkyGolay(series, window: frameWindowFor(times, ms, min: min, max: max))
    }

    /*
      Central difference derivative against a real timestamp array in milliseconds.
      Browser frame delivery is not uniform, so a fixed delta assumption quietly
      biases every speed reading. Returned units are series units per second.
    */
    public static func derivative(_ series: [Double], _ timesMs: [Double]) -> [Double] {
        let n = series.count
        var out = [Double](repeating: 0, count: n)
        if n < 2 { return out }
        for i in 0..<n {
            let i0 = max(0, i - 1)
            let i1 = min(n - 1, i + 1)
            let dt = (timesMs[i1] - timesMs[i0]) / 1000
            out[i] = dt > 1e-6 ? (series[i1] - series[i0]) / dt : 0
        }
        return out
    }

    public struct Peak {
        public var index: Int
        public var value: Double
    }

    /* Local maxima above a floor, with a minimum separation in samples. */
    public static func findPeaks(_ series: [Double], minValue: Double = -Double.infinity, minGap: Int = 3) -> [Peak] {
        var peaks: [Peak] = []
        if series.count < 3 { return peaks }
        for i in 1..<(series.count - 1) {
            if series[i] < minValue { continue }
            if series[i] >= series[i - 1] && series[i] > series[i + 1] {
                if let last = peaks.last, i - last.index < minGap {
                    if series[i] > last.value {
                        peaks[peaks.count - 1] = Peak(index: i, value: series[i])
                    }
                } else {
                    peaks.append(Peak(index: i, value: series[i]))
                }
            }
        }
        return peaks
    }

    public static func argMax(_ series: [Double], from: Int = 0, to: Int? = nil) -> Int {
        let toIndex = to ?? series.count - 1
        var best = from
        var i = from
        while i <= toIndex && i < series.count {
            if series[i] > series[best] { best = i }
            i += 1
        }
        return best
    }

    public static func argMin(_ series: [Double], from: Int = 0, to: Int? = nil) -> Int {
        let toIndex = to ?? series.count - 1
        var best = from
        var i = from
        while i <= toIndex && i < series.count {
            if series[i] < series[best] { best = i }
            i += 1
        }
        return best
    }

    /* Resample a series to a fixed length by linear interpolation. Used to put
       every swing on a common time base for trend charts and template matching. */
    public static func resample(_ series: [Double], _ length: Int) -> [Double] {
        if series.isEmpty { return [Double](repeating: 0, count: length) }
        var out = [Double](repeating: 0, count: length)
        for i in 0..<length {
            let denom = Double(length - 1 == 0 ? 1 : length - 1)
            let pos = (Double(i) / denom) * Double(series.count - 1)
            let lo = Int(pos.rounded(.down))
            let hi = min(series.count - 1, lo + 1)
            out[i] = lerp(series[lo], series[hi], pos - Double(lo))
        }
        return out
    }

    /*
      Map a raw measurement to a 0 to 100 score with a flat top inside the good
      band and a smooth falloff outside it. Beginners improve in steps, and a
      linear score makes a real gain look like nothing, which is the fastest
      way to lose someone in week two.
    */
    public static func bandScore(_ value: Double, _ bands: ScoreBands) -> Int {
        let (gLo, gHi) = bands.good
        if value >= gLo && value <= gHi { return 100 }
        let (oLo, oHi) = bands.ok
        let (hLo, hHi) = bands.hard
        if value < gLo {
            if value >= oLo { return Int((70 + 30 * ((value - oLo) / (gLo - oLo == 0 ? 1 : gLo - oLo))).rounded()) }
            if value >= hLo { return Int((30 + 40 * ((value - hLo) / (oLo - hLo == 0 ? 1 : oLo - hLo))).rounded()) }
            return Int(clamp(30 * (value / (hLo == 0 ? 1 : hLo)), 0, 30).rounded())
        }
        if value <= oHi { return Int((70 + 30 * ((oHi - value) / (oHi - gHi == 0 ? 1 : oHi - gHi))).rounded()) }
        if value <= hHi { return Int((30 + 40 * ((hHi - value) / (hHi - oHi == 0 ? 1 : hHi - oHi))).rounded()) }
        return Int(clamp(30 - 30 * ((value - hHi) / (hHi == 0 ? 1 : hHi)), 0, 30).rounded())
    }
}
