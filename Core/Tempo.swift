import Foundation

/*
  The tempo trainer.

  Straight lift from rhythm games, and it works for the same reason they do:
  a tight, immediate, graded judgement on a single timing window teaches faster
  than any explanation. Hit it, get told exactly how far off you were, go again.

  This needs no computer vision at all. Three timestamps, address, top, impact,
  are the entire input. That means it runs when the camera cannot see you, when
  the light is bad, indoors, at night, without a ball, in a hallway.

  The target is the ratio golf instruction has been built around for decades,
  roughly three to one, backswing to downswing. Tour players cluster tightly
  around it. Beginners are almost always faster going back than they think.

  Translated from packages/core/src/tempo.ts.

  DELIBERATE OMISSION, carried over from the TypeScript port: createMetronome
  and its audio backed click() helper are not translated here. They are a
  platform audio concern, not swing measurement, matching why they were left
  out of tempo.ts's own port from the original tempo.js. An iOS metronome
  should be built against AVFoundation directly, driven by JUDGEMENTS and
  judge() below, in whatever file owns audio playback, not in this one.
*/

public enum Tempo {

    public static let TARGET_RATIO = 3.0

    /*
      Below this tracking rate, a measured tempo ratio is not reported.

      A downswing runs about 250ms. At 12fps that is three samples, so the timing
      of the top and of impact are each uncertain by a whole frame, and the ratio
      built from them carries something like 25 percent error. That is larger than
      the difference between a good tempo and a bad one, which means the number
      would be describing the phone rather than the golfer.

      Tapped tempo, where the golfer marks the top and impact themselves, is not
      gated by this. It does not come from tracking at all.
    */
    public static let MIN_FPS_FOR_TEMPO = 15.0

    public static func tempoMeasurable(_ fps: Double?) -> Bool {
        guard let fps = fps else { return false }
        return fps >= MIN_FPS_FOR_TEMPO
    }

    /* How wrong the ratio could be at a given capture rate, as a fraction. Used to
       decide whether to show a number, a band, or nothing at all. */
    public static func tempoUncertainty(_ fps: Double, downswingMs: Double = 250) -> Double {
        if fps <= 0 { return .infinity }
        let frameMs = 1000 / fps
        return frameMs / downswingMs
    }

    private struct JudgementBand {
        let key: TempoJudgementKey
        let label: String
        let tolerance: Double
        let points: Int
    }

    private static let JUDGEMENTS: [JudgementBand] = [
        JudgementBand(key: .perfect, label: "Perfect", tolerance: 0.12, points: 100),
        JudgementBand(key: .great, label: "Great", tolerance: 0.28, points: 70),
        JudgementBand(key: .good, label: "Good", tolerance: 0.5, points: 40),
        JudgementBand(key: .off, label: "Off", tolerance: .infinity, points: 0),
    ]

    public static func judge(_ backswingMs: Double, _ downswingMs: Double, target: Double = TARGET_RATIO) -> TempoJudgement? {
        if downswingMs <= 0 { return nil }
        let ratio = backswingMs / downswingMs
        let error = ratio - target
        let found = JUDGEMENTS.first { abs(error) <= $0.tolerance } ?? JUDGEMENTS[3]

        return TempoJudgement(
            ratio: ratio,
            error: error,
            /* Named the way a golfer thinks about it, not the way the maths works.
               "Rushed" is what a fast backswing actually feels like. */
            direction: error < 0 ? .rushed : .dragged,
            judgement: found.key,
            label: found.label,
            points: found.points,
            backswingMs: backswingMs,
            downswingMs: downswingMs,
            message: message(found.key, error)
        )
    }

    private static func message(_ key: TempoJudgementKey, _ error: Double) -> String {
        if key == .perfect { return "Right on it. That is the rhythm to remember." }
        if error < 0 {
            return key == .great
                ? "Slightly quick going back. Almost there."
                : "Your backswing is rushing. Take it back slower than feels right."
        }
        return key == .great
            ? "A touch slow coming down. Commit to it."
            : "You are dragging the downswing. Let it go."
    }

    /* A run of good judgements is worth showing, because it is the thing that
       makes somebody take one more swing. */
    public static func streakOf(_ results: [TempoJudgementKey]) -> Int {
        var run = 0
        for r in results {
            if r == .perfect || r == .great { run += 1 }
            else { break }
        }
        return run
    }
}
