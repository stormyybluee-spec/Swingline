//
//  Analyze.swift
//  Swingline
//
//  The orchestrator. Ported from src/engine/analyze.js (analyseSwing), plus the
//  two helpers it leans on that had not been ported yet: cameraView and
//  withinBounds from src/engine/validity.js, and measureFundamentals from
//  analyze.js itself.
//
//  Frames go in. One assessed result comes out: validity, phases, the four
//  category scores, one headline sentence, and everything CaptureViewModel
//  needs to build a storable SwingRecord. Nothing here reaches the network. It
//  is pure over value types, so it runs off the main actor without ceremony.
//
//  Why this is its own file and not a method on CaptureViewModel. The web build
//  keeps the orchestrator as its own module for the same reason it is worth
//  keeping here: it is the one place the whole pipeline is wired in order, it is
//  the thing most worth reading on its own, and it has no business knowing about
//  a camera session or a SwiftUI view. CaptureViewModel calls analyseSwing and
//  turns the result into a record. That is the whole seam.
//
//  A gap worth naming. The Swift port had assessClip, buildSeries, segment,
//  analyseSequence, analyseXFactor, scoreSwing and diagnose, but not cameraView,
//  not withinBounds, and not measureFundamentals. scoreSwing and diagnose both
//  require a Fundamentals and a gated MeasuredSet as input, so those three had
//  to be ported here before the pipeline could be assembled at all. They are
//  translated straight from the web source rather than reinvented, so the two
//  builds stay in agreement.
//
//  House rule: no em dashes anywhere.
//

import Foundation

public enum Analyze {

    // The assessed result. Mirrors the object analyseSwing returns in the web
    // build, narrowed to what the record and the later views actually read.
    public struct SwingAnalysis {
        public var ok: Bool
        public var reason: String? = nil
        public var confidence: Double
        public var validity: ValidityResult? = nil
        public var view: CameraView? = nil
        // Per swing confidence and Z axis reliability, from the frames and the
        // detected view. Consumed by the metrics UI to badge degraded data.
        // Whether the tracked 3D depth channel is trustworthy for this clip,
        // from the lead wrist jitter test. False on failed analyses.
        public var depthReliable: Bool = false
        public var quality: SessionQuality? = nil

        // Present only when ok is true.
        public var phases: PhaseResult? = nil
        public var sequence: SequenceResult? = nil
        public var xf: XFactorResult? = nil
        public var fundamentals: Fundamentals? = nil
        public var scores: ScoreResult? = nil
        public var diagnosis: DiagnosisResult? = nil
        public var measured: MeasuredSet? = nil

        static func failed(_ reason: String, confidence: Double, validity: ValidityResult? = nil, view: CameraView? = nil) -> SwingAnalysis {
            SwingAnalysis(ok: false, reason: reason, confidence: confidence, validity: validity, view: view)
        }
    }

    /*
      Nothing is scored until the footage has been shown to contain a whole
      person swinging. This gate is the reason the app does not produce a
      confident diagnosis of a video of somebody's hand.
    */
    public static func analyseSwing(_ frames: [Frame], dominantHand: DominantHand = .right) -> SwingAnalysis {
        let S = Landmarks.sides(dominantHand)

        let validity = Validity.assessClip(frames, S)
        if !validity.ok {
            let reason = validity.reasons.first?.rawValue ?? ValidityReason.lowConfidence.rawValue
            return .failed(reason, confidence: validity.confidence, validity: validity)
        }

        var series = Biomechanics.buildSeries(frames, dominantHand)

        guard let phases = Phases.segment(series, frames) else {
            return .failed(Failure.noSwing, confidence: series.confidence, validity: validity)
        }
        guard let sequence = Sequencing.analyseSequence(series, phases) else {
            return .failed(Failure.noSwing, confidence: series.confidence, validity: validity)
        }

        // The phase indices the rest of this depends on. segment returns a full
        // set when it succeeds, but reading them through the dictionary is
        // optional, so they are pulled once here and a missing one is treated as
        // no swing rather than crashing on a force unwrap.
        guard
            let iP1 = phases.idx[.p1],
            let iP3 = phases.idx[.p3],
            let iP4 = phases.idx[.p4],
            let iP7 = phases.idx[.p7],
            let iP10 = phases.idx[.p10]
        else {
            return .failed(Failure.noSwing, confidence: series.confidence, validity: validity)
        }

        // Now that the phases exist, fill the address to top and downswing
        // stability metrics on the series.
        series.fillStability(p1: iP1, p4: iP4, p7: iP7)

        let xf = Sequencing.analyseXFactor(series, phases)
        let view = cameraView(frames, S, addressIndex: iP1)
        // Confidence and Z axis reliability for this swing, from the tracked
        // frame confidences and the view the pipeline just detected.
        let quality = SessionQuality(
            confidences: frames.map(\.conf),
            view: view.view,
            deviceTier: DeviceTier.detect(),
            times: frames.map(\.t)
        )

        // Depth reliability, from how much noisier the lead wrist path is in 3D
        // than in 2D. Built from the same frames, so it costs one pass over the
        // wrist landmark and nothing more.
        let leadWrist2D = frames.map { f -> Point2D in
            let l = f.norm[S.leadWrist]
            return Point2D(x: l.x, y: l.y)
        }
        let leadWrist3D = frames.map { f -> Vec3 in
            let l = f.world[S.leadWrist]
            return Vec3(x: l.x, y: l.y, z: l.z)
        }
        let depthReliable = Biomechanics.is3DValid(
            leadWrist2D: leadWrist2D,
            leadWrist3D: leadWrist3D,
            times: frames.map(\.t)
        )
        let fundamentals = measureFundamentals(series, frames, phases, view: view, idx: (p1: iP1, p3: iP3, p4: iP4, p7: iP7, p10: iP10))

        /*
          Rotation, measured the most reliable way available for this camera
          angle. Face on, apparent shoulder width gives the turn without touching
          the depth channel. Down the line, neither estimator works, so rotation
          is reported as unavailable rather than estimated.
        */
        let widthTurn = view.view == .faceOn
            ? Biomechanics.turnFromApparentWidth(series, phases, series.torso)
            : nil

        let rotationTrustworthy = series.rotationReliable && view.view != .downTheLine

        let turnAtTop: Double
        if let widthTurn, iP4 < widthTurn.turn.count {
            turnAtTop = abs(widthTurn.turn[iP4])
        } else {
            turnAtTop = xf.shoulderTurn
        }

        let why = rotationWhy(series, view)

        /*
          Every figure that reaches a screen is checked against what a body can
          physically do. Out of range means the measurement failed, not that the
          golfer is remarkable, and it is carried as unmeasurable rather than as
          a number. The keys here match exactly what scoreSwing and diagnose read
          out of the set.
        */
        let pressureReadable = view.pressureReadable ?? false

        var measured: MeasuredSet = [
            "shoulderTurn": rotationTrustworthy ? gate("shoulderTurn", turnAtTop) : unmeasurable(why),
            "hipTurn": rotationTrustworthy ? gate("hipTurn", xf.hipTurn) : unmeasurable(why),
            "separation": rotationTrustworthy ? gate("separation", xf.atTop) : unmeasurable(why),
            "stretch": rotationTrustworthy ? gate("stretch", xf.stretch) : unmeasurable(why),
            "tempo": gate("tempo", phases.tempoRatio),
            "headSway": gate("headSway", fundamentals.headSway),
            "spineDrift": gate("spineDrift", fundamentals.spineDrift),
            "finishPressure": pressureReadable ? gate("pressure", fundamentals.finishPressure) : unmeasurable("camera-angle"),
        ]
        measured["pressureShift"] = pressureReadable
            ? Measurement(value: fundamentals.pressureShift, valid: true)
            : unmeasurable("camera-angle")

        /*
          Too much could not be seen to say anything honest. Five or more of the
          nine measurements failing means the clip did not give the engine enough
          to score, and the swing is kept as an unscored recording rather than
          dressed up with a confident but hollow number.
        */
        /*
          Whether the clip gave the engine enough to score.

          A metric the camera angle simply cannot see (down the line hides the
          rotation family) is not a failure of the clip, it is a fact of the view,
          so it does not count toward the unscored threshold. Only metrics that
          should have been measurable but were not count here. This is what keeps
          a clean down the line swing scored rather than dressed as unscorable.
        */
        let genuinelyUnmeasured = measured.values.filter { !$0.valid && $0.why != "camera-angle" }.count
        if genuinelyUnmeasured >= 5 {
            var flagged = validity
            flagged.ok = false
            flagged.reasons = [.lowConfidence]
            flagged.measured = measured
            return .failed(ValidityReason.lowConfidence.rawValue, confidence: series.confidence, validity: flagged, view: view)
        }

        let scores = Scoring.scoreSwing(phases: phases, sequence: sequence, xf: xf, fundamentals: fundamentals, measured: measured)
        let diagnosis = Diagnosis.diagnose(DiagnosisContext(
            series: series,
            phases: phases,
            sequence: sequence,
            xf: xf,
            fundamentals: fundamentals,
            scores: scores,
            measured: measured
        ))

        return SwingAnalysis(
            ok: true,
            reason: nil,
            confidence: series.confidence,
            validity: validity,
            view: view,
            depthReliable: depthReliable,
            quality: quality,
            phases: phases,
            sequence: sequence,
            xf: xf,
            fundamentals: fundamentals,
            scores: scores,
            diagnosis: diagnosis,
            measured: measured
        )
    }

    // MARK: - Record building

    /*
      Turn an analysis result into a storable SwingRecord.

      This lived as a private helper on CaptureViewModel, which was fine while
      capture was the only producer. Upload is a second producer of the exact
      same shape, so the builder moved here, beside the pipeline it summarises,
      and takes the source as a parameter, "capture" or "upload", rather than
      hard coding it. Pure over value types, so both callers use it off the main
      actor without ceremony.
    */
    public static func buildRecord(from analysis: SwingAnalysis, createdAt: Date, source: String) -> SwingRecord {
        let id = UUID().uuidString
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        let day = dayFormatter.string(from: createdAt)
        let viewString = analysis.view?.view.rawValue

        if analysis.ok, let scoreResult = analysis.scores, let phaseResult = analysis.phases {
            let categoryScores = scoreResult.categoryScores.compactMapValues { $0 }
            let scores = Scores(
                overall: scoreResult.overall ?? 0,
                categoryScores: categoryScores,
                weakest: scoreResult.weakest
            )
            let phaseSummary = PhaseSummary(
                idx: Dictionary(uniqueKeysWithValues: phaseResult.idx.map { ($0.key.rawValue, $0.value) }),
                tempoRatio: phaseResult.tempoRatio,
                backswingMs: phaseResult.backswingMs,
                downswingMs: phaseResult.downswingMs
            )
            let sequenceSummary = analysis.sequence.map { seq in
                SequenceSummary(
                    observedOrder: seq.observedOrder.map(\.rawValue),
                    orderCorrect: seq.orderCorrect,
                    gaps: seq.gaps.map(\.ms)
                )
            }

            return SwingRecord(
                id: id,
                createdAt: createdAt,
                day: day,
                club: "",
                source: source,
                timeBase: "video",
                analysed: true,
                confidence: analysis.confidence,
                scores: scores,
                diagnosis: analysis.diagnosis,
                phases: phaseSummary,
                sequence: sequenceSummary,
                view: viewString,
                validity: analysis.validity
            )
        }

        // Kept, unscored. A recording the engine could not read is still the
        // golfer's recording.
        return SwingRecord(
            id: id,
            createdAt: createdAt,
            day: day,
            club: "",
            source: source,
            timeBase: "video",
            analysed: false,
            confidence: analysis.confidence,
            failure: analysis.reason,
            view: viewString,
            validity: analysis.validity
        )
    }

    // MARK: - Failure reasons

    public enum Failure {
        public static let tooShort = "too-short"
        public static let noSwing = "no-swing"
        public static let lowConfidence = "low-confidence"
    }

    // MARK: - Camera view (ported from validity.js)

    /*
      Which way the camera is looking, inferred from how wide the body reads in
      the frame. Face on, the shoulders and ankles are spread across the picture.
      Down the line they collapse toward a single vertical line. The score is the
      combined spread over body height, so it holds at any distance.
    */
    public static func cameraView(_ frames: [Frame], _ S: Sides, addressIndex: Int = 0) -> CameraView {
        guard !frames.isEmpty else { return CameraView(view: .unknown, faceOnScore: 0) }
        let index = min(max(addressIndex, 0), frames.count - 1)
        let n = frames[index].norm

        let needed = [S.leadShoulder, S.trailShoulder, S.leadAnkle, S.trailAnkle,
                      Landmarks.NOSE, Landmarks.LEFT_ANKLE, Landmarks.RIGHT_ANKLE].max() ?? 0
        guard n.count > needed else { return CameraView(view: .unknown, faceOnScore: 0) }

        let shoulderSpan = abs(n[S.leadShoulder].x - n[S.trailShoulder].x)
        let ankleSpan = abs(n[S.leadAnkle].x - n[S.trailAnkle].x)
        let rawHeight = abs(n[Landmarks.NOSE].y - max(n[Landmarks.LEFT_ANKLE].y, n[Landmarks.RIGHT_ANKLE].y))
        let height = rawHeight == 0 ? 1 : rawHeight

        let faceOnScore = (shoulderSpan + ankleSpan) / height
        let kind: CameraViewKind = faceOnScore > 0.34 ? .faceOn : (faceOnScore > 0.18 ? .angled : .downTheLine)

        // Pressure across the stance is only readable when the feet are actually
        // separated across the picture.
        return CameraView(view: kind, faceOnScore: round3(faceOnScore), pressureReadable: (ankleSpan / height) > 0.11)
    }

    // MARK: - Fundamentals (ported from analyze.js measureFundamentals)

    private struct PhaseIdx {
        var p1: Int
        var p3: Int
        var p4: Int
        var p7: Int
        var p10: Int
    }

    private static func measureFundamentals(_ series: SwingSeries, _ frames: [Frame], _ phases: PhaseResult, view: CameraView, idx raw: (p1: Int, p3: Int, p4: Int, p7: Int, p10: Int)) -> Fundamentals {
        let i = PhaseIdx(p1: raw.p1, p3: raw.p3, p4: raw.p4, p7: raw.p7, p10: raw.p10)
        let scale = Biomechanics.bodyScale(frames)
        let n = series.n

        func at(_ arr: [Double], _ k: Int) -> Double {
            guard !arr.isEmpty else { return 0 }
            return arr[min(max(k, 0), arr.count - 1)]
        }

        // Head travel, in centimetres, from address to impact.
        let headStart = at(series.headX, i.p1)
        var maxSway = 0.0
        var k = i.p1
        while k <= i.p7 {
            maxSway = max(maxSway, abs(at(series.headX, k) - headStart))
            k += 1
        }

        let topPressure = at(series.pressure, i.p4)
        let impactPressure = at(series.pressure, i.p7)
        let finishPressure = at(series.pressure, i.p10)

        // How long the finish was actually held before the golfer moved out of it.
        var holdMs = 0.0
        let finishPos = at(series.comX, i.p10)
        var f = i.p10
        while f < n {
            if abs(at(series.comX, f) - finishPos) > 0.06 { break }
            holdMs = at(series.t, f) - at(series.t, i.p10)
            f += 1
        }
        if i.p10 >= n - 2 { holdMs = max(holdMs, 250) }

        // Spine angle drift from address through impact.
        var spineDrift = 0.0
        var s = i.p1
        while s <= i.p7 {
            spineDrift = max(spineDrift, abs(at(series.spineTilt, s) - at(series.spineTilt, i.p1)))
            s += 1
        }

        // Width of the takeaway: how far the hands travel from the body centre by
        // the time the club is halfway back.
        let side = series.sides
        let frameForP3 = frames[min(max(i.p3, 0), frames.count - 1)]
        let w = frameForP3.world
        var takeawayWidth = 0.0
        if w.count > max(side.leadHip, side.trailHip, side.leadWrist) {
            let centre = Geometry.v.mid(w[side.leadHip].vec, w[side.trailHip].vec)
            takeawayWidth = Geometry.v.dist(w[side.leadWrist].vec, centre) / (scale == 0 ? 1 : scale)
        }

        let stanceRatio = series.stanceWidth / (scale == 0 ? 1 : scale)

        return Fundamentals(
            headSway: maxSway * 100,
            pressureShift: impactPressure - topPressure,
            topPressure: topPressure,
            stanceRatio: stanceRatio,
            spineDrift: spineDrift,
            finishPressure: finishPressure,
            finishHoldMs: holdMs,
            takeawayWidth: takeawayWidth
        )
    }

    // MARK: - Bounds (ported from validity.js)

    /*
      Physical plausibility bounds for the numbers that reach the screen.
      Anything outside these is a measurement failure rather than an unusual
      golfer, and is shown as unmeasurable rather than as a figure.
    */
    static let bounds: [String: ClosedRange<Double>] = [
        "shoulderTurn": 0...140,
        "hipTurn": 0...95,
        "separation": -25...85,
        "stretch": -30...40,
        "tempo": 0.8...8,
        "pressure": 0...1,
        "headSway": 0...45,
        "spineDrift": 0...45,
    ]

    public static func withinBounds(_ key: String, _ value: Double) -> Bool {
        guard let range = bounds[key], value.isFinite else { return false }
        return range.contains(value)
    }

    // MARK: - Gated measurement helpers (ported from analyze.js)

    /* Bounds checked measurement. Carries whether it can be trusted alongside
       the figure, so no screen has to guess. The raw value is kept even when out
       of range, since consumers read the valid flag before the value. */
    private static func gate(_ key: String, _ value: Double) -> Measurement {
        Measurement(value: value, valid: withinBounds(key, value), why: nil)
    }

    private static func unmeasurable(_ why: String) -> Measurement {
        Measurement(value: 0, valid: false, why: why)
    }

    /* Which of the reasons rotation is unavailable, so the screen can say the
       useful one rather than a generic failure. */
    private static func rotationWhy(_ series: SwingSeries, _ view: CameraView) -> String {
        if view.view == .downTheLine { return "camera-angle" }
        if !series.rotationReliable { return "tracking-unstable" }
        return "out-of-range"
    }

    private static func round3(_ x: Double) -> Double {
        (x * 1000).rounded() / 1000
    }
}

