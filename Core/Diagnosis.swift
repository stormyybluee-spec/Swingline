import Foundation

/*
  Diagnosis.

  This is the file that makes the product a diagnostician rather than a
  thermometer. A thermometer hands you a number. A diagnostician names the one
  thing that is wrong and tells you what to do about it tomorrow morning.

  The structure is a prioritised checklist, the same pattern the basketball shot
  analysis literature settled on: extract a structured list of specific faults
  rather than one opaque similarity score. Each check is a small, testable
  statement about the body. The list is walked in priority order, and the first
  fault that fires is the only one promoted to the headline.

  Priority is not the same as severity. A sequencing fault outranks a rotation
  fault even when the rotation number looks worse, because you cannot fix your
  turn while your body is firing in the wrong order. Fixing things in the wrong
  order is how beginners spend a year getting nowhere.

  Translated from packages/core/src/diagnosis.ts.

  TRANSLATION NOTE. The original's CHECKS array has headline and detail fields
  typed as "string OR a function that computes a string from context". Swift
  has no clean equivalent of that union for a stored property. Every headline
  and detail below is a closure, (DiagnosisContext) -> String, with plain
  string cases wrapped through the small lit() helper so the checklist below
  still reads like a list of sentences rather than a list of closures.
*/

public enum Diagnosis {

    private struct Check {
        let id: String
        let category: CategoryKey
        let priority: Int
        let gate: String?
        let test: (DiagnosisContext) -> Bool
        let headline: (DiagnosisContext) -> String
        let detail: (DiagnosisContext) -> String
        let drill: String
    }

    private static func lit(_ s: String) -> (DiagnosisContext) -> String { { _ in s } }

    /* Every check: id, category, the test, the sentence, the drill. */
    private static let CHECKS: [Check] = [
        Check(
            id: "upper-body-first", category: .sequencing, priority: 1, gate: nil,
            test: { $0.sequence.upperBodyFirst },
            headline: lit("Your shoulders started down before your hips did."),
            detail: lit("Your chest reached top speed before your hips reached theirs. That reverses the order power is supposed to travel in, so your arms end up doing work your legs should have done."),
            drill: "step-change"
        ),
        Check(
            id: "all-at-once", category: .sequencing, priority: 2, gate: nil,
            test: { $0.sequence.allAtOnce },
            headline: lit("Everything fired at the same time."),
            detail: lit("Your hips, chest and arms all hit top speed together. The order is not wrong, there is just no handover between them, so nothing gets a chance to build on what came before it."),
            drill: "pump-transition"
        ),
        Check(
            id: "arms-before-chest", category: .sequencing, priority: 3, gate: nil,
            test: { $0.sequence.armsFirst && !$0.sequence.upperBodyFirst },
            headline: lit("Your arms went before your chest did."),
            detail: lit("Your hips led correctly, then your arms jumped ahead of your torso. This usually shows up as a swing that feels fast but comes out short."),
            drill: "pump-transition"
        ),
        Check(
            id: "rushed-backswing", category: .sequencing, priority: 4, gate: "tempo",
            test: { $0.phases.tempoRatio < 2.1 },
            headline: lit("Your backswing is too quick for your downswing."),
            detail: { context in
                "You are swinging at about \(String(format: "%.1f", context.phases.tempoRatio)) to 1. A backswing that rushes leaves you no time to change direction properly, and the change of direction is where the speed actually comes from."
            },
            drill: "tempo-count"
        ),
        Check(
            id: "reverse-pivot", category: .balance, priority: 5, gate: "finishPressure",
            test: { $0.fundamentals.topPressure > 0.58 },
            headline: lit("Your weight went the wrong way at the top."),
            detail: lit("At the top of your backswing your weight was still on your front foot. That is a reverse pivot, and it means you have to fall backwards to make room for the downswing."),
            drill: "reverse-pivot-fix"
        ),
        Check(
            id: "no-weight-shift", category: .balance, priority: 6, gate: "pressureShift",
            test: { $0.fundamentals.pressureShift < 0.14 },
            headline: lit("Your weight stayed put on the way down."),
            detail: lit("Your pressure barely moved toward the target through the downswing. Everything you hit is coming from your arms alone."),
            drill: "pressure-step"
        ),
        Check(
            id: "head-sway", category: .balance, priority: 7, gate: "headSway",
            test: { $0.fundamentals.headSway > 9 },
            headline: lit("Your head slid sideways during the swing."),
            detail: { context in
                "Your head moved about \(Int(context.fundamentals.headSway.rounded())) centimetres off where it started. Every centimetre of that has to be found again before impact, and it usually is not."
            },
            drill: "head-still"
        ),
        Check(
            id: "no-separation", category: .rotation, priority: 8, gate: "separation",
            test: { $0.xf.atTop < 25 },
            headline: lit("Your chest and hips turned as one block."),
            detail: { context in
                "You held about \(Int(context.xf.atTop.rounded())) degrees of separation at the top. There is no stretch to release, so the downswing has nothing stored in it."
            },
            drill: "cross-arm-turn"
        ),
        Check(
            id: "lost-stretch", category: .rotation, priority: 9, gate: "stretch",
            test: { $0.xf.stretch < 0.5 },
            headline: lit("You let go of your turn as soon as you changed direction."),
            detail: lit("Your separation peaked at the top and immediately started shrinking. In a swing that stores power, separation keeps growing for a beat after the downswing has already begun."),
            drill: "pump-transition"
        ),
        Check(
            id: "short-turn", category: .rotation, priority: 10, gate: "shoulderTurn",
            test: { $0.xf.shoulderTurn < 62 },
            headline: lit("Your backswing is short."),
            detail: { context in
                "Your chest turned about \(Int(context.xf.shoulderTurn.rounded())) degrees. Under roughly sixty, there is not enough room left to accelerate into the ball."
            },
            drill: "cross-arm-turn"
        ),
        Check(
            id: "spine-drift", category: .balance, priority: 11, gate: "spineDrift",
            test: { $0.fundamentals.spineDrift > 13 },
            headline: lit("You stood up out of your posture."),
            detail: lit("The angle you set at address changed noticeably during the swing. When your body height changes mid swing, your hands have to make a last moment correction to find the ball."),
            drill: "wall-hip-turn"
        ),
        Check(
            id: "narrow-takeaway", category: .finish, priority: 12, gate: nil,
            test: { $0.fundamentals.takeawayWidth < 0.62 },
            headline: lit("Your hands picked the club up instead of taking it back."),
            detail: lit("Your takeaway was narrow and steep. A wide, low first move gives you a much bigger arc to work with, and arc is free speed."),
            drill: "low-and-slow"
        ),
        Check(
            id: "unbalanced-finish", category: .finish, priority: 13, gate: "finishPressure",
            test: { $0.fundamentals.finishPressure < 0.62 },
            headline: lit("You finished off your front foot."),
            detail: lit("At the end of the swing your weight was still split, or hanging back. A balanced finish over the lead leg is the clearest sign that everything before it happened in the right order."),
            drill: "hold-the-finish"
        ),
        Check(
            id: "falling-finish", category: .finish, priority: 14, gate: nil,
            test: { $0.fundamentals.finishHoldMs < 200 },
            headline: lit("You could not hold your finish."),
            detail: lit("You came out of the finish almost immediately. That is usually a sign of swinging harder than your balance can currently support."),
            drill: "feet-together"
        ),
        Check(
            id: "stance-narrow", category: .balance, priority: 15, gate: nil,
            test: { $0.fundamentals.stanceRatio < 0.82 },
            headline: lit("Your stance is narrower than it should be."),
            detail: lit("A base narrower than your shoulders gives you very little to push against and makes balance harder than it needs to be."),
            drill: "feet-together"
        ),
    ]

    private static let DRILL_FOR_CATEGORY: [CategoryKey: String] = [
        .sequencing: "step-change",
        .rotation: "cross-arm-turn",
        .balance: "feet-together",
        .finish: "hold-the-finish",
    ]

    public static func diagnose(_ context: DiagnosisContext) -> DiagnosisResult {
        let measured = context.measured

        /* A check is only allowed to fire if the measurement behind it is
           trustworthy. Telling a golfer their weight went the wrong way, based on a
           pressure reading the camera angle made impossible, is worse than saying
           nothing. */
        func usable(_ gate: String?) -> Bool {
            guard let gate = gate else { return true }
            guard let m = measured[gate] else { return true }
            return m.valid
        }

        let fired = CHECKS
            .filter { usable($0.gate) && $0.test(context) }
            .sorted { $0.priority < $1.priority }

        guard let weakest = context.scores.weakest else {
            return DiagnosisResult(
                headline: "This one could not be scored reliably.",
                detail: "Too little of the swing could be measured with confidence, so nothing here would be worth acting on.",
                category: nil, drill: nil, faultId: nil,
                faults: [], clean: false, unscored: true
            )
        }

        if fired.isEmpty {
            /* Nothing tripped a fault check. Say something true rather than
               manufacturing a problem, and point at whichever category is still
               furthest behind. */
            return DiagnosisResult(
                headline: "Nothing is obviously broken in this one.",
                detail: "Every check passed. Your weakest area is still \(Scoring.CATEGORY_LABELS[weakest]!.lowercased()), so that is where the next gain is, but this was a clean swing.",
                category: weakest, drill: DRILL_FOR_CATEGORY[weakest],
                faultId: nil, faults: [], clean: true
            )
        }

        /*
          Which fault gets promoted.

          The checklist is walked in priority order, but the headline should also be
          about the category the golfer is actually weakest in, otherwise the sentence
          at the top of the screen and the red bar further down are talking about two
          different things and the golfer has to reconcile them. So: the highest
          priority fault inside the weakest category wins, and only if that category
          happens to be clean does the highest priority fault overall take the slot.
        */
        let inWeakest = fired.filter { $0.category == weakest }
        let primary = inWeakest.first ?? fired[0]

        return DiagnosisResult(
            headline: primary.headline(context),
            detail: primary.detail(context),
            category: primary.category,
            drill: primary.drill,
            faultId: primary.id,
            /* The rest of the checklist stays available behind the full breakdown
               disclosure. It is never promoted to the front of the screen. */
            faults: fired.map { f in
                DiagnosisFaultSummary(id: f.id, category: f.category, headline: f.headline(context), drill: f.drill)
            },
            clean: false
        )
    }

    /*
      Did the prescribed drill actually work.

      This is the loop that makes the whole product accountable to itself. A drill
      is prescribed against one named fault. The next swing recorded after that
      drill is checked against that same fault and nothing else. Not the overall
      score, which moves for a dozen unrelated reasons, just the one thing the
      drill was supposed to fix.
    */
    public static func didDrillWork(_ previousSwing: StoredSwingLike?, _ nextSwing: StoredSwingLike?) -> DrillWorkResult? {
        guard let previousSwing = previousSwing,
              let faultId = previousSwing.diagnosis?.faultId,
              let nextSwing = nextSwing
        else { return nil }

        /*
          Both swings have to carry scores before a delta between them means anything.

          Ported from a JavaScript file where this guard mattered because React runs
          every hook before an early return, so a screen that early-returns on an
          unscored swing had already called this function. Swift's optional chaining
          below achieves the same safety more directly, there is no path through
          this function that reads a field that is not there.
        */
        guard let category = previousSwing.diagnosis?.category,
              let before = previousSwing.scores?.categoryScores?[category],
              let after = nextSwing.scores?.categoryScores?[category]
        else { return nil }

        let stillPresent = (nextSwing.diagnosis?.faults ?? []).contains { $0.id == faultId }

        return DrillWorkResult(
            faultId: faultId,
            category: category,
            cleared: !stillPresent,
            delta: after - before
        )
    }
}
