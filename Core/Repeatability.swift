import Foundation

/*
  Repeatability.

  The one number this app can put at the top of a screen and defend.

  The reasoning is short. Measurement error splits into bias and noise. Bias is
  the part that repeats: if the tracker places the pelvis four centimetres too
  high, it places it four centimetres too high on every swing filmed from the
  same spot in the same session. Take a difference between two swings from that
  session and the bias subtracts out. What survives is mostly the golfer
  actually moving differently.

  So the absolute numbers are the weak claim and the spread between them is the
  strong one, which is the opposite of how swing apps normally present
  themselves.

  It also happens to be the thing that matters. A single camera markerless study
  across 27 golfers of mixed ability found that what separated skilled from
  unskilled was the stability and reproducibility of forward tilt between
  trials, not its value. Meanwhile club trajectory shape, the thing golfers
  argue about most, turned out to be an individual characteristic rather than a
  proficiency marker. Consistency is skill. Shape is personal.

  WHERE THIS IS VALID, and it is not everywhere.

  Within a session, from one camera position, this is sound. Across sessions it
  is only sound if the setup matched, because moving the camera changes the bias
  and a changed bias looks exactly like a changed swing. So cross session
  comparison is gated on a setup fingerprint and refuses rather than guesses.

  Translated from packages/core/src/repeatability.ts.
*/

public enum Repeatability {

    private struct Track {
        let key: String
        let label: String
        let get: (RepeatabilitySwingLike) -> Double?
        let good: Double
        let poor: Double
        let note: String
    }

    /*
      What gets measured for consistency.

      Deliberately weighted toward timing and posture. Timing is where pose
      estimation is genuinely strong. Posture is measured against the golfer's own
      address frame, so it does not depend on absolute angular accuracy either.

      Rotation in degrees is absent on purpose. It is the least trustworthy thing
      the engine produces and its variance would be mostly measurement noise
      wearing a golfer's clothes.
    */
    /*
      THE ANCHORS BELOW ARE NOT CALIBRATED AGAINST REAL GOLFERS.

      good and poor are the coefficients of variation that map to 100 and 0. They
      were reasoned from published tour timing ranges and from what the measurement
      itself can resolve, not fitted to a dataset, because no dataset of this app's
      own measurements exists yet.

      That makes the ranking trustworthy and the absolute number provisional. A
      golfer who improves will see their score rise, and one golfer will correctly
      rank against another. Whether 72 is genuinely a good score is unknown until
      there are real sessions to calibrate against, and this comment should be
      deleted the day there are.
    */
    private static let TRACKS: [Track] = [
        Track(
            key: "tempoRatio", label: "Tempo ratio",
            get: { $0.phases?.tempoRatio },
            /* Tour players cluster near three to one and hold it swing to swing. This
               is dimensionless, so it needs no normalising for height or build. */
            good: 0.04, poor: 0.18,
            note: "How consistently your backswing and downswing keep the same proportion."
        ),
        Track(
            key: "backswingMs", label: "Backswing length",
            get: { $0.phases?.backswingMs },
            good: 0.04, poor: 0.15,
            note: "Whether you take the club back for the same length of time each swing."
        ),
        Track(
            key: "downswingMs", label: "Downswing length",
            get: { $0.phases?.downswingMs },
            good: 0.05, poor: 0.18,
            note: "The quarter second that decides the strike, and whether it repeats."
        ),
        Track(
            key: "headSway", label: "Head position",
            get: { $0.fundamentals?.headSway },
            good: 0.15, poor: 0.50,
            note: "Whether your head finishes in the same place relative to the ball."
        ),
        Track(
            key: "finishHoldMs", label: "Finish",
            get: { $0.fundamentals?.finishHoldMs },
            good: 0.20, poor: 0.60,
            note: "Whether you arrive in the same balanced position each time."
        ),
    ]

    /* At least this many swings before a spread means anything. Two swings give a
       range, not a distribution, and a number built on two swings would move
       wildly and look like feedback. */
    public static let MIN_SWINGS = 3

    private static func mean(_ xs: [Double]) -> Double {
        xs.reduce(0, +) / Double(xs.count)
    }

    private static func stdev(_ xs: [Double]) -> Double {
        if xs.count < 2 { return 0 }
        let m = mean(xs)
        return (xs.reduce(0.0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count - 1)).squareRoot()
    }

    /*
      Coefficient of variation, spread as a fraction of the typical value.

      Used rather than raw standard deviation because these tracks are in different
      units and a golfer with a slow swing would otherwise look less consistent than
      a fast one purely because their milliseconds are bigger numbers.
    */
    private static func coefficientOfVariation(_ xs: [Double]) -> Double? {
        let m = mean(xs)
        if !m.isFinite || abs(m) < 1e-9 { return nil }
        return stdev(xs) / abs(m)
    }

    /* Map a coefficient of variation onto 0 to 100, where lower spread scores
       higher. Linear between the good and poor anchors, flat outside them. */
    private static func scoreFor(_ cv: Double?, _ good: Double, _ poor: Double) -> Int? {
        guard let cv = cv else { return nil }
        if cv <= good { return 100 }
        if cv >= poor { return 0 }
        return Int((100 * (1 - (cv - good) / (poor - good))).rounded())
    }

    /*
      A fingerprint of how the clip was captured.

      Two sessions are only comparable if the camera was in roughly the same place,
      because bias is what cancels and bias is a property of the camera position.
      Subject fill and camera view are the two things that move the bias most and
      both are already measured.
    */
    public static func captureFingerprint(_ swing: RepeatabilitySwingLike) -> SessionFingerprint {
        /* Written out rather than chained. swing.validity?.fill is a Double
           inside two optionals, and coalescing two of those together leaves
           the compiler to guess which level it is being asked to unwrap. */
        let fill: Double? = {
            guard let validity = swing.validity else { return nil }
            return validity.fill ?? validity.subjectFill
        }()

        return SessionFingerprint(
            view: swing.view?.view ?? .unknown,
            fill: fill.map { ($0 * 20).rounded() / 20 }
        )
    }

    public static func fingerprintsMatch(_ a: SessionFingerprint?, _ b: SessionFingerprint?) -> Bool {
        guard let a = a, let b = b else { return false }
        if a.view != b.view || a.view == .unknown { return false }
        guard let aFill = a.fill, let bFill = b.fill else { return false }
        /* Within a tenth of frame height. Beyond that the golfer is a materially
           different size on screen and the errors no longer subtract out. */
        return abs(aFill - bFill) <= 0.1
    }

    /*
      The score.

      swings should be from one session, newest or oldest order does not matter.
      Returns .failure rather than a number when there is not enough to say,
      because a confident number built on two swings is exactly the kind of
      invented figure this app exists not to produce.
    */
    public static func repeatability(_ swings: [RepeatabilitySwingLike], requireMatchingSetup: Bool = true) -> RepeatabilityResult {
        let scored = swings.filter { $0.analysed != false && $0.phases != nil }

        if scored.count < MIN_SWINGS {
            return .failure(RepeatabilityFailure(
                reason: .notEnoughSwings,
                have: scored.count,
                need: MIN_SWINGS,
                message: "Three swings from one session is the minimum. You have \(scored.count)."
            ))
        }

        /* Setup has to be consistent or the comparison is measuring the camera. */
        if requireMatchingSetup {
            let prints = scored.map { captureFingerprint($0) }
            let base = prints[0]
            let mismatched = prints.filter { !fingerprintsMatch(base, $0) }.count
            if mismatched > 0 {
                return .failure(RepeatabilityFailure(
                    reason: .setupChanged,
                    message: "These swings were not filmed from the same place, so the differences between them include the camera moving. Consistency needs one camera position."
                ))
            }
        }

        var tracks: [RepeatabilityTrack] = []
        for t in TRACKS {
            let values = scored.compactMap { t.get($0) }.filter { $0.isFinite }
            /* A track needs a value on nearly every swing or its spread is describing
               which swings happened to be measurable, not how the golfer moved. */
            if values.count < scored.count - 1 || values.count < MIN_SWINGS { continue }

            let cv = coefficientOfVariation(values)
            guard let score = scoreFor(cv, t.good, t.poor), let cvValue = cv else { continue }

            tracks.append(RepeatabilityTrack(
                key: t.key, label: t.label, note: t.note,
                cv: (cvValue * 1000).rounded() / 1000,
                score: score,
                typical: (mean(values) * 100).rounded() / 100,
                spread: (stdev(values) * 100).rounded() / 100,
                n: values.count
            ))
        }

        if tracks.isEmpty {
            return .failure(RepeatabilityFailure(
                reason: .nothingMeasurable,
                message: "None of these swings produced enough matching measurements to compare."
            ))
        }

        let overall = Int(mean(tracks.map { Double($0.score) }).rounded())
        let ranked = tracks.sorted { $0.score < $1.score }

        return .success(RepeatabilitySuccess(
            overall: overall,
            swings: scored.count,
            tracks: tracks,
            /* Named the way it should be said. The weakest track is the one thing worth
               working on, and the strongest is worth saying out loud because a beginner
               who hears only faults stops coming back. */
            leastConsistent: ranked.first!,
            mostConsistent: ranked.last!,
            band: band(overall)
        ))
    }

    public static func band(_ score: Int) -> RepeatabilityBandInfo {
        if score >= 80 { return RepeatabilityBandInfo(key: "tight", label: "Tight", note: "These swings repeat closely. That is the thing good golfers actually have.") }
        if score >= 60 { return RepeatabilityBandInfo(key: "settling", label: "Settling", note: "A recognisable pattern with some drift in it.") }
        if score >= 35 { return RepeatabilityBandInfo(key: "loose", label: "Loose", note: "The shape is there but it is moving around between swings.") }
        return RepeatabilityBandInfo(key: "searching", label: "Searching", note: "Every swing is a different swing at the moment. That is normal early on, and it is the thing to change first.")
    }

    /*
      Session grouping.

      A session is a run of swings close together in time. Sessions are the unit
      this is valid over, so the caller needs a way to cut a history into them
      without having recorded session boundaries at the time.
    */
    public static let SESSION_GAP_MS = 90.0 * 60 * 1000

    public static func intoSessions(_ swings: [RepeatabilitySwingLike], gapMs: Double = SESSION_GAP_MS) -> [[RepeatabilitySwingLike]] {
        let sorted = swings
            .filter { $0.at != nil }
            .sorted { $0.at! < $1.at! }

        var sessions: [[RepeatabilitySwingLike]] = []
        var current: [RepeatabilitySwingLike] = []

        for s in sorted {
            if current.isEmpty || s.at! - current.last!.at! <= gapMs {
                current.append(s)
            } else {
                sessions.append(current)
                current = [s]
            }
        }
        if !current.isEmpty { sessions.append(current) }
        return sessions
    }
}
