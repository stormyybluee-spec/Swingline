//
//  HandPathGate.swift
//  Swingline
//
//  Fix 3 of the OnForm parity pass: the hand path's start and stop, decided
//  by velocity and phase rather than by the clip's edges. The path draws
//  from the refined frames' lead wrist directly; the midpoint magnet that
//  once fed a separate anchor track here has been removed from the
//  pipeline, so there is nothing left to receive.
//
//  A NOTE ON PROVENANCE, the same situation PosePrior.swift once recorded:
//  TraceOverlay.swift and TrackingLayers.swift were not attached to this
//  round, so this file cannot rewrite them. What it does instead is own the
//  entire DECISION (where the path starts, where it stops, which positions
//  it is made of), computed once in UploadProcessor and carried on
//  Result.handPath, so the overlay's remaining job is rendering:
//
//      INTEGRATION (TraceOverlay / TrackingLayers, replacing wherever the
//      hand path polyline is currently accumulated from per-frame wrists):
//
//          let path = result.handPath
//          let points = path.filter { $0.active }.map {
//              CGPoint(x: $0.x * overlayWidth, y: $0.y * overlayHeight)
//          }
//          // draw points; $0.frameIndex aligns each sample to its frame
//          // for scrubbing and partial reveals.
//
//  WHY THE GATE LIVES HERE AND NOT IN THE OVERLAY
//
//  The overlay draws per frame and would have to re-derive speeds and
//  phases every layout pass; worse, a gate computed at render time cannot
//  be recorded. Computed once in the pipeline, the gate is deterministic,
//  rides the Result, and writes its verdict into TrackingQC
//  (handPathStartFrame, handPathStopFrame, handPathActiveFrames), which is
//  this codebase's standing rule: every stage says what it did.
//
//  THE STATE MACHINE (identical across views, as the benchmark's is)
//
//  START. The trigger is the brief's velocity threshold: grip speed above
//  0.3 m/s held for a few consecutive frames, so a single noise spike at
//  address cannot start the trace. The path then walks BACK from the
//  trigger, at most a fifth of a second, while the speed still sits above
//  the stop threshold, so the trace begins where the takeaway actually
//  began rather than mid ramp.
//
//  STOP. The brief verbatim: grip speed under 0.1 m/s for ten consecutive
//  frames AND the swing past P8. The path ends at the first frame of that
//  quiet run, which is the frame the hands actually came to rest. Without
//  phases (segmentation returned nil) the phase condition cannot be
//  honoured, so the quiet run must be half again as long instead, and the
//  gate says so in QC by simply being what it is.
//
//  SPEED. World grip speed in metres per second where the world channel
//  carries it, the brief's units. The Vision fallback has no world channel,
//  so the thresholds fall back to normalised units per second scaled by the
//  same world-to-norm ratio the hand collapse guard established (4.0 world
//  to 1.2 norm). The larger of the backward and forward step speeds is
//  used, the same both-sided rule as fastHandFrames, because motion peaks
//  between samples.
//
//  POSITIONS. The lead wrist slot of the refined frames. On the upload
//  path PosePrior's grip fusion has already run by the time these frames
//  are read, so that slot carries the fused grip point; the trace and the
//  skeleton therefore draw from the same corrected data.
//
//  House rule: no em dashes anywhere.
//

import Foundation

/// One hand path sample per grid frame. Positions are normalised image
/// coordinates, the overlay's currency. Codable so a future schema bump can
/// persist the path with the record if it wants to.
public struct HandPathSample: Codable, Hashable {
    /// Index into Result.frames, for scrubbing alignment.
    public var frameIndex: Int
    /// The frame's timestamp, milliseconds.
    public var t: Double
    /// Normalised image position of the hand path point.
    public var x: Double
    public var y: Double
    /// True between the gate's start and stop, inclusive. The overlay draws
    /// active samples and skips the rest.
    public var active: Bool

    public init(frameIndex: Int, t: Double, x: Double, y: Double, active: Bool) {
        self.frameIndex = frameIndex
        self.t = t
        self.x = x
        self.y = y
        self.active = active
    }
}

public enum HandPathBuilder {

    public struct Config {
        /// Start trigger, metres per second (the brief's 0.3), and how many
        /// consecutive frames must clear it.
        public var startSpeedWorld: Double = 0.3
        public var startRunFrames: Int = 3
        /// Stop threshold, metres per second (the brief's 0.1), and the
        /// quiet run length (the brief's 10 frames).
        public var stopSpeedWorld: Double = 0.1
        public var stopRunFrames: Int = 10
        /// The longer quiet run required when no phases exist to enforce
        /// the past-P8 half of the stop condition.
        public var stopRunFramesNoPhases: Int = 15
        /// Normalised-space fallbacks for the Vision backend, scaled by the
        /// same world-to-norm ratio the hand collapse guard uses.
        public var startSpeedNorm: Double = 0.10
        public var stopSpeedNorm: Double = 0.035
        /// The walk-back cap from the start trigger, frames (a fifth of a
        /// second at the 60 Hz grid), so a long slow waggle before the
        /// swing cannot be swallowed into the trace.
        public var maxStartWalkback: Int = 12

        public init() {}
    }

    /*
      Build the gated path. frames are the refined frames; phases the FINAL
      segmentation (the one Analyze saw), so the P8 the stop condition reads
      is the P8 the record reports. Positions are the lead wrist slot of
      those refined frames.
    */
    public static func build(
        frames: [Frame],
        phases: PhaseResult?,
        dominantHand: DominantHand,
        config: Config = Config(),
        qc: inout TrackingQC
    ) -> [HandPathSample] {
        let n = frames.count
        guard n > 4 else { return [] }

        // ---- Positions: the lead wrist slot of the refined frames. On the
        // upload path this is read AFTER PosePrior's grip fusion, so it is
        // the fused grip point (fusion writes the same point into both
        // wrist slots); on any pre-fusion caller it is the lead wrist
        // proper. With the midpoint magnet removed there is no longer a
        // separate anchor track to prefer: the trace follows the same
        // measured, corrected wrist the skeleton draws.
        let leadWrist = Landmarks.sides(dominantHand).leadWrist
        let lw = Landmarks.LEFT_WRIST, rw = Landmarks.RIGHT_WRIST
        var xs = [Double](repeating: .nan, count: n)
        var ys = [Double](repeating: .nan, count: n)
        for i in 0..<n {
            let set = frames[i].norm
            guard set.count > max(lw, rw, leadWrist) else { continue }
            let l = set[leadWrist]
            guard l.x.isFinite, l.y.isFinite else { continue }
            xs[i] = l.x
            ys[i] = l.y
        }

        // ---- Speeds: world preferred, norm fallback, both-sided max.
        func gripWorld(_ i: Int) -> (x: Double, y: Double, z: Double)? {
            let set = frames[i].world
            guard set.count > rw else { return nil }
            let l = set[lw], r = set[rw]
            guard l.x.isFinite, l.y.isFinite, r.x.isFinite, r.y.isFinite else { return nil }
            let z: Double
            if let zl = l.z, let zr = r.z, zl.isFinite, zr.isFinite { z = (zl + zr) / 2 } else { z = .nan }
            return ((l.x + r.x) / 2, (l.y + r.y) / 2, z)
        }

        func stepSpeedWorld(_ i: Int, _ k: Int) -> Double? {
            guard let a = gripWorld(i), let b = gripWorld(k) else { return nil }
            let dtSec = abs(frames[i].t - frames[k].t) / 1000
            guard dtSec > 1e-4 else { return nil }
            let dx = a.x - b.x, dy = a.y - b.y
            var d2 = dx * dx + dy * dy
            if a.z.isFinite, b.z.isFinite { let dz = a.z - b.z; d2 += dz * dz }
            return d2.squareRoot() / dtSec
        }

        func stepSpeedNorm(_ i: Int, _ k: Int) -> Double? {
            guard xs[i].isFinite, xs[k].isFinite else { return nil }
            let dtSec = abs(frames[i].t - frames[k].t) / 1000
            guard dtSec > 1e-4 else { return nil }
            let dx = xs[i] - xs[k], dy = ys[i] - ys[k]
            return (dx * dx + dy * dy).squareRoot() / dtSec
        }

        // moving[i]: above the start trigger. quiet[i]: below the stop
        // threshold. Each frame is judged in whichever space it carries,
        // against that space's own threshold.
        var moving = [Bool](repeating: false, count: n)
        var quiet = [Bool](repeating: true, count: n)
        for i in 0..<n {
            var worldSpeed: Double? = nil
            if i > 0, let s = stepSpeedWorld(i, i - 1) { worldSpeed = s }
            if i + 1 < n, let s = stepSpeedWorld(i, i + 1) { worldSpeed = Swift.max(worldSpeed ?? 0, s) }
            if let ws = worldSpeed {
                moving[i] = ws > config.startSpeedWorld
                quiet[i] = ws < config.stopSpeedWorld
                continue
            }
            var normSpeed: Double? = nil
            if i > 0, let s = stepSpeedNorm(i, i - 1) { normSpeed = s }
            if i + 1 < n, let s = stepSpeedNorm(i, i + 1) { normSpeed = Swift.max(normSpeed ?? 0, s) }
            if let ns = normSpeed {
                moving[i] = ns > config.startSpeedNorm
                quiet[i] = ns < config.stopSpeedNorm
            }
        }

        // ---- START: the sustained trigger, then the bounded walk-back.
        var start: Int? = nil
        let runLen = Swift.max(1, config.startRunFrames)
        if n >= runLen {
            outer: for i in 0...(n - runLen) {
                for k in i..<(i + runLen) where !moving[k] { continue outer }
                start = i
                break
            }
        }
        guard var startFrame = start else {
            // The hands never moved: an all-inactive path, and QC's zeros
            // read as "the gate never opened", which is the truth.
            return (0..<n).map { i in
                HandPathSample(frameIndex: i, t: frames[i].t,
                               x: xs[i].isFinite ? xs[i] : 0,
                               y: ys[i].isFinite ? ys[i] : 0,
                               active: false)
            }
        }
        var walked = 0
        while startFrame > 0, walked < config.maxStartWalkback, !quiet[startFrame - 1] {
            startFrame -= 1
            walked += 1
        }

        // ---- STOP: the quiet run, past P8 when phases exist.
        let p8Index = phases?.idx[.p8]
        let quietRun = p8Index != nil ? config.stopRunFrames : config.stopRunFramesNoPhases
        let earliestStop = Swift.max(startFrame + 1, p8Index ?? (startFrame + 1))

        var stopFrame = n - 1
        if earliestStop <= n - quietRun {
            search: for f in earliestStop...(n - quietRun) {
                for k in f..<(f + quietRun) where !quiet[k] { continue search }
                stopFrame = f
                break
            }
        }

        qc.handPathStartFrame = startFrame
        qc.handPathStopFrame = stopFrame
        qc.handPathActiveFrames = stopFrame - startFrame + 1

        return (0..<n).map { i in
            HandPathSample(
                frameIndex: i, t: frames[i].t,
                x: xs[i].isFinite ? xs[i] : 0,
                y: ys[i].isFinite ? ys[i] : 0,
                active: i >= startFrame && i <= stopFrame && xs[i].isFinite
            )
        }
    }
}
