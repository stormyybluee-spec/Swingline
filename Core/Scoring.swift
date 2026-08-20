import Foundation

/*
  Scoring.

  Every measurement in this engine collapses into exactly one of four plain
  language categories before it reaches the screen:

    Sequencing   the order things fire in
    Rotation     how much you turn, and how much separation you hold
    Balance      where your weight is, and whether your head stays put
    Finish       whether you finish over your lead leg and stay there

  No biomechanics term ever appears in the interface. X-Factor is a real and
  useful measurement, and it is also a phrase that means nothing to somebody in
  their first year of golf, so it lives in this file and never on a screen.

  Scores use flat topped bands rather than a linear mapping. A beginner
  improves in steps, and a linear score makes a real gain look like nothing,
  which is the fastest way to lose somebody in week two.

  Translated from packages/core/src/scoring.ts.
*/

public enum Scoring {

    public static let CATEGORIES: [CategoryKey] = [.sequencing, .rotation, .balance, .finish]

    public static let CATEGORY_LABELS: [CategoryKey: String] = [
        .sequencing: "Sequencing",
        .rotation: "Rotation",
        .balance: "Balance",
        .finish: "Finish",
    ]

    public static let CATEGORY_BLURBS: [CategoryKey: String] = [
        .sequencing: "The order your body fires in on the way down.",
        .rotation: "How far you turn, and how much of that turn you keep.",
        .balance: "Where your weight sits, and whether your head stays still.",
        .finish: "Whether you end up over your front foot and stay there.",
    ]

    /* Weights reflect what actually holds a beginner back, not what is easiest to
       measure. Sequencing carries the most because a swing that fires in the wrong
       order cannot be fixed by turning further or standing wider. */
    private static let WEIGHTS: [CategoryKey: Double] = [.sequencing: 0.34, .rotation: 0.26, .balance: 0.22, .finish: 0.18]

    private static let SHORT: [SegmentKey: String] = [.pelvis: "hips", .torso: "chest", .arm: "arm", .club: "hands"]

    public static func scoreSwing(
        phases: PhaseResult, sequence: SequenceResult, xf: XFactorResult,
        fundamentals: Fundamentals, measured: MeasuredSet = [:]
    ) -> ScoreResult {
        var metrics: [ScoredMetric] = []

        /*
          A metric that could not be measured is left out of the score entirely
          rather than being scored as though it were zero. Scoring an unmeasurable
          thing as bad is how a golfer filmed down the line ends up being told their
          balance is poor when the camera simply could not see their feet apart.
        */
        func add(_ m: ScoredMetric) {
            var metric = m
            if let gateKey = m.gate, let gate = measured[gateKey], !gate.valid {
                metric.score = nil
                metric.measurable = false
                metric.why = gate.why ?? "out-of-range"
                metrics.append(metric)
                return
            }
            metric.measurable = true
            metrics.append(metric)
        }

        /* ---------- Sequencing ---------- */
        var orderScore = 100
        if !sequence.orderCorrect { orderScore = max(10, 100 - sequence.inversions * 28) }
        add(ScoredMetric(
            id: "sequence-order", category: .sequencing, label: "Firing order",
            plain: "Hips, then chest, then arms, then hands",
            value: Double(sequence.observedOrder.count),
            display: sequence.observedOrder.map { SHORT[$0]! }.joined(separator: " then "),
            score: orderScore, measurable: false
        ))

        let gapScore = Int((Double(sequence.goodGaps) / 3 * 70 + Double(sequence.okGaps) / 3 * 30).rounded())
        let avgGapMs = sequence.gaps.reduce(0.0) { $0 + $1.ms } / 3
        add(ScoredMetric(
            id: "sequence-gaps", category: .sequencing, label: "Handover timing",
            plain: "Each part waits its turn instead of firing together",
            value: avgGapMs, unit: "ms",
            display: "\(Int(avgGapMs.rounded())) ms average",
            score: Int(Geometry.clamp(Double(gapScore), 0, 100)), measurable: false
        ))

        let tempoScore = Geometry.bandScore(phases.tempoRatio, ScoreBands(good: (2.6, 3.4), ok: (2.0, 4.2), hard: (1.4, 5.5)))
        add(ScoredMetric(
            id: "tempo", category: .sequencing, label: "Tempo",
            plain: "Back slow, down fast, roughly three to one",
            value: phases.tempoRatio,
            display: "\(String(format: "%.1f", phases.tempoRatio)) to 1",
            score: tempoScore, measurable: false, gate: "tempo"
        ))

        /* ---------- Rotation ---------- */
        add(ScoredMetric(
            id: "separation-top", category: .rotation, label: "Separation at the top",
            plain: "Chest turned further than hips",
            value: xf.atTop, unit: "deg",
            display: "\(Int(xf.atTop.rounded())) degrees",
            score: Geometry.bandScore(xf.atTop, ScoreBands(good: (38, 58), ok: (26, 68), hard: (12, 82))),
            measurable: false, gate: "separation"
        ))
        add(ScoredMetric(
            id: "separation-stretch", category: .rotation, label: "Stretch into the downswing",
            plain: "Hips start down while the chest is still going back",
            value: xf.stretch, unit: "deg",
            display: xf.stretch > 0 ? "plus \(String(format: "%.1f", xf.stretch)) degrees" : "\(String(format: "%.1f", xf.stretch)) degrees",
            score: Geometry.bandScore(xf.stretch, ScoreBands(good: (2, 12), ok: (0, 18), hard: (-6, 26))),
            measurable: false, gate: "stretch"
        ))
        add(ScoredMetric(
            id: "shoulder-turn", category: .rotation, label: "Shoulder turn",
            plain: "How far your chest turns going back",
            value: xf.shoulderTurn, unit: "deg",
            display: "\(Int(xf.shoulderTurn.rounded())) degrees",
            score: Geometry.bandScore(xf.shoulderTurn, ScoreBands(good: (80, 105), ok: (62, 118), hard: (40, 132))),
            measurable: false, gate: "shoulderTurn"
        ))

        /* ---------- Balance ---------- */
        add(ScoredMetric(
            id: "head-sway", category: .balance, label: "Head movement",
            plain: "Your head stays where it started",
            value: fundamentals.headSway, unit: "cm",
            display: "\(String(format: "%.1f", fundamentals.headSway)) cm",
            score: Geometry.bandScore(fundamentals.headSway, ScoreBands(good: (0, 4), ok: (0, 8), hard: (0, 15))),
            measurable: false, gate: "headSway"
        ))
        add(ScoredMetric(
            id: "pressure-shift", category: .balance, label: "Weight through the ball",
            plain: "Pressure moves toward the target on the way down",
            value: fundamentals.pressureShift,
            display: "\(Int((fundamentals.pressureShift * 100).rounded())) percent of stance",
            score: Geometry.bandScore(fundamentals.pressureShift, ScoreBands(good: (0.28, 0.6), ok: (0.15, 0.75), hard: (0, 0.95))),
            measurable: false, gate: "pressureShift"
        ))
        add(ScoredMetric(
            id: "stance-width", category: .balance, label: "Stance width",
            plain: "Feet about shoulder width apart",
            value: fundamentals.stanceRatio,
            display: "\(String(format: "%.2f", fundamentals.stanceRatio)) times shoulder width",
            score: Geometry.bandScore(fundamentals.stanceRatio, ScoreBands(good: (1.0, 1.35), ok: (0.85, 1.55), hard: (0.6, 1.9))),
            measurable: false
        ))
        add(ScoredMetric(
            id: "posture", category: .balance, label: "Spine angle",
            plain: "You keep the tilt you set up with",
            value: fundamentals.spineDrift, unit: "deg",
            display: "\(String(format: "%.1f", fundamentals.spineDrift)) degrees of drift",
            score: Geometry.bandScore(fundamentals.spineDrift, ScoreBands(good: (0, 6), ok: (0, 12), hard: (0, 22))),
            measurable: false, gate: "spineDrift"
        ))

        /* ---------- Finish ---------- */
        add(ScoredMetric(
            id: "finish-pressure", category: .finish, label: "Weight at the finish",
            plain: "You end up over your front foot",
            value: fundamentals.finishPressure,
            display: "\(Int((fundamentals.finishPressure * 100).rounded())) percent front foot",
            score: Geometry.bandScore(fundamentals.finishPressure, ScoreBands(good: (0.78, 1.0), ok: (0.62, 1.1), hard: (0.4, 1.3))),
            measurable: false, gate: "finishPressure"
        ))
        add(ScoredMetric(
            id: "finish-hold", category: .finish, label: "Held finish",
            plain: "You hold the finish instead of stumbling out of it",
            value: fundamentals.finishHoldMs, unit: "ms",
            display: "\(Int(fundamentals.finishHoldMs.rounded())) ms",
            score: Geometry.bandScore(fundamentals.finishHoldMs, ScoreBands(good: (400, 3000), ok: (220, 4000), hard: (60, 6000))),
            measurable: false
        ))
        add(ScoredMetric(
            id: "takeaway-width", category: .finish, label: "Takeaway",
            plain: "Hands stay low and wide on the way back",
            value: fundamentals.takeawayWidth,
            display: "\(String(format: "%.2f", fundamentals.takeawayWidth)) times shoulder width",
            score: Geometry.bandScore(fundamentals.takeawayWidth, ScoreBands(good: (0.85, 1.5), ok: (0.6, 1.8), hard: (0.3, 2.2))),
            measurable: false
        ))

        var categoryScores: [CategoryKey: Int?] = [:]
        var categoryMeasurable: [CategoryKey: Bool] = [:]
        for c in CATEGORIES {
            let inCat = metrics.filter { $0.category == c && $0.measurable }
            categoryMeasurable[c] = !inCat.isEmpty
            if inCat.isEmpty {
                /* updateValue rather than a subscript assignment. The dictionary
                   value is itself an optional, so `categoryScores[c] = nil` would
                   read as "remove this key" rather than "this category exists and
                   could not be measured", and those are different claims. */
                categoryScores.updateValue(nil, forKey: c)
            } else {
                let sum = inCat.reduce(0) { $0 + ($1.score ?? 0) }
                categoryScores[c] = Int((Double(sum) / Double(inCat.count)).rounded())
            }
        }

        /* The overall score is weighted across whichever categories could actually
           be measured, and the weights are renormalised so a swing missing one
           category is not silently penalised for it. */
        let usable = CATEGORIES.filter { categoryScores[$0] != nil && categoryScores[$0]! != nil }
        let weightSum = usable.reduce(0.0) { $0 + WEIGHTS[$1]! }
        let overall: Int? = usable.isEmpty ? nil : Int(
            (usable.reduce(0.0) { $0 + Double(categoryScores[$1]!!) * WEIGHTS[$1]! } / (weightSum == 0 ? 1 : weightSum)).rounded()
        )

        let weakest: CategoryKey? = usable.isEmpty ? nil : usable.reduce(usable[0]) { a, c in
            categoryScores[c]!! < categoryScores[a]!! ? c : a
        }

        return ScoreResult(
            metrics: metrics, categoryScores: categoryScores, categoryMeasurable: categoryMeasurable,
            overall: overall, weakest: weakest, measuredCategories: usable.count
        )
    }

    /*
      Confidence banded rating.

      A brand new golfer with one recorded swing does not have a form score of 62.
      They have a form score somewhere between about 45 and 79, and the app should
      say so. Presenting false precision on day one is how a scoring system loses
      the golfer's trust the first time a good swing scores badly.

      This is a Glicko style treatment: the rating carries a deviation alongside it.
      The deviation shrinks as swings accumulate, widens again when somebody has not
      recorded for a while, and widens when tracking confidence was poor. Only once
      the deviation is small enough does the interface show a single number.
    */
    private static let RD_START = 24.0
    private static let RD_FLOOR = 3.5
    private static let RD_CEILING = 30.0
    private static let DRIFT_PER_DAY = 0.55

    public static func newRating(seed: Double = 55, now: Double = Date().timeIntervalSince1970 * 1000) -> Rating {
        Rating(rating: seed, rd: RD_START, swings: 0, updatedAt: now)
    }

    public static func updateRating(_ prev: Rating, _ observed: Double, trackingConfidence: Double = 1, at: Double = Date().timeIntervalSince1970 * 1000) -> Rating {
        let days = max(0, (at - (prev.updatedAt == 0 ? at : prev.updatedAt)) / 86400000)
        let rdPre = min(RD_CEILING, (prev.rd * prev.rd + DRIFT_PER_DAY * DRIFT_PER_DAY * days).squareRoot())

        /* A poorly tracked swing is a noisier measurement, so it moves the rating
           less and leaves the band wider. */
        let noise = 12 / max(0.35, trackingConfidence)
        let k = (rdPre * rdPre) / (rdPre * rdPre + noise * noise)

        return Rating(
            rating: Geometry.clamp(prev.rating + k * (observed - prev.rating), 0, 100),
            rd: max(RD_FLOOR, ((1 - k) * rdPre * rdPre).squareRoot()),
            swings: prev.swings + 1,
            updatedAt: at
        )
    }

    public static func ratingBand(_ r: Rating) -> RatingBand {
        let half = 1.96 * r.rd
        return RatingBand(
            low: Int(Geometry.clamp(r.rating - half, 0, 100).rounded()),
            high: Int(Geometry.clamp(r.rating + half, 0, 100).rounded()),
            point: Int(r.rating.rounded()),
            /* Below this width the band is tight enough that a single number is an
               honest summary of it. */
            settled: half < 6
        )
    }

    public static func bandLabel(_ r: Rating) -> String {
        let b = ratingBand(r)
        if b.settled { return "\(b.point)" }
        return "\(b.low) to \(b.high)"
    }
}
