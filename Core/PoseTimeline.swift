//
//  PoseTimeline.swift
//  Swingline
//
//  A struct-of-arrays view of [Frame] for the upload post-processing pipeline.
//
//  Every cleanup and smoothing operation downstream is per joint, per channel:
//  reject an outlier in the left wrist's x track, gap fill the right ankle's y
//  track, low-pass everything. Doing that against [Frame] means mutating 33
//  Landmark structs per frame per pass. Converting once into flat channel
//  arrays (x[joint][frame] and friends) makes every filter a plain [Double]
//  operation, and converting back at the end hands the renderers, the
//  exporter and Analyze exactly the [Frame] currency they already speak, so
//  none of them change.
//
//  THE GRID
//
//  Zero-phase filtering assumes a uniform time base, and real clips are not
//  guaranteed to provide one (variable frame rate exists, and detection can
//  skip frames). So ingest resamples once onto a uniform grid, and that grid
//  becomes the canonical frame clock: PlaybackState is agnostic, it just reads
//  frameTimes, so the grid drives playback with no change on its side.
//
//  The grid rate is the requested rate capped at the clip's own measured rate.
//  Upsampling a 30 fps clip to a 60 Hz grid would invent frames that were
//  never captured and present them as data, which this codebase does not do.
//
//  MISSINGNESS
//
//  A missing sample is NaN in the coordinate channels. Missing means: the
//  detector reported nothing usable there (absent slot, non-finite value, or
//  a zero placeholder at zero confidence), or the two input frames bracketing
//  a grid point are too far apart to interpolate between honestly. The
//  cleanup engine widens this to include untrusted and outlier samples, then
//  fills the gaps; the round trip renders any still-missing sample as the
//  same zero placeholder at visibility 0 the providers use, which every
//  overlay already skips via its visibility floor.
//
//  NORM AND WORLD IN LOCKSTEP
//
//  Both spaces ride in one timeline and share the one grid, so any operation
//  applied to both keeps the drawn skeleton and the printed numbers in
//  agreement, which is the discipline VisionPoseProvider.stabilise states and
//  Landmarks.swift implies.
//
//  House rule: no em dashes anywhere.
//

import Foundation

public enum PoseSpace {
    case norm
    case world
}

public struct PoseTimeline {

    /// Per-space channel bank. Outer index is joint, inner is grid frame.
    /// NaN marks a missing sample. A joint with no valid samples anywhere in
    /// the clip (Vision has no heels or fingers) is NaN throughout and comes
    /// back out as placeholders, exactly as it went in.
    public struct Channels {
        public var x: [[Double]]
        public var y: [[Double]]
        /// All-NaN for a space that carries no depth (normalised image space
        /// on this build, and any backend that never filled z in).
        public var z: [[Double]]
        /// visibility ?? score per sample; NaN when the backend reported
        /// neither, which downstream treats as "unknown, act as trusted",
        /// matching the `visibility ?? score ?? 1` convention everywhere else.
        public var visibility: [[Double]]

        init(jointCount: Int, frameCount: Int) {
            let blank = [Double](repeating: .nan, count: frameCount)
            x = Array(repeating: blank, count: jointCount)
            y = Array(repeating: blank, count: jointCount)
            z = Array(repeating: blank, count: jointCount)
            visibility = Array(repeating: blank, count: jointCount)
        }
    }

    public let jointCount: Int
    /// The realised grid rate in Hz, after capping at the clip's own rate.
    public let gridHz: Double
    /// The measured input rate, for QC.
    public let inputFps: Double
    /// Uniform grid timestamps in milliseconds, ascending.
    public private(set) var times: [Double]
    public var norm: Channels
    public var world: Channels
    /// Per-frame overall confidence, carried through from Frame.conf so the
    /// validity gate reads the same quantity it always has (a per-detection
    /// figure, not a mean over placeholder slots).
    public private(set) var conf: [Double]

    public var frameCount: Int { times.count }

    // MARK: - Ingest

    /*
      Build from captured frames. resampleHz is a ceiling: the grid never runs
      faster than the frames actually arrived. Works for both backends; joint
      count is the 33-slot contract, widened only if a longer set ever appears.
    */
    public init(frames: [Frame], resampleHz: Double = 60) {
        // Strictly increasing input timeline; drop any frame that steps back.
        var input: [Frame] = []
        input.reserveCapacity(frames.count)
        var lastT = -Double.infinity
        for f in frames where f.t > lastT {
            input.append(f)
            lastT = f.t
        }

        let observedJoints = input.reduce(0) { Swift.max($0, $1.norm.count, $1.world.count) }
        let joints = Swift.max(33, observedJoints)
        self.jointCount = joints

        guard input.count >= 2 else {
            // Degenerate clip: mirror it straight through, no grid to build.
            self.gridHz = resampleHz
            self.inputFps = 0
            self.times = input.map { $0.t }
            self.conf = input.map { $0.conf }
            var n = Channels(jointCount: joints, frameCount: input.count)
            var w = Channels(jointCount: joints, frameCount: input.count)
            for (i, f) in input.enumerated() {
                Self.write(frame: f.norm, at: i, into: &n, joints: joints)
                Self.write(frame: f.world, at: i, into: &w, joints: joints)
            }
            self.norm = n
            self.world = w
            return
        }

        // Measure the clip's own cadence from the median frame interval, and
        // cap the grid there so no frame is invented.
        var dts: [Double] = []
        dts.reserveCapacity(input.count - 1)
        for i in 1..<input.count { dts.append(input[i].t - input[i - 1].t) }
        dts.sort()
        let medianDt = Swift.max(1.0, dts[dts.count / 2])
        let nativeHz = 1000.0 / medianDt
        let hz = Swift.max(5.0, Swift.min(resampleHz, nativeHz))
        self.gridHz = hz
        self.inputFps = nativeHz

        let t0 = input.first!.t
        let t1 = input.last!.t
        let step = 1000.0 / hz
        let count = Swift.max(2, Int(((t1 - t0) / step).rounded()) + 1)
        self.times = (0..<count).map { t0 + step * Double($0) }

        // Interpolation is honest only across a normal frame interval. Across
        // anything much longer, the detector genuinely lost the joint and the
        // gap must be visible to the cleanup engine, so it stays NaN here.
        let interpLimitMs = Swift.max(2.2 * medianDt, 50.0)

        var n = Channels(jointCount: joints, frameCount: count)
        var w = Channels(jointCount: joints, frameCount: count)
        Self.resample(input: input, sets: { $0.norm }, into: &n, times: times, joints: joints, interpLimitMs: interpLimitMs)
        Self.resample(input: input, sets: { $0.world }, into: &w, times: times, joints: joints, interpLimitMs: interpLimitMs)
        self.norm = n
        self.world = w

        // Frame confidence, linearly interpolated onto the grid. Always
        // defined, since every input frame carries a conf.
        var c = [Double](repeating: 0, count: count)
        var p = 0
        for (gi, g) in times.enumerated() {
            while p + 1 < input.count, input[p + 1].t <= g { p += 1 }
            if p + 1 >= input.count {
                c[gi] = input[p].conf
            } else {
                let a = input[p], b = input[p + 1]
                let span = b.t - a.t
                let f = span > 0 ? (g - a.t) / span : 0
                c[gi] = a.conf + (b.conf - a.conf) * Swift.min(Swift.max(f, 0), 1)
            }
        }
        self.conf = c
    }

    /// A landmark counts as present when its coordinates are finite and it is
    /// not the zero placeholder both providers write for untracked slots
    /// (origin at zero confidence).
    private static func present(_ l: Landmark) -> Bool {
        guard l.x.isFinite, l.y.isFinite else { return false }
        let trust = l.visibility ?? l.score
        if l.x == 0, l.y == 0, (trust ?? 0) == 0 { return false }
        return true
    }

    private static func write(frame set: LandmarkSet, at i: Int, into bank: inout Channels, joints: Int) {
        for j in 0..<Swift.min(joints, set.count) {
            let l = set[j]
            guard present(l) else { continue }
            bank.x[j][i] = l.x
            bank.y[j][i] = l.y
            if let z = l.z, z.isFinite { bank.z[j][i] = z }
            if let v = l.visibility ?? l.score { bank.visibility[j][i] = v }
        }
    }

    private static func resample(
        input: [Frame],
        sets: (Frame) -> LandmarkSet,
        into bank: inout Channels,
        times: [Double],
        joints: Int,
        interpLimitMs: Double
    ) {
        for j in 0..<joints {
            // Valid samples for this joint, in time order.
            var st: [Double] = [], sx: [Double] = [], sy: [Double] = []
            var sz: [Double] = [], sv: [Double] = []
            for f in input {
                let set = sets(f)
                guard j < set.count else { continue }
                let l = set[j]
                guard present(l) else { continue }
                st.append(f.t)
                sx.append(l.x)
                sy.append(l.y)
                sz.append((l.z?.isFinite == true) ? l.z! : .nan)
                sv.append((l.visibility ?? l.score) ?? .nan)
            }
            guard !st.isEmpty else { continue }  // dead joint, stays NaN

            var p = 0
            for (gi, g) in times.enumerated() {
                while p + 1 < st.count, st[p + 1] <= g { p += 1 }
                if abs(st[p] - g) < 0.5 {
                    bank.x[j][gi] = sx[p]; bank.y[j][gi] = sy[p]
                    bank.z[j][gi] = sz[p]; bank.visibility[j][gi] = sv[p]
                    continue
                }
                // Bracketing pair around g, if one exists on each side.
                let before = st[p] <= g ? p : p - 1
                let after = before + 1
                guard before >= 0, after < st.count else { continue }  // outside coverage
                let span = st[after] - st[before]
                guard span > 0, span <= interpLimitMs else { continue } // real gap, stays NaN
                let f = (g - st[before]) / span
                bank.x[j][gi] = sx[before] + (sx[after] - sx[before]) * f
                bank.y[j][gi] = sy[before] + (sy[after] - sy[before]) * f
                if sz[before].isFinite, sz[after].isFinite {
                    bank.z[j][gi] = sz[before] + (sz[after] - sz[before]) * f
                }
                if sv[before].isFinite, sv[after].isFinite {
                    bank.visibility[j][gi] = sv[before] + (sv[after] - sv[before]) * f
                }
            }
        }
    }

    // MARK: - Round trip

    /*
      Back to the interchange type. Anything still NaN comes out as the zero
      placeholder at visibility 0, which is the same shape the providers write
      for untracked joints, so every renderer's visibility floor handles it
      with no change. people is nil: the refined frames carry one person by
      construction, and the raw frames keep the original detections.
    */
    public func frames() -> [Frame] {
        var out: [Frame] = []
        out.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            var n = LandmarkSet(repeating: Landmark(x: 0, y: 0, visibility: 0), count: jointCount)
            var w = LandmarkSet(repeating: Landmark(x: 0, y: 0, visibility: 0), count: jointCount)
            for j in 0..<jointCount {
                if norm.x[j][i].isFinite, norm.y[j][i].isFinite {
                    n[j] = Landmark(
                        x: norm.x[j][i],
                        y: norm.y[j][i],
                        z: norm.z[j][i].isFinite ? norm.z[j][i] : nil,
                        visibility: norm.visibility[j][i].isFinite ? norm.visibility[j][i] : nil
                    )
                }
                if world.x[j][i].isFinite, world.y[j][i].isFinite {
                    w[j] = Landmark(
                        x: world.x[j][i],
                        y: world.y[j][i],
                        z: world.z[j][i].isFinite ? world.z[j][i] : nil,
                        visibility: world.visibility[j][i].isFinite ? world.visibility[j][i] : nil
                    )
                }
            }
            out.append(Frame(t: times[i], world: w, norm: n, conf: conf[i], people: nil))
        }
        return out
    }

    // MARK: - Channel access for the pipeline stages

    public func channels(_ space: PoseSpace) -> Channels {
        space == .norm ? norm : world
    }

    public mutating func setChannels(_ space: PoseSpace, _ bank: Channels) {
        if space == .norm { norm = bank } else { world = bank }
    }

    /// True when a joint has at least one measured sample in a space.
    public func jointIsAlive(_ space: PoseSpace, _ joint: Int) -> Bool {
        channels(space).x[joint].contains { $0.isFinite }
    }
}
