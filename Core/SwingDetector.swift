//
//  SwingDetector.swift
//  Swingline
//
//  Live swing detection, ported from src/engine/swingDetector.js
//  (createSwingDetector, the live state machine, lines 1 to ~180 of the web
//  source). This is the detection half only. It decides that a swing happened.
//  It does not cut a clip and it does not score anything.
//
//  The camera watches continuously. Nobody presses record, runs to the ball,
//  swings, runs back and presses stop. This machine watches lead hand speed
//  frame by frame and decides when a real swing has occurred.
//
//  A bug worth carrying the shape of, from the web source. The first version
//  disarmed the moment hand speed rose above the quiet threshold unless it also
//  cleared the trigger threshold in that same frame. A takeaway accelerates
//  through quiet long before it reaches trigger, so the detector disarmed
//  itself at the very start of every backswing and was back at idle by the time
//  the hands reached full speed. It never fired. The fix, kept here, separates
//  being ready (armed) from being still (quiet). Once armed it stays armed
//  through the slow part of the swing, and only gives up if somebody moves
//  continuously for several seconds without ever swinging, which is what
//  walking away actually looks like.
//
//  When a swing completes, onSwing is called. That is the seam the analysis
//  chain (Biomechanics -> Phases -> Scoring -> Diagnosis, roadmap step 1b) will
//  hang off later. For now the hook just lets the UI flash and the count tick.
//
//  House rule: no em dashes anywhere.
//

import Foundation

@MainActor
final class SwingDetector: ObservableObject {

    // The phases the record screen reacts to. The web machine has an internal
    // settling stage between swinging and done, kept below because it is what
    // confirms a swing is genuinely over rather than paused. For the UI,
    // settling reads as still swinging (the red STOP state), so the screen does
    // not need to tell them apart. This is a deliberate keep of the web logic,
    // flagged rather than dropped, because collapsing settling into swinging
    // would remove the check that a swing has actually finished.
    enum Phase: Equatable {
        case idle       // Waiting for the hands to settle. Shows WAIT.
        case armed      // A real address was held, now watching for a swing.
        case swinging   // The trigger was crossed.
        case settling   // Speed dropped, confirming the swing is over.
        case captured   // A swing just completed. A brief flash, then idle.

        // Whether this phase should read as an active swing in the UI: the red
        // STOP state with a running timer.
        var isActive: Bool {
            self == .armed || self == .swinging || self == .settling
        }
    }

    // Tunables, mirrored one for one from createSwingDetector's defaults in the
    // web source. The lowered trigger speed is deliberate there: pose
    // estimation on a phone is noisy and the cost of the two errors is not
    // symmetric. A missed swing is a golfer at the range wondering why nothing
    // happened. A false trigger is one junk entry they delete in a tap.
    struct Config {
        var triggerSpeed: Double = 1.7     // m/s of lead hand travel to fire.
        var quietSpeed: Double = 0.4       // below this the hands count as still.
        var addressMs: Double = 400        // stillness before a swing can count.
        var settleMs: Double = 650         // stillness again before it is over.
        var armExpiryMs: Double = 6000     // continuous motion this long = walking.
        var maxClipMs: Double = 6000       // runaway guard while swinging.
        var capturedFlashMs: Double = 900  // how long the captured flash holds.
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var peakSpeed: Double = 0
    @Published private(set) var swingCount: Int = 0

    // Called on the main actor the instant a swing is confirmed complete,
    // carrying the peak hand speed seen during it. The clip and scoring bridge
    // (roadmap step 1b) attaches here later. Detection does not know or care
    // what happens next.
    var onSwing: ((_ peakSpeed: Double) -> Void)?

    private let cfg: Config

    // All timing below is in frame timestamp milliseconds, the same clock
    // CaptureViewModel already stamps every frame with. Nothing here reads the
    // wall clock, so playback of recorded frames would drive it identically.
    private var quietSince: Double?
    private var movingSince: Double?
    private var motionStart: Double?
    private var swingStart: Double?
    private var settleSince: Double?
    private var capturedAt: Double?

    init(config: Config = Config()) {
        self.cfg = config
    }

    // Drop everything back to waiting. Used both for a clean restart and for the
    // runaway abort, where no swing actually happened so the count is untouched.
    func reset() {
        phase = .idle
        peakSpeed = 0
        quietSince = nil
        movingSince = nil
        motionStart = nil
        swingStart = nil
        settleSince = nil
        capturedAt = nil
    }

    // Feed one frame. speed is instantaneous lead hand speed in m/s, already
    // computed by CaptureViewModel. t is that frame's timestamp in ms.
    //
    // The speed is deliberately unsmoothed: this is a trigger, not a
    // measurement, and latency matters more than precision, exactly as the web
    // source notes.
    func push(speed: Double, t: Double) {
        let quiet = speed < cfg.quietSpeed

        switch phase {
        case .idle:
            if quiet {
                if quietSince == nil { quietSince = t }
                if let since = quietSince, t - since >= cfg.addressMs {
                    phase = .armed
                    movingSince = nil
                    motionStart = nil
                }
            } else {
                quietSince = nil
            }

        case .armed:
            if speed >= cfg.triggerSpeed {
                // The clip should start where the takeaway started, not where
                // the hands finally got fast, which is already halfway down.
                phase = .swinging
                swingStart = motionStart ?? t
                peakSpeed = speed
            } else if quiet {
                // Still at address. Staying armed is the whole point.
                movingSince = nil
                motionStart = nil
            } else {
                if movingSince == nil {
                    movingSince = t
                    motionStart = t
                }
                // Moving a long time without ever swinging means the golfer
                // walked off, or somebody else wandered into frame.
                if let since = movingSince, t - since >= cfg.armExpiryMs {
                    phase = .idle
                    quietSince = nil
                    movingSince = nil
                    motionStart = nil
                }
            }

        case .swinging:
            peakSpeed = max(peakSpeed, speed)
            if quiet {
                phase = .settling
                settleSince = t
            } else if let start = swingStart, t - start > cfg.maxClipMs + 2000 {
                // Something is moving continuously and it is not a golf swing.
                reset()
            }

        case .settling:
            peakSpeed = max(peakSpeed, speed)
            if speed >= cfg.triggerSpeed {
                // Not over after all, the hands sped back up.
                phase = .swinging
                settleSince = nil
            } else if let since = settleSince, t - since >= cfg.settleMs {
                let captured = peakSpeed
                swingCount += 1
                phase = .captured
                capturedAt = t
                onSwing?(captured)
            }

        case .captured:
            // Hold the flash briefly, then fall back to waiting. Clearing the
            // timers here means the next address is timed fresh from this point.
            if let since = capturedAt, t - since >= cfg.capturedFlashMs {
                reset()
            }
        }
    }
}
