//
//  AdaptiveSmoothing.swift
//  Swingline
//
//  Offline temporal smoothing for the upload pipeline. Vectors O (adaptive
//  window, now using Geometry.adaptiveSavitzkyGolay as the residual noise
//  estimator, which was written for exactly this and marked "not yet wired"),
//  S in its full Phase 2 form (speed and phase scheduled cutoffs, per-joint
//  frequency bands), and T (visibility-weighted smoothing). Replaces Vector
//  J's trailing average, which was rejected: a trailing window is group delay
//  by construction, and offline we can afford zero-phase filtering, which
//  strictly dominates it.
//
//  WHY ZERO PHASE
//
//  Every filter that only looks backwards drags its output behind the truth,
//  and on a swing that lag lands exactly where it hurts most, at impact. A
//  forward-backward pass runs the same filter twice, once in each direction,
//  so the two lags cancel: peaks stay where they happened, the tempo ratio is
//  untouched, and P7 lands on the frame it landed on. This is only possible
//  because the upload path has the whole clip in hand; the live path keeps
//  its One Euro filter, which is the right tool when the future is unknown.
//
//  THE SCHEDULE (Task 1, Vectors O and S merged)
//
//  A single cutoff cannot serve both ends of a swing: 6 Hz rounds the release
//  off through impact, and 12 Hz lets address-frame jitter through untouched.
//  The Phase 2 answer is a continuous per-frame schedule rather than hard
//  phase switching, exactly as the roadmap disposed of Vectors O and S,
//  because phase indices are themselves estimates and a hard switch at an
//  estimated boundary is an artifact generator.
//
//  Each joint carries a cutoff BAND, and a per-frame weight s in [0, 1]
//  interpolates across it:
//
//      cutoff[joint][frame] = band.low + (band.high - band.low) * s[frame]
//
//  s is built from the hand-speed envelope of the provisional pass-1 series,
//  shaped by the provisional phases: capped low before P4 (the backswing
//  stays firm), floored high from the transition through P8 (the release
//  keeps its detail even where the envelope dips), decaying after P8 as the
//  follow through settles. The schedule is then itself low-passed, so the
//  effective cutoff glides rather than steps.
//
//  The bands reconcile the brief's two sets of numbers (phase targets of
//  4-5 / 8-10 / 6 Hz, and per-joint targets of 6-8 / 10-12 / 12-15 Hz): the
//  band highs are the per-joint downswing targets, the band lows are what
//  the backswing cap resolves to, and the follow-through lands mid band.
//
//      torso, pelvis, head   4 ... 8 Hz
//      elbows, legs, feet    5 ... 12 Hz
//      wrists and hands      6 ... 15 Hz
//
//  A per-frame cutoff cannot be realised by one time-invariant Butterworth,
//  so it is realised the same way Vector T already is: each channel is
//  filtered once at the band's low end and once at its high end, both zero
//  phase, and the output crossfades between the two by s. A blend of two
//  zero-phase signals is zero phase, so nothing here re-introduces the lag
//  this file exists to avoid.
//
//  PER-SAMPLE WEIGHTS (Vector T, unchanged)
//
//  A classic Butterworth has no per-sample weight, so Vector T lives here as
//  a second crossfade toward a heavier filter, blended by that sample's
//  visibility. A well-seen sample keeps the light filter's detail; a
//  poorly-seen one leans on the heavier filter's stability.
//
//  THE FINISH POLISH (final pass, Video 1 audit)
//
//  The audit's remaining complaint after scheduling: residual micro-jitter
//  through the finish hold (00:19 to 00:28 in the reference clip), where the
//  golfer is nearly still, the scheduled cutoff is already at the band low,
//  and what is left is small uncorrelated wobble the Butterworth's passband
//  legitimately admits. The fix is an optional FINAL PASS over each smoothed
//  channel, EMA or Kalman per config.
//
//  Two decisions keep it honest to this file's own reasoning:
//
//  The brief said "EMA", and a causal EMA is exactly the trailing filter the
//  header above rejects: group delay by construction. So the EMA here is run
//  forward and then backward by default (a first-order filtfilt in all but
//  name), and the Kalman option is a forward filter plus RTS backward
//  smoother, which is likewise zero phase. Peaks stay where they happened.
//  The strictly causal single-direction EMA remains available behind
//  bidirectional = false for parity experiments, and for nothing else.
//
//  The pass is SPEED GATED by default: its output is blended in by (1 - s)
//  where s is the schedule weight, or by a per-joint low-speed gate when no
//  schedule exists. The polish therefore owns the address and the finish
//  hold, tapers through transition, and leaves impact strictly alone, so it
//  cannot round off the one instant the schedule fought to preserve.
//
//  ONFORM PARITY ADDITIONS (final accuracy overhaul), two new tools:
//
//  Fix 2: OcclusionRTSSmoother, at the bottom of this file. The scheduled
//  Butterworth treats every sample as equally true, and during the DTL
//  downswing the occluded lead arm's samples are not: they teleport, and a
//  Butterworth run over a teleport smears it rather than removing it. The
//  occlusion smoother finds the windows where a joint's visibility fell
//  under the occlusion floor, runs a constant-velocity Kalman FORWARD and
//  an RTS smoother BACKWARD across each padded window with per-sample
//  measurement noise inflated by how blind the tracker admitted to being,
//  and crossfades the result in over the pads. Inside the window the low
//  trust samples barely tug the filter, so the forward pass coasts on the
//  arm's own dynamics and the backward pass bends that coast to meet the
//  first honestly seen sample after the occlusion, which is exactly the
//  forward-backward reconstruction the benchmark performs. Outside the
//  windows nothing changes at all.
//
//  Fix 6: ClubHeadPathSmoother, likewise at the bottom. The club head
//  trajectory never passed through this file: the skeleton got zero-phase
//  smoothing and the fastest, noisiest track in the scene got none, which
//  is why it reads jagged next to the benchmark. The smoother exposes the
//  same forward-backward Butterworth (via zeroPhaseLowPass, now a public
//  static so overlay code can reach it) applied piecewise over the finite
//  runs of a club head track, never bridging its gaps, so future frames
//  cancel the lag and a missing detection stays honestly missing.
//
//  House rule: no em dashes anywhere.
//

import Foundation
import CoreGraphics

public final class TemporalSmoothingService {

    // MARK: - Configuration

    /// The pass-1 series the schedule is built from. Times are the series'
    /// own millisecond timestamps; they normally coincide with the timeline
    /// grid, but the schedule is aligned by time rather than by index so a
    /// mismatch degrades to interpolation instead of misregistration.
    public struct ScheduleSource {
        public var handSpeed: [Double]
        public var times: [Double]
        public var phases: PhaseResult?

        public init(handSpeed: [Double], times: [Double], phases: PhaseResult?) {
            self.handSpeed = handSpeed
            self.times = times
            self.phases = phases
        }
    }

    /// The finish polish. See the header note for what it is and why the
    /// EMA is bidirectional by default.
    public struct FinalPassConfig {
        public enum Kind {
            /// Zero-phase EMA (forward then backward) at this alpha. At the
            /// 60 Hz grid, 0.35 lands around a 4 to 5 Hz single-pole knee,
            /// gentle enough to only eat uncorrelated wobble.
            case ema(alpha: Double)
            /// Constant-velocity Kalman forward filter with an RTS backward
            /// smoother. processNoise is the white-acceleration spectral
            /// density in channel units per second squared (30 to 80 is a
            /// reasonable normalised-space start), measurementNoise is the
            /// per-sample variance (around 1e-5 for a couple of millipixels
            /// of jitter at typical framing).
            case kalman(processNoise: Double, measurementNoise: Double)
        }

        public var kind: Kind
        /// Forward-backward for the EMA so the pass stays zero phase. The
        /// Kalman path is zero phase by construction and ignores this.
        public var bidirectional: Bool
        /// Blend the polished output in only where motion is slow: by
        /// (1 - schedule) when a schedule exists, by a per-joint low-speed
        /// gate otherwise. Off means the pass applies everywhere, which
        /// WILL soften impact and exists for experiments only.
        public var speedGated: Bool
        /// Round four: optional per-joint kind resolution, so one pass can
        /// polish the wrists lighter than the body (the face-on profile's
        /// 0.5 wrist alpha against 0.35 elsewhere). Nil means the single
        /// kind above rules every joint, so every existing caller compiles
        /// and behaves exactly as before. Gating and direction stay shared:
        /// only the kind varies per joint, because the gate is the schedule
        /// and the schedule is one clip-wide fact.
        public var kindForJoint: ((Int) -> Kind)?

        public init(
            kind: Kind = .ema(alpha: 0.35),
            bidirectional: Bool = true,
            speedGated: Bool = true,
            kindForJoint: ((Int) -> Kind)? = nil
        ) {
            self.kind = kind
            self.bidirectional = bidirectional
            self.speedGated = speedGated
            self.kindForJoint = kindForJoint
        }

        /// The kind that actually applies to this joint.
        public func kind(for joint: Int) -> Kind {
            kindForJoint?(joint) ?? kind
        }
    }

    public struct Config {
        /// Cutoff in Hz for a joint when no schedule is present (the uniform
        /// and perJoint factories). Ignored when a schedule and bands exist.
        public var cutoffForJoint: (Int) -> Double

        /// Task 1: the per-joint cutoff band the schedule interpolates
        /// across. Nil means no scheduling and cutoffForJoint rules alone.
        public var bandForJoint: ((Int) -> ClosedRange<Double>)?
        /// Task 1: the source the per-frame schedule is built from.
        public var scheduleSource: ScheduleSource?

        /// Vector O. When true, each joint's cutoff (or band) is scaled down
        /// by up to (1 - adaptiveFloor) on channels whose residual against
        /// Geometry.adaptiveSavitzkyGolay says the track is noisy, so a hazy
        /// clip gets a firmer hand and a clean one keeps its detail.
        public var adaptive: Bool
        public var adaptiveFloor: Double

        /// Vector T. When true, output blends between the scheduled cutoff and
        /// a heavier one by per-sample visibility.
        public var visibilityWeighting: Bool
        /// The heavier filter's cutoff as a fraction of the scheduled one.
        public var heavyRatio: Double
        /// Visibility mapped to blend weight over this range: at or below the
        /// lower bound the heavy filter carries the sample, at or above the
        /// upper bound the light one does.
        public var visibilityBlendRange: ClosedRange<Double>

        /// The finish polish. Nil (the default) means no final pass, so
        /// every existing configuration behaves exactly as before.
        public var finalPass: FinalPassConfig?

        public init(
            cutoffForJoint: @escaping (Int) -> Double,
            bandForJoint: ((Int) -> ClosedRange<Double>)? = nil,
            scheduleSource: ScheduleSource? = nil,
            adaptive: Bool = true,
            adaptiveFloor: Double = 0.65,
            visibilityWeighting: Bool = true,
            heavyRatio: Double = 0.5,
            visibilityBlendRange: ClosedRange<Double> = 0.1...0.6,
            finalPass: FinalPassConfig? = nil
        ) {
            self.cutoffForJoint = cutoffForJoint
            self.bandForJoint = bandForJoint
            self.scheduleSource = scheduleSource
            self.adaptive = adaptive
            self.adaptiveFloor = adaptiveFloor
            self.visibilityWeighting = visibilityWeighting
            self.heavyRatio = heavyRatio
            self.visibilityBlendRange = visibilityBlendRange
            self.finalPass = finalPass
        }
    }

    private let config: Config

    public init(config: Config) {
        self.config = config
    }

    // MARK: - Factories

    /// One cutoff everywhere. This remains the pass-1 configuration and the
    /// fallback when phase segmentation returns nil, so a clip whose phases
    /// could not be read still gets honest zero-phase smoothing.
    public static func uniform(
        cutoffHz: Double, adaptive: Bool = true,
        finalPass: FinalPassConfig? = nil
    ) -> TemporalSmoothingService {
        TemporalSmoothingService(config: Config(
            cutoffForJoint: { _ in cutoffHz },
            adaptive: adaptive,
            finalPass: finalPass
        ))
    }

    /*
      Per-joint scheduling without a per-frame schedule, the v1 form kept for
      callers that have no provisional series in hand. The full scheduled
      factory below supersedes it on the upload path.
    */
    public static func perJoint(
        bodyHz: Double = 7, limbHz: Double = 9, wristHz: Double = 13,
        adaptive: Bool = true,
        finalPass: FinalPassConfig? = nil
    ) -> TemporalSmoothingService {
        TemporalSmoothingService(config: Config(
            cutoffForJoint: { joint in
                if Self.wristJoints.contains(joint) { return wristHz }
                if Self.limbJoints.contains(joint) { return limbHz }
                return bodyHz
            },
            adaptive: adaptive,
            finalPass: finalPass
        ))
    }

    /*
      TASK 1. The Phase 2 configuration: per-joint bands, interpolated per
      frame by a schedule built from the provisional hand-speed envelope and
      phases. Pass series.handSpeed, series.t and the provisional PhaseResult
      from pass 1; phases may be nil, in which case the schedule follows the
      speed envelope alone, which is still the continuous form the roadmap
      prefers over hard switching.
    */
    public static func scheduled(
        handSpeed: [Double],
        times: [Double],
        phases: PhaseResult?,
        adaptive: Bool = true,
        finalPass: FinalPassConfig? = nil
    ) -> TemporalSmoothingService {
        TemporalSmoothingService(config: Config(
            cutoffForJoint: { joint in
                // Fallback midpoint, used only if the schedule cannot build.
                let band = Self.defaultBand(for: joint)
                return (band.lowerBound + band.upperBound) / 2
            },
            bandForJoint: { Self.defaultBand(for: $0) },
            scheduleSource: ScheduleSource(handSpeed: handSpeed, times: times, phases: phases),
            adaptive: adaptive,
            finalPass: finalPass
        ))
    }

    /*
      ROUND FOUR VIEW ROUTING (R6b, verdict 18). The same scheduled factory,
      plus the classified view. The public factory above is untouched and
      keeps today's behaviour exactly; this overload is internal because
      SwingView itself is declared internal (MediaPipePoseProvider.swift),
      and `view` carries no default so the two factories can never be
      ambiguous at a call site.

      What the view changes, and only when it is .faceOn:

      HIP BAND CEILING. Hips fall through to the default torso band, 4...8,
      the lowest ceiling in the system, and a fast face-on pelvis rotation
      through impact genuinely exceeds what 8 Hz preserves: that is the
      audited hip marker lagging onto the lower femur. The ceiling rises to
      11 for the two hips ONLY. Shoulders stay at 8 on purpose: their
      high-frequency content at impact is mostly arm bleed-through, and the
      shoulder stage upstream depends on stable shoulders. Going to 15
      would let crossing-window wrist noise leak into the pelvis line that
      every rotation metric reads. Note the backswing cap in buildSchedule
      is deliberately NOT the lever here: it applies only before P4 and the
      lag is at impact.

      WRIST POLISH. The final pass, when the caller asked for one, resolves
      to a lighter 0.5 EMA on the wrist set (0.35 default elsewhere). The
      pass is speed gated, so this mostly shapes the release and finish,
      which is exactly where the audit sees the lag tail; above 0.6 the
      polish stops earning its place at address. Installed only when the
      caller has not already resolved kinds per joint, so an explicit
      kindForJoint always wins.

      DTL and nil route everything to defaultBand and leave the pass alone:
      a misclassified clip degrades to slightly different tuning, never to
      different logic.
    */
    static func scheduled(
        handSpeed: [Double],
        times: [Double],
        phases: PhaseResult?,
        view: SwingView?,
        adaptive: Bool = true,
        finalPass: FinalPassConfig? = nil
    ) -> TemporalSmoothingService {
        var routedPass = finalPass
        if view == .faceOn, var pass = routedPass, pass.kindForJoint == nil {
            let baseKind = pass.kind
            pass.kindForJoint = { joint in
                Self.wristJoints.contains(joint) ? .ema(alpha: 0.5) : baseKind
            }
            routedPass = pass
        }
        return TemporalSmoothingService(config: Config(
            cutoffForJoint: { joint in
                // Fallback midpoint, used only if the schedule cannot build.
                let band = Self.scheduledBand(for: joint, view: view)
                return (band.lowerBound + band.upperBound) / 2
            },
            bandForJoint: { Self.scheduledBand(for: $0, view: view) },
            scheduleSource: ScheduleSource(handSpeed: handSpeed, times: times, phases: phases),
            adaptive: adaptive,
            finalPass: routedPass
        ))
    }

    /// The view-aware band table (round four), wrapping defaultBand. See
    /// the routing note above for why the ceiling moves for the hips only
    /// and only face-on. Internal for the SwingView reason above.
    static func scheduledBand(for joint: Int, view: SwingView?) -> ClosedRange<Double> {
        if view == .faceOn,
           joint == Landmarks.LEFT_HIP || joint == Landmarks.RIGHT_HIP {
            return 4...11
        }
        return defaultBand(for: joint)
    }

    /// The band definitions from the header note. Public so QC and tests can
    /// state what the schedule actually spans.
    public static func defaultBand(for joint: Int) -> ClosedRange<Double> {
        if wristJoints.contains(joint) { return 6...15 }
        if limbJoints.contains(joint) { return 5...12 }
        return 4...8
    }

    private static let wristJoints: Set<Int> = [
        Landmarks.LEFT_WRIST, Landmarks.RIGHT_WRIST,
        Landmarks.LEFT_PINKY, Landmarks.RIGHT_PINKY,
        Landmarks.LEFT_INDEX, Landmarks.RIGHT_INDEX,
        Landmarks.LEFT_THUMB, Landmarks.RIGHT_THUMB,
    ]
    private static let limbJoints: Set<Int> = [
        Landmarks.LEFT_ELBOW, Landmarks.RIGHT_ELBOW,
        Landmarks.LEFT_KNEE, Landmarks.RIGHT_KNEE,
        Landmarks.LEFT_ANKLE, Landmarks.RIGHT_ANKLE,
        Landmarks.LEFT_HEEL, Landmarks.RIGHT_HEEL,
        Landmarks.LEFT_FOOT_INDEX, Landmarks.RIGHT_FOOT_INDEX,
    ]

    // MARK: - Entry point

    public func run(_ timeline: inout PoseTimeline) {
        let fs = timeline.gridHz
        guard fs > 0, timeline.frameCount > 8 else { return }

        // Build the per-frame schedule once, on the timeline's own grid. Nil
        // when no source was configured or the source is degenerate, in
        // which case every joint falls back to its single fallback cutoff.
        let schedule = config.scheduleSource.flatMap {
            buildSchedule(source: $0, gridTimes: timeline.times, fs: fs)
        }

        for space in [PoseSpace.norm, PoseSpace.world] {
            var bank = timeline.channels(space)
            for joint in 0..<timeline.jointCount {
                // Dead or partially missing joints are not filtered: the
                // cleanup engine runs first and leaves every alive joint
                // complete, so any remaining NaN means "never measured" and
                // must not be smeared into numbers.
                guard bank.x[joint].allSatisfy({ $0.isFinite }) else { continue }

                let scale = config.adaptive
                    ? adaptiveScale(x: bank.x[joint], y: bank.y[joint], times: timeline.times)
                    : 1.0

                let visibility = bank.visibility[joint]

                if let schedule, let bandFor = config.bandForJoint {
                    // Scheduled path (Task 1). The adaptive scale narrows
                    // the whole band on a noisy channel, which is Vector O
                    // acting on Vector S's schedule rather than fighting it.
                    let band = bandFor(joint)
                    let lowHz = band.lowerBound * scale
                    let highHz = Swift.max(band.upperBound * scale, lowHz + 0.1)

                    bank.x[joint] = smoothScheduled(bank.x[joint], lowHz: lowHz, highHz: highHz, weights: schedule, fs: fs, visibility: visibility)
                    bank.y[joint] = smoothScheduled(bank.y[joint], lowHz: lowHz, highHz: highHz, weights: schedule, fs: fs, visibility: visibility)
                    if bank.z[joint].allSatisfy({ $0.isFinite }) {
                        bank.z[joint] = smoothScheduled(bank.z[joint], lowHz: lowHz, highHz: highHz, weights: schedule, fs: fs, visibility: visibility)
                    }
                } else {
                    // Uniform / perJoint path, unchanged in behaviour.
                    let cutoff = config.cutoffForJoint(joint) * scale
                    bank.x[joint] = smooth(bank.x[joint], cutoffHz: cutoff, fs: fs, visibility: visibility)
                    bank.y[joint] = smooth(bank.y[joint], cutoffHz: cutoff, fs: fs, visibility: visibility)
                    if bank.z[joint].allSatisfy({ $0.isFinite }) {
                        bank.z[joint] = smooth(bank.z[joint], cutoffHz: cutoff, fs: fs, visibility: visibility)
                    }
                }

                // The finish polish (see the header note). Runs on the
                // already smoothed channels, gated so it owns the still
                // stretches and leaves impact strictly alone. The gate is
                // the inverted schedule when one exists, this joint's own
                // low-speed gate otherwise, and is computed AFTER the main
                // smoothing so glitches the Butterworth already removed
                // cannot masquerade as motion and lift the gate.
                if let fp = config.finalPass {
                    let gate: [Double]?
                    if fp.speedGated {
                        if let schedule {
                            gate = schedule.map { 1 - $0 }
                        } else {
                            gate = lowSpeedGate(
                                x: bank.x[joint], y: bank.y[joint],
                                times: timeline.times, fs: fs
                            )
                        }
                    } else {
                        gate = nil
                    }
                    // Round four: the kind can resolve per joint (the
                    // face-on wrist polish); the gate and direction stay
                    // shared. See FinalPassConfig.kindForJoint.
                    var fpJoint = fp
                    fpJoint.kind = fp.kind(for: joint)
                    bank.x[joint] = finalPolish(bank.x[joint], fs: fs, gate: gate, config: fpJoint)
                    bank.y[joint] = finalPolish(bank.y[joint], fs: fs, gate: gate, config: fpJoint)
                    if bank.z[joint].allSatisfy({ $0.isFinite }) {
                        bank.z[joint] = finalPolish(bank.z[joint], fs: fs, gate: gate, config: fpJoint)
                    }
                }
                // Visibility itself is never smoothed: it is metadata about
                // trust, and a smoothed trust figure would overstate bad
                // samples and understate good ones.
            }
            timeline.setChannels(space, bank)
        }
    }

    // MARK: - The schedule (Task 1)

    /*
      Per-frame weight in [0, 1] on the timeline grid.

      Built in four steps: resample the hand-speed series onto the grid by
      time; normalise it into an envelope and pass it through a soft knee, so
      the whole downswing sits at 1 rather than only the single peak frame;
      shape it with the provisional phases (cap before P4, floor from the
      transition through P8, decay after); then low-pass the result so the
      effective cutoff glides. Returns nil when the source cannot support a
      schedule, and the caller falls back to a single cutoff.
    */
    private func buildSchedule(source: ScheduleSource, gridTimes: [Double], fs: Double) -> [Double]? {
        guard source.handSpeed.count == source.times.count,
              source.handSpeed.count >= 4, gridTimes.count >= 4 else { return nil }

        let speed = Self.resampleByTime(values: source.handSpeed, from: source.times, to: gridTimes)
        guard let peak = speed.max(), peak > 1e-6 else { return nil }

        // Envelope with a soft knee: half of peak speed already earns the
        // full band, so the schedule holds high through the whole downswing
        // rather than spiking at the single fastest frame.
        var s = speed.map { Self.smoothstep($0 / peak, 0.06, 0.5) }

        if let phases = source.phases,
           let p4i = phases.idx[.p4], let p8i = phases.idx[.p8],
           p4i < source.times.count, p8i < source.times.count {
            let p4t = source.times[p4i]
            // A short pad past P8 keeps the floor up through the release
            // rather than dropping it on the estimated boundary frame.
            let p8t = source.times[p8i] + 100

            for i in 0..<s.count {
                let t = gridTimes[i]
                // Backswing cap: firm smoothing before the top. The cap is on
                // the weight, not the data, so a violently fast takeaway can
                // still not push the backswing to the impact band.
                //
                // Round four record: raising this cap was proposed as the fix
                // for the face-on hip lag and REJECTED, because the cap
                // applies only before P4 and the audited lag is at impact.
                // The actual lever is the hip band ceiling in scheduledBand.
                // Recorded here so the next round does not re-propose it.
                let cap: Double = t < p4t ? 0.35 : 1.0
                // Downswing floor: full band from the transition through P8
                // plus pad, then a 400 ms glide down to a mid-band hold, the
                // follow-through's 6 Hz-ish target.
                let floor: Double
                if t < p4t {
                    floor = 0
                } else if t <= p8t {
                    floor = 0.85
                } else {
                    floor = Swift.max(0.35, 0.85 - 0.5 * (t - p8t) / 400.0)
                }
                s[i] = Geometry.clamp(Swift.max(s[i], floor), 0, cap)
            }
        }

        // Glide, not step: the schedule itself is low-passed at 3 Hz, zero
        // phase, so the crossfade below cannot manufacture a boundary
        // artifact at an estimated phase index.
        s = filtfilt(s, cutoffHz: 3, fs: fs).map { Geometry.clamp($0, 0, 1) }
        return s
    }

    /// Linear resample by timestamp, clamped at both ends.
    private static func resampleByTime(values: [Double], from t: [Double], to grid: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: grid.count)
        var p = 0
        for (gi, g) in grid.enumerated() {
            while p + 1 < t.count, t[p + 1] <= g { p += 1 }
            if p + 1 >= t.count {
                out[gi] = values[t.count - 1]
            } else if g <= t[0] {
                out[gi] = values[0]
            } else {
                let span = t[p + 1] - t[p]
                let f = span > 0 ? Geometry.clamp((g - t[p]) / span, 0, 1) : 0
                out[gi] = values[p] + (values[p + 1] - values[p]) * f
            }
        }
        return out
    }

    /// Hermite smoothstep, shared by the schedule and the low-speed gate.
    private static func smoothstep(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        let t = Geometry.clamp((x - lo) / Swift.max(hi - lo, 1e-9), 0, 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: - The finish polish (final pass)

    /*
      Per-joint gate for the uniform and perJoint paths, which have no
      schedule to invert: the joint's own step speed, normalised by its own
      peak, mapped through an inverted smoothstep so stillness reads 1 and
      real motion reads 0, then low-passed at the same 3 Hz glide the
      schedule uses so the gate cannot flap frame to frame. A channel that
      never moves (peak effectively zero) gates fully open, which is right:
      it is all stillness and the polish is exactly for it.
    */
    private func lowSpeedGate(x: [Double], y: [Double], times: [Double], fs: Double) -> [Double] {
        let n = x.count
        guard n > 4, y.count == n, times.count == n else {
            return [Double](repeating: 1, count: n)
        }
        var speed = [Double](repeating: 0, count: n)
        for i in 1..<n {
            let dt = (times[i] - times[i - 1]) / 1000
            guard dt > 1e-4 else { continue }
            let dx = x[i] - x[i - 1], dy = y[i] - y[i - 1]
            speed[i] = (dx * dx + dy * dy).squareRoot() / dt
        }
        if n > 1 { speed[0] = speed[1] }
        guard let peak = speed.max(), peak > 1e-9 else {
            return [Double](repeating: 1, count: n)
        }
        var g = speed.map { 1 - Self.smoothstep($0 / peak, 0.04, 0.3) }
        g = filtfilt(g, cutoffHz: 3, fs: fs).map { Geometry.clamp($0, 0, 1) }
        return g
    }

    /// One channel through the configured polish, blended in by the gate
    /// (nil gate means fully applied). The polished signal and the input
    /// are both zero phase, so any pointwise blend of them is too.
    private func finalPolish(
        _ channel: [Double], fs: Double, gate: [Double]?, config fp: FinalPassConfig
    ) -> [Double] {
        guard channel.count > 4 else { return channel }
        let polished: [Double]
        switch fp.kind {
        case .ema(let alpha):
            let a = Geometry.clamp(alpha, 0.01, 1)
            polished = fp.bidirectional
                ? Self.emaZeroPhase(channel, alpha: a)
                : Self.emaForward(channel, alpha: a)
        case .kalman(let q, let r):
            polished = Self.kalmanRTS(
                channel, dt: 1 / fs,
                processNoise: Swift.max(q, 1e-9),
                measurementNoise: Swift.max(r, 1e-12)
            )
        }
        guard let gate else { return polished }
        var out = channel
        for i in 0..<out.count {
            let g = i < gate.count ? Geometry.clamp(gate[i], 0, 1) : 0
            out[i] = g * polished[i] + (1 - g) * channel[i]
        }
        return out
    }

    /// The strictly causal EMA, kept only for bidirectional = false parity
    /// experiments. It lags by construction; see the header.
    private static func emaForward(_ x: [Double], alpha: Double) -> [Double] {
        guard x.count > 1 else { return x }
        var y = x
        for i in 1..<x.count {
            y[i] = y[i - 1] + alpha * (x[i] - y[i - 1])
        }
        return y
    }

    /// Forward then backward, so the two group delays cancel: a first-order
    /// filtfilt in all but name, consistent with everything else here.
    private static func emaZeroPhase(_ x: [Double], alpha: Double) -> [Double] {
        var y = emaForward(x, alpha: alpha)
        y.reverse()
        y = emaForward(y, alpha: alpha)
        y.reverse()
        return y
    }

    /*
      Constant-velocity Kalman forward pass plus Rauch-Tung-Striebel
      backward smoother, per channel. State is [position, velocity] on the
      uniform grid; Q is the standard white-acceleration form. The RTS
      pass makes it a smoother rather than a filter: zero phase, using the
      whole clip, which is the only Kalman this file would accept. All the
      2 by 2 algebra is written out scalar so there is nothing to allocate
      per sample.
    */
    private static func kalmanRTS(
        _ z: [Double], dt: Double, processNoise q: Double, measurementNoise r: Double
    ) -> [Double] {
        let n = z.count
        guard n > 2, dt > 0 else { return z }

        let q00 = q * dt * dt * dt / 3
        let q01 = q * dt * dt / 2
        let q11 = q * dt

        // Per-step storage for the backward pass.
        var fx0 = [Double](repeating: 0, count: n)   // filtered position
        var fx1 = [Double](repeating: 0, count: n)   // filtered velocity
        var fp00 = [Double](repeating: 0, count: n)  // filtered covariance
        var fp01 = [Double](repeating: 0, count: n)
        var fp10 = [Double](repeating: 0, count: n)
        var fp11 = [Double](repeating: 0, count: n)
        var px0 = [Double](repeating: 0, count: n)   // predicted position
        var px1 = [Double](repeating: 0, count: n)   // predicted velocity
        var pp00 = [Double](repeating: 0, count: n)  // predicted covariance
        var pp01 = [Double](repeating: 0, count: n)
        var pp10 = [Double](repeating: 0, count: n)
        var pp11 = [Double](repeating: 0, count: n)

        // Prior at the first sample: position from the data, velocity
        // unknown, covariance generous so the first measurements dominate.
        var x0 = z[0]
        var x1 = 0.0
        var p00 = r * 10
        var p01 = 0.0
        var p10 = 0.0
        var p11 = 1.0

        for k in 0..<n {
            // Predict (the k = 0 prior stands in for its own prediction).
            let ax0: Double, ax1: Double
            let ap00: Double, ap01: Double, ap10: Double, ap11: Double
            if k == 0 {
                ax0 = x0; ax1 = x1
                ap00 = p00; ap01 = p01; ap10 = p10; ap11 = p11
            } else {
                ax0 = x0 + dt * x1
                ax1 = x1
                ap00 = p00 + dt * (p10 + p01) + dt * dt * p11 + q00
                ap01 = p01 + dt * p11 + q01
                ap10 = p10 + dt * p11 + q01
                ap11 = p11 + q11
            }
            px0[k] = ax0; px1[k] = ax1
            pp00[k] = ap00; pp01[k] = ap01; pp10[k] = ap10; pp11[k] = ap11

            // Update with the measurement (H = [1, 0]).
            let s = ap00 + r
            let k0 = ap00 / s
            let k1 = ap10 / s
            let innovation = z[k] - ax0
            x0 = ax0 + k0 * innovation
            x1 = ax1 + k1 * innovation
            p00 = (1 - k0) * ap00
            p01 = (1 - k0) * ap01
            p10 = ap10 - k1 * ap00
            p11 = ap11 - k1 * ap01

            fx0[k] = x0; fx1[k] = x1
            fp00[k] = p00; fp01[k] = p01; fp10[k] = p10; fp11[k] = p11
        }

        // RTS backward pass, means only (smoothed covariances are unused).
        var out = [Double](repeating: 0, count: n)
        var sx0 = fx0[n - 1]
        var sx1 = fx1[n - 1]
        out[n - 1] = sx0
        for k in stride(from: n - 2, through: 0, by: -1) {
            // A = Pf[k] * F^T, written out for F = [[1, dt], [0, 1]].
            let a00 = fp00[k] + dt * fp01[k]
            let a01 = fp01[k]
            let a10 = fp10[k] + dt * fp11[k]
            let a11 = fp11[k]

            let b00 = pp00[k + 1], b01 = pp01[k + 1]
            let b10 = pp10[k + 1], b11 = pp11[k + 1]
            let det = b00 * b11 - b01 * b10

            let dx0 = sx0 - px0[k + 1]
            let dx1 = sx1 - px1[k + 1]

            if abs(det) > 1e-18 {
                // C = A * inverse(Ppred[k + 1]).
                let c00 = (a00 * b11 - a01 * b10) / det
                let c01 = (-a00 * b01 + a01 * b00) / det
                let c10 = (a10 * b11 - a11 * b10) / det
                let c11 = (-a10 * b01 + a11 * b00) / det
                sx0 = fx0[k] + c00 * dx0 + c01 * dx1
                sx1 = fx1[k] + c10 * dx0 + c11 * dx1
            } else {
                sx0 = fx0[k]
                sx1 = fx1[k]
            }
            out[k] = sx0
        }
        return out
    }

    // MARK: - Adaptive scale (Vector O)

    /*
      Noise estimate wired to Geometry.adaptiveSavitzkyGolay, the estimator
      that was written for this and documented "not yet wired": its output is
      the reference fit whose residual measures how much of the channel is
      jitter, and because its own window already adapts to frame rate and
      local noise, the residual is honest at 30 fps and at 60. The residual
      RMS is normalised by how much the channel actually moves, so the ratio
      is unit free. A jittery track pulls the cutoff down toward the floor; a
      clean track keeps it at 1.
    */
    private func adaptiveScale(x: [Double], y: [Double], times: [Double]) -> Double {
        func noiseRatio(_ channel: [Double]) -> Double {
            let fitted = Geometry.adaptiveSavitzkyGolay(channel, times: times)
            guard fitted.count == channel.count, channel.count > 4 else { return 0 }
            var residual = 0.0
            var motion = 0.0
            for i in 0..<channel.count {
                let r = channel[i] - fitted[i]
                residual += r * r
                if i > 0 {
                    let d = channel[i] - channel[i - 1]
                    motion += d * d
                }
            }
            let rmsResidual = (residual / Double(channel.count)).squareRoot()
            let rmsMotion = (motion / Double(channel.count - 1)).squareRoot()
            guard rmsMotion > 1e-9 else { return 0 }
            return rmsResidual / rmsMotion
        }
        let ratio = max(noiseRatio(x), noiseRatio(y))
        // ratio around 0.3 is a clean pose track; around 1 and above the
        // residual rivals the motion and the channel is mostly jitter.
        let scale = 1.15 - 0.5 * ratio
        return min(1.0, max(config.adaptiveFloor, scale))
    }

    // MARK: - Filtering

    /*
      Scheduled smoothing for one channel: two zero-phase banks at the band's
      ends, crossfaded per sample by the schedule, then the Vector T
      visibility crossfade toward a heavier bank. Three filtfilt runs per
      channel; the whole clip is still tens of milliseconds of CPU math.
    */
    private func smoothScheduled(
        _ channel: [Double], lowHz: Double, highHz: Double,
        weights: [Double], fs: Double, visibility: [Double]
    ) -> [Double] {
        let lowBank = filtfilt(channel, cutoffHz: lowHz, fs: fs)
        let highBank = filtfilt(channel, cutoffHz: highHz, fs: fs)
        let n = channel.count
        var light = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let s = i < weights.count ? weights[i] : (weights.last ?? 0.5)
            light[i] = (1 - s) * lowBank[i] + s * highBank[i]
        }

        guard config.visibilityWeighting, visibility.contains(where: { $0.isFinite }) else {
            return light
        }
        // Vector T: blend toward a heavier filter where the tracker admitted
        // it could not see. Every input is zero phase, so so is the blend.
        let heavy = filtfilt(channel, cutoffHz: lowHz * config.heavyRatio, fs: fs)
        return visibilityBlend(light: light, heavy: heavy, visibility: visibility)
    }

    private func smooth(_ channel: [Double], cutoffHz: Double, fs: Double, visibility: [Double]) -> [Double] {
        let light = filtfilt(channel, cutoffHz: cutoffHz, fs: fs)
        guard config.visibilityWeighting, visibility.contains(where: { $0.isFinite }) else {
            return light
        }
        let heavy = filtfilt(channel, cutoffHz: cutoffHz * config.heavyRatio, fs: fs)
        return visibilityBlend(light: light, heavy: heavy, visibility: visibility)
    }

    private func visibilityBlend(light: [Double], heavy: [Double], visibility: [Double]) -> [Double] {
        let lo = config.visibilityBlendRange.lowerBound
        let hi = config.visibilityBlendRange.upperBound
        var out = [Double](repeating: 0, count: light.count)
        for i in 0..<light.count {
            let v = i < visibility.count ? visibility[i] : .nan
            let w: Double
            if v.isFinite {
                w = min(1, max(0, (v - lo) / max(hi - lo, 1e-9)))
            } else {
                w = 1  // unknown trust reads as trusted, the house convention
            }
            out[i] = w * light[i] + (1 - w) * heavy[i]
        }
        return out
    }

    /*
      Forward-backward second-order Butterworth low pass with reflected edge
      padding, so the filter is warmed up before it ever touches a real sample
      and the clip's ends do not sag toward zero.

      Public and static since the overhaul (Fix 6): the club head path
      smoother below, and any overlay code with a buffered trajectory in
      hand, applies exactly this filter, and duplicating a filter is how two
      halves of a pipeline drift apart.
    */
    public static func zeroPhaseLowPass(_ x: [Double], cutoffHz: Double, fs: Double) -> [Double] {
        let n = x.count
        guard n > 8 else { return x }

        let biquad = Biquad(lowpassCutoffHz: cutoffHz, sampleHz: fs)

        let pad = min(n - 1, max(12, Int((fs / max(cutoffHz, 0.5)).rounded())))
        var extended: [Double] = []
        extended.reserveCapacity(n + 2 * pad)
        for i in stride(from: pad, through: 1, by: -1) { extended.append(2 * x[0] - x[i]) }
        extended.append(contentsOf: x)
        let last = n - 1
        for i in 1...pad { extended.append(2 * x[last] - x[last - i]) }

        var forward = biquad.filter(extended)
        forward.reverse()
        var backward = biquad.filter(forward)
        backward.reverse()
        return Array(backward[pad..<(pad + n)])
    }

    /// The instance spelling every call site in this class already uses.
    private func filtfilt(_ x: [Double], cutoffHz: Double, fs: Double) -> [Double] {
        Self.zeroPhaseLowPass(x, cutoffHz: cutoffHz, fs: fs)
    }

    /// One second-order low-pass section, bilinear transform coefficients,
    /// Butterworth Q. State initialised at the first sample so the (already
    /// padded) start does not ring.
    private struct Biquad {
        let b0: Double, b1: Double, b2: Double
        let a1: Double, a2: Double

        init(lowpassCutoffHz fc: Double, sampleHz fs: Double) {
            // Keep the cutoff meaningfully inside Nyquist.
            let f = min(max(fc, 0.01), fs * 0.45)
            let w = tan(.pi * f / fs)
            let k1 = 2.0.squareRoot() * w
            let k2 = w * w
            let a0 = 1 + k1 + k2
            b0 = k2 / a0
            b1 = 2 * k2 / a0
            b2 = k2 / a0
            a1 = 2 * (k2 - 1) / a0
            a2 = (1 - k1 + k2) / a0
        }

        func filter(_ x: [Double]) -> [Double] {
            var y = [Double](repeating: 0, count: x.count)
            var x1 = x.first ?? 0, x2 = x1, y1 = x1, y2 = x1
            for i in 0..<x.count {
                let xi = x[i]
                let yi = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                y[i] = yi
                x2 = x1; x1 = xi
                y2 = y1; y1 = yi
            }
            return y
        }
    }
}

// MARK: - Occlusion-window RTS smoother (Fix 2)

/*
  See the header note for what this is and why. Mechanics worth recording:

  WINDOWS. A window is a run of at least minRunLength consecutive frames
  where the joint's visibility is finite and under the occlusion floor.
  Runs closer together than the pad are merged, then each window is padded
  on both sides so the filter enters and leaves through honestly seen
  samples. On the Vision backend visibility is NaN, NaN reads as trusted
  (the house convention), and the smoother is inert, which is honest.

  TRUST AS MEASUREMENT NOISE. The Kalman's per-sample measurement variance
  is the base value inflated by how far under the floor the visibility sat:
  a sample at the floor keeps the base R and still steers the filter, a
  sample at zero visibility carries R hundreds of times larger and barely
  tugs it. This is the principled version of "ignore the teleports": the
  tracker itself said how much each sample deserves to be believed, and the
  filter simply takes it at its word.

  WHY BEFORE THE BUTTERWORTH. A teleport is broadband; a low pass run over
  one smears it into the neighbouring honest samples. Running the window
  smoother first hands the Butterworth a track whose occluded stretch is
  already a plausible trajectory, so the scheduled smoothing then does what
  it was tuned for. UploadProcessor calls this between cleanup (plus crop
  refinement) and the scheduled smoothing for exactly that reason.

  Corrections are counted in TrackingQC (occlusionWindowsSmoothed,
  occlusionFramesSmoothed), because a pipeline that corrects data quietly
  is a pipeline that lies.
*/
public final class OcclusionRTSSmoother {

    public struct Config {
        /// Below this (finite) visibility a sample counts as occluded, the
        /// brief's 0.3.
        public var visibilityFloor: Double = 0.3
        /// Shorter dips than this are single-sample flickers the cleanup
        /// and the Butterworth already handle.
        public var minRunLength: Int = 2
        /// Honest-context frames on each side of a window: filter warm-up,
        /// RTS anchor, and the crossfade ramp all live here.
        public var pad: Int = 5
        /// White-acceleration process noise per space. The norm figure
        /// follows the FinalPassConfig guidance for normalised channels;
        /// the world figure allows the several g of acceleration a hand
        /// actually pulls mid downswing, so the model never fights a real
        /// swing, only the noise around it.
        public var processNoiseNorm: Double = 50
        public var processNoiseWorld: Double = 300
        /// Base measurement variance per space (a couple of millipixels of
        /// jitter at typical framing, about 1.5 cm in metres).
        public var measurementNoiseNorm: Double = 1e-5
        public var measurementNoiseWorld: Double = 2.5e-4
        /// R inflation factor at zero visibility. Quadratic ramp from the
        /// floor down, so trust falls away smoothly rather than stepping.
        public var occludedNoiseBoost: Double = 400

        public init() {}

        /*
          View factory (round four, R6a). Face-on hand crossings create
          occlusion windows in the MIDDLE of the downswing, so this
          smoother is active at the fastest instant of the clip, and the
          default process noise, tuned for reconstructing the DTL's long
          quiet holds, pulls the reconstructed wrist toward where it WILL
          be: a zero-phase backward pass blends the future in, which is
          the audited "projects forward into future frames". 80/500 lets
          the model carry the several g a hand really pulls there, so the
          window tracks instead of coasting; the ceiling is the point
          where reconstructed windows would re-inherit the teleports the
          smoother exists to remove. DTL and nil keep 50/300 exactly: DTL
          occlusion windows are long holds where reconstruction, not
          tracking, is the job. Measurement noise and the occluded boost
          are deliberately untouched; the trust ramp is what shapes the
          window, and it keeps doing so.

          Internal because SwingView itself is declared internal
          (MediaPipePoseProvider.swift).
        */
        static func forView(_ view: SwingView?) -> Config {
            var config = Config()
            if view == .faceOn {
                config.processNoiseNorm = 80
                config.processNoiseWorld = 500
            }
            return config
        }
    }

    private let config: Config

    public init(config: Config = Config()) {
        self.config = config
    }

    public func run(_ timeline: inout PoseTimeline, qc: inout TrackingQC) {
        let fs = timeline.gridHz
        let n = timeline.frameCount
        guard fs > 0, n > 8 else { return }
        let dt = 1 / fs

        var framesTouched = Set<Int>()
        var windows = 0

        for space in [PoseSpace.norm, PoseSpace.world] {
            var bank = timeline.channels(space)
            let q = space == .norm ? config.processNoiseNorm : config.processNoiseWorld
            let rBase = space == .norm ? config.measurementNoiseNorm : config.measurementNoiseWorld

            for joint in 0..<timeline.jointCount {
                // Same rule as the main smoothing: a joint with remaining
                // NaN was never measured and is not filtered.
                guard bank.x[joint].allSatisfy({ $0.isFinite }) else { continue }

                let vis = bank.visibility[joint]
                let occluded: [Bool] = (0..<n).map { i in
                    vis[i].isFinite && vis[i] < config.visibilityFloor
                }
                let ranges = Self.paddedWindows(
                    occluded: occluded, minRun: config.minRunLength,
                    pad: config.pad, count: n
                )
                guard !ranges.isEmpty else { continue }

                // Per-sample measurement variance from this joint's own
                // reported trust, shared by x, y and z.
                var r = [Double](repeating: rBase, count: n)
                for i in 0..<n where occluded[i] {
                    let v = vis[i].isFinite ? Swift.max(vis[i], 0) : 0
                    let t = 1 - Geometry.clamp(v / config.visibilityFloor, 0, 1)
                    r[i] = rBase * (1 + config.occludedNoiseBoost * t * t)
                }

                for range in ranges {
                    windows += 1
                    for i in range where occluded[i] { framesTouched.insert(i) }

                    let ramp = Self.crossfade(range: range, occluded: occluded, pad: config.pad)
                    Self.smoothWindow(&bank.x[joint], range: range, dt: dt, q: q, r: r, ramp: ramp)
                    Self.smoothWindow(&bank.y[joint], range: range, dt: dt, q: q, r: r, ramp: ramp)
                    if bank.z[joint].allSatisfy({ $0.isFinite }) {
                        Self.smoothWindow(&bank.z[joint], range: range, dt: dt, q: q, r: r, ramp: ramp)
                    }
                }
            }
            timeline.setChannels(space, bank)
        }

        // Windows are counted across joints and spaces (each is a run the
        // smoother actually processed); frames are unique grid frames, so
        // the two numbers answer different questions on purpose.
        qc.occlusionWindowsSmoothed += windows
        qc.occlusionFramesSmoothed += framesTouched.count
    }

    /// Occlusion runs of at least minRun, padded by pad frames each side,
    /// merged where the padded spans touch.
    private static func paddedWindows(occluded: [Bool], minRun: Int, pad: Int, count: Int) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        var start: Int? = nil
        for i in 0...count {
            if i < count, occluded[i] {
                if start == nil { start = i }
            } else if let s = start {
                if i - s >= minRun { runs.append(s...(i - 1)) }
                start = nil
            }
        }
        guard !runs.isEmpty else { return [] }

        var padded: [ClosedRange<Int>] = []
        for run in runs {
            let lo = Swift.max(0, run.lowerBound - pad)
            let hi = Swift.min(count - 1, run.upperBound + pad)
            if let last = padded.last, lo <= last.upperBound + 1 {
                padded[padded.count - 1] = last.lowerBound...Swift.max(last.upperBound, hi)
            } else {
                padded.append(lo...hi)
            }
        }
        // A window needs enough samples for the filter to mean anything.
        return padded.filter { $0.count > 4 }
    }

    /// Blend-in weight across a window: 0 at the padded edges, ramping to 1
    /// at the occluded core, 1 throughout the core. The smoothed and the
    /// original samples inside the pads differ only by the filter's own
    /// small correction, so the ramp cannot manufacture a step.
    private static func crossfade(range: ClosedRange<Int>, occluded: [Bool], pad: Int) -> [Double] {
        let m = range.count
        var w = [Double](repeating: 1, count: m)
        guard pad > 0 else { return w }
        let denom = Double(pad + 1)
        for (k, i) in range.enumerated() {
            if occluded[i] { continue }
            // Distance to the nearest occluded frame inside this window,
            // capped at the pad, mapped to a linear ramp.
            var d = pad + 1
            var j = i - 1
            while j >= range.lowerBound, i - j <= pad { if occluded[j] { d = Swift.min(d, i - j); break }; j -= 1 }
            j = i + 1
            while j <= range.upperBound, j - i <= pad { if occluded[j] { d = Swift.min(d, j - i); break }; j += 1 }
            w[k] = Geometry.clamp(1 - Double(d) / denom, 0, 1)
        }
        return w
    }

    /*
      One channel through one window: constant-velocity Kalman forward with
      per-sample measurement variance, RTS backward, blended in by the ramp.
      The algebra mirrors TemporalSmoothingService.kalmanRTS; the difference
      that earns the second implementation is the time-varying R, which is
      the entire mechanism here.
    */
    private static func smoothWindow(
        _ channel: inout [Double], range: ClosedRange<Int>,
        dt: Double, q: Double, r: [Double], ramp: [Double]
    ) {
        let z = Array(channel[range])
        let rw = Array(r[range])
        let n = z.count
        guard n > 2, dt > 0 else { return }

        let q00 = q * dt * dt * dt / 3
        let q01 = q * dt * dt / 2
        let q11 = q * dt

        var fx0 = [Double](repeating: 0, count: n)
        var fx1 = [Double](repeating: 0, count: n)
        var fp00 = [Double](repeating: 0, count: n)
        var fp01 = [Double](repeating: 0, count: n)
        var fp10 = [Double](repeating: 0, count: n)
        var fp11 = [Double](repeating: 0, count: n)
        var px0 = [Double](repeating: 0, count: n)
        var px1 = [Double](repeating: 0, count: n)
        var pp00 = [Double](repeating: 0, count: n)
        var pp01 = [Double](repeating: 0, count: n)
        var pp10 = [Double](repeating: 0, count: n)
        var pp11 = [Double](repeating: 0, count: n)

        var x0 = z[0]
        var x1 = 0.0
        var p00 = rw[0] * 10
        var p01 = 0.0
        var p10 = 0.0
        var p11 = 1.0

        for k in 0..<n {
            let ax0: Double, ax1: Double
            let ap00: Double, ap01: Double, ap10: Double, ap11: Double
            if k == 0 {
                ax0 = x0; ax1 = x1
                ap00 = p00; ap01 = p01; ap10 = p10; ap11 = p11
            } else {
                ax0 = x0 + dt * x1
                ax1 = x1
                ap00 = p00 + dt * (p10 + p01) + dt * dt * p11 + q00
                ap01 = p01 + dt * p11 + q01
                ap10 = p10 + dt * p11 + q01
                ap11 = p11 + q11
            }
            px0[k] = ax0; px1[k] = ax1
            pp00[k] = ap00; pp01[k] = ap01; pp10[k] = ap10; pp11[k] = ap11

            // Update with THIS sample's own variance: the time-varying R.
            let s = ap00 + rw[k]
            let k0 = ap00 / s
            let k1 = ap10 / s
            let innovation = z[k] - ax0
            x0 = ax0 + k0 * innovation
            x1 = ax1 + k1 * innovation
            p00 = (1 - k0) * ap00
            p01 = (1 - k0) * ap01
            p10 = ap10 - k1 * ap00
            p11 = ap11 - k1 * ap01

            fx0[k] = x0; fx1[k] = x1
            fp00[k] = p00; fp01[k] = p01; fp10[k] = p10; fp11[k] = p11
        }

        var smoothed = [Double](repeating: 0, count: n)
        var sx0 = fx0[n - 1]
        var sx1 = fx1[n - 1]
        smoothed[n - 1] = sx0
        for k in stride(from: n - 2, through: 0, by: -1) {
            let a00 = fp00[k] + dt * fp01[k]
            let a01 = fp01[k]
            let a10 = fp10[k] + dt * fp11[k]
            let a11 = fp11[k]

            let b00 = pp00[k + 1], b01 = pp01[k + 1]
            let b10 = pp10[k + 1], b11 = pp11[k + 1]
            let det = b00 * b11 - b01 * b10

            let dx0 = sx0 - px0[k + 1]
            let dx1 = sx1 - px1[k + 1]

            if abs(det) > 1e-18 {
                let c00 = (a00 * b11 - a01 * b10) / det
                let c01 = (-a00 * b01 + a01 * b00) / det
                let c10 = (a10 * b11 - a11 * b10) / det
                let c11 = (-a10 * b01 + a11 * b00) / det
                sx0 = fx0[k] + c00 * dx0 + c01 * dx1
                sx1 = fx1[k] + c10 * dx0 + c11 * dx1
            } else {
                sx0 = fx0[k]
                sx1 = fx1[k]
            }
            smoothed[k] = sx0
        }

        for (k, i) in range.enumerated() {
            let w = k < ramp.count ? ramp[k] : 1
            channel[i] = w * smoothed[k] + (1 - w) * channel[i]
        }
    }
}

// MARK: - Club head path smoothing (Fix 6)

/*
  The one-call API for the club head trajectory, which lives in overlay
  code (TrackingLayers) rather than on the timeline. See the header note.

  Piecewise on purpose: a club head track has honest gaps (motion blur, the
  head leaving frame at the top), and running one filter across a gap would
  invent a path through it. Each finite run long enough to filter (the same
  eight-sample floor zeroPhaseLowPass itself enforces) is smoothed on its
  own; shorter runs and the gaps pass through untouched.

  8 Hz default: the club head is the fastest track in the scene and lives
  at the top of the wrist band, but its detections are also the noisiest,
  so it takes the wrist band's midpoint rather than its 15 Hz ceiling.
  Overlay code that disagrees passes its own cutoff.

  INTEGRATION (TrackingLayers, one line where the club head polyline is
  assembled, before it is drawn):

      let smoothed = ClubHeadPathSmoother.smooth(
          points: clubHeadPoints, gridHz: 60
      )
*/
public enum ClubHeadPathSmoother {

    /// Optional-point spelling for overlay code holding [CGPoint?] with nil
    /// gaps. Gaps survive as nil; only finite runs are smoothed.
    public static func smooth(
        points: [CGPoint?], gridHz: Double, cutoffHz: Double = 8
    ) -> [CGPoint?] {
        var x = points.map { $0.map { Double($0.x) } ?? Double.nan }
        var y = points.map { $0.map { Double($0.y) } ?? Double.nan }
        smoothChannels(x: &x, y: &y, gridHz: gridHz, cutoffHz: cutoffHz)
        return (0..<points.count).map { i in
            guard x[i].isFinite, y[i].isFinite else { return nil }
            return CGPoint(x: x[i], y: y[i])
        }
    }

    /// Channel spelling, NaN marking the gaps, for callers already holding
    /// parallel arrays.
    public static func smooth(
        x: [Double], y: [Double], gridHz: Double, cutoffHz: Double = 8
    ) -> (x: [Double], y: [Double]) {
        var sx = x, sy = y
        smoothChannels(x: &sx, y: &sy, gridHz: gridHz, cutoffHz: cutoffHz)
        return (sx, sy)
    }

    private static func smoothChannels(
        x: inout [Double], y: inout [Double], gridHz: Double, cutoffHz: Double
    ) {
        let n = Swift.min(x.count, y.count)
        guard n > 8, gridHz > 0, cutoffHz > 0 else { return }

        // A sample is present only when BOTH channels are, so the two
        // channels agree about the gaps.
        var i = 0
        while i < n {
            guard x[i].isFinite, y[i].isFinite else { i += 1; continue }
            var j = i
            while j + 1 < n, x[j + 1].isFinite, y[j + 1].isFinite { j += 1 }
            let run = i...j
            if run.count > 8 {
                let rx = TemporalSmoothingService.zeroPhaseLowPass(Array(x[run]), cutoffHz: cutoffHz, fs: gridHz)
                let ry = TemporalSmoothingService.zeroPhaseLowPass(Array(y[run]), cutoffHz: cutoffHz, fs: gridHz)
                for (k, idx) in run.enumerated() {
                    x[idx] = rx[k]
                    y[idx] = ry[k]
                }
            }
            i = j + 1
        }
    }
}
