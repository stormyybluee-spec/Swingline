import Foundation

/*
  Shared types for the Swingline Swift core.

  Everything the engine passes between files lives here. The rule is that no
  engine file defines a type another engine file needs, so there is exactly one
  place to look when two files disagree about a shape.

  House rule: no em dashes anywhere.

  CHANGES MADE WHILE FIXING THE FIRST BUILD, all of them recorded so the web
  build and this one do not quietly drift apart:

    1. PhaseKey and StageKey were typealiases to String. Every call site in
       Phases.swift and Biomechanics writes them as .p1, .p4, .address and so
       on, which a String cannot answer. They are now real enums with the same
       string raw values, so anything already persisted still decodes.

    2. Rating.updatedAt was a Date. Scoring.swift, which is the ported engine
       and therefore the source of truth, does arithmetic on it in epoch
       milliseconds. It is now a Double in epoch milliseconds, matching the
       TypeScript original exactly.

    3. Landmark gained an optional score. Landmarks.frameConfidence reads
       visibility ?? score ?? 1, because MediaPipe reports visibility and
       Vision reports a confidence, and the engine should not care which
       backend filled the frame in.

    4. The validity chain, Measurement, ValidityReason, ValidityDetail and
       ValidityResult, is now Codable and Hashable. SwingRecord stores a
       ValidityResult and could not synthesise its own conformances without it.

    5. StoredSwingLike, DrillWorkResult, RepeatabilitySwingLike,
       RepeatabilityFailure, RepeatabilitySuccess and RepeatabilityBandInfo
       were referenced by Diagnosis.swift and Repeatability.swift but never
       declared. They are declared here as structs rather than protocols on
       purpose: an existential parameter would need `any` in Swift 6, and
       nothing constructs these yet, so a struct is the shape with the fewest
       future edges.
*/

// MARK: - Vectors and landmarks

public struct Vec3 {
    public var x: Double
    public var y: Double
    public var z: Double?

    public init(x: Double, y: Double, z: Double? = nil) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct Landmark {
    public var x: Double
    public var y: Double
    public var z: Double?
    public var visibility: Double?
    /* Vision reports a per joint confidence rather than MediaPipe's
       visibility. Both mean "how much should this joint be trusted", so the
       engine reads whichever one the backend filled in. */
    public var score: Double?

    public init(x: Double, y: Double, z: Double? = nil, visibility: Double? = nil, score: Double? = nil) {
        self.x = x
        self.y = y
        self.z = z
        self.visibility = visibility
        self.score = score
    }

    public var vec: Vec3 {
        Vec3(x: self.x, y: self.y, z: self.z)
    }
}

public typealias LandmarkSet = [Landmark]

public struct PersonDetection {
    public var norm: LandmarkSet
    public var world: LandmarkSet
    public var conf: Double

    public init(norm: LandmarkSet, world: LandmarkSet, conf: Double) {
        self.norm = norm
        self.world = world
        self.conf = conf
    }
}

public struct Frame {
    public var t: Double
    public var world: LandmarkSet
    public var norm: LandmarkSet
    public var conf: Double
    public var people: [PersonDetection]?

    public init(t: Double, world: LandmarkSet, norm: LandmarkSet, conf: Double, people: [PersonDetection]? = nil) {
        self.t = t
        self.world = world
        self.norm = norm
        self.conf = conf
        self.people = people
    }
}

public struct Sides {
    public var leadShoulder: Int
    public var trailShoulder: Int
    public var leadElbow: Int
    public var trailElbow: Int
    public var leadWrist: Int
    public var trailWrist: Int
    public var leadHip: Int
    public var trailHip: Int
    public var leadKnee: Int
    public var trailKnee: Int
    public var leadAnkle: Int
    public var trailAnkle: Int
    public var targetSign: Int

    public init(leadShoulder: Int, trailShoulder: Int, leadElbow: Int, trailElbow: Int, leadWrist: Int, trailWrist: Int, leadHip: Int, trailHip: Int, leadKnee: Int, trailKnee: Int, leadAnkle: Int, trailAnkle: Int, targetSign: Int) {
        self.leadShoulder = leadShoulder
        self.trailShoulder = trailShoulder
        self.leadElbow = leadElbow
        self.trailElbow = trailElbow
        self.leadWrist = leadWrist
        self.trailWrist = trailWrist
        self.leadHip = leadHip
        self.trailHip = trailHip
        self.leadKnee = leadKnee
        self.trailKnee = trailKnee
        self.leadAnkle = leadAnkle
        self.trailAnkle = trailAnkle
        self.targetSign = targetSign
    }
}

public enum DominantHand: String, Codable, Hashable, CaseIterable {
    case left, right
}

// MARK: - Phases and stages

/*
  P1 through P10, the real coaching positions. Raw values match the strings the
  web build persists, so a swing recorded there still decodes here.
*/
public enum PhaseKey: String, Codable, Hashable, CaseIterable {
    case p1, p2, p3, p4, p5, p6, p7, p8, p9, p10
}

/* The five stages the interface actually shows. */
public enum StageKey: String, Codable, Hashable, CaseIterable {
    case address, takeaway, top, downswing, finish
}

// MARK: - Series

public struct SwingSeries {
    public var t: [Double]
    public var n: Int
    public var sides: Sides
    public var pelvis: [Double]
    public var torso: [Double]
    public var xFactor: [Double]
    public var pelvisSpeed: [Double]
    public var torsoSpeed: [Double]
    public var armSpeed: [Double]
    public var handSpeed: [Double]
    public var pelvisVel: [Double]
    public var torsoVel: [Double]
    public var spineTilt: [Double]
    public var headX: [Double]
    public var headY: [Double]
    public var comX: [Double]
    public var comY: [Double]
    public var pressure: [Double]
    public var pressureValid: [Bool]
    public var pressureValidFraction: Double
    public var flipFraction: Double
    public var rotationReliable: Bool
    public var shoulderSpanImage: [Double]
    public var scale: Double
    public var handPos: [Vec3]
    public var handY: [Double]
    public var leadElbowAngle: [Double]
    public var trailKneeFlex: [Double]
    public var stanceWidth: Double
    public var turnFrom: (Int) -> (pelvis: [Double], torso: [Double])
    public var confidence: Double

    /*
      Per frame world space paths of the pelvis and torso centres, up positive.
      These need no phase indices, so buildSeries fills them. The address to top
      deltas that the stability metrics report are computed later by
      fillStability, once the phases exist, because segmentation runs after the
      series is built and buildSeries has no p1 or p4 to difference against.
    */
    public var pelvisAbsX: [Double] = []
    public var pelvisAbsY: [Double] = []
    public var torsoAbsX: [Double] = []
    public var torsoAbsY: [Double] = []
    public var torsoAbsZ: [Double] = []
    // Lead arm angular speed per frame, for the lever arm release ratio.
    public var armAngularVel: [Double] = []

    /*
      Stability metrics, filled by fillStability. Nil until it runs, which is the
      honest state: the value is an address to top or downswing quantity and
      cannot exist before the phases that define those points.
    */
    public var normalizedPelvisLift: Double?
    public var normalizedPelvisSway: Double?
    public var normalizedTorsoSway: Double?
    public var normalizedTorsoThrust: Double?
    public var normalizedTorsoLift: Double?
    public var leverArmReleaseRatio: Double?
    public var stabilityScores: [String: Double]?

    /*
      Lead wrist control proxies, per frame, in degrees, computed from the body
      landmarks (elbow, wrist, index, pinky). One camera gives one in plane wrist
      angle, so these two are correlated 2D proxies, not independent clinical
      flexion and deviation. Deviation is the mean cock of the fingers relative to
      the forearm (radial positive, ulnar negative); flexion is the roll between
      the index and pinky sides of the hand (bowed positive, cupped negative).
      Both are depth sensitive and hidden down the line.
    */
    public var leadWristFlexion: [Double] = []
    public var leadWristDeviation: [Double] = []

    /*
      Ball flight efficiency, horizontal displacement over peak height, from a
      fitted trajectory. Nil unless a ball was actually tracked, which needs a
      detection step that does not exist yet, so this stays nil and its card
      reads unavailable rather than inventing a flight.
    */
    public var flightEfficiency: Double?

    /*
      Ball flight estimates. Model figures, not measurements: driven by the one
      measured input (hand speed at impact) plus club average tables, so they are
      always shown labelled Est. with a pose confidence dot. Filled by the
      estimator once phases and the chosen club are known; zero until then.
    */
    public var clubheadSpeedEstimate: Double = 0.0
    public var ballSpeedEstimate: Double = 0.0
    public var launchAngleEstimate: Double = 0.0
    public var carryDistanceEstimate: Double = 0.0
    public var spinRateEstimate: Int = 0
    public var estimatedClub: ClubType = .driver
    // Schematic flight, normalised image points, not registered to the scene.
    public var ballTrajectory: [CGPoint] = []

    public init(t: [Double], n: Int, sides: Sides, pelvis: [Double], torso: [Double], xFactor: [Double], pelvisSpeed: [Double], torsoSpeed: [Double], armSpeed: [Double], handSpeed: [Double], pelvisVel: [Double], torsoVel: [Double], spineTilt: [Double], headX: [Double], headY: [Double], comX: [Double], comY: [Double], pressure: [Double], pressureValid: [Bool], pressureValidFraction: Double, flipFraction: Double, rotationReliable: Bool, shoulderSpanImage: [Double], scale: Double, handPos: [Vec3], handY: [Double], leadElbowAngle: [Double], trailKneeFlex: [Double], stanceWidth: Double, turnFrom: @escaping (Int) -> (pelvis: [Double], torso: [Double]), confidence: Double, pelvisAbsX: [Double] = [], pelvisAbsY: [Double] = [], torsoAbsX: [Double] = [], torsoAbsY: [Double] = [], torsoAbsZ: [Double] = [], armAngularVel: [Double] = [], normalizedPelvisLift: Double? = nil, normalizedPelvisSway: Double? = nil, normalizedTorsoSway: Double? = nil, normalizedTorsoThrust: Double? = nil, normalizedTorsoLift: Double? = nil, leverArmReleaseRatio: Double? = nil, stabilityScores: [String: Double]? = nil, leadWristFlexion: [Double] = [], leadWristDeviation: [Double] = [], flightEfficiency: Double? = nil) {
        self.t = t
        self.n = n
        self.sides = sides
        self.pelvis = pelvis
        self.torso = torso
        self.xFactor = xFactor
        self.pelvisSpeed = pelvisSpeed
        self.torsoSpeed = torsoSpeed
        self.armSpeed = armSpeed
        self.handSpeed = handSpeed
        self.pelvisVel = pelvisVel
        self.torsoVel = torsoVel
        self.spineTilt = spineTilt
        self.headX = headX
        self.headY = headY
        self.comX = comX
        self.comY = comY
        self.pressure = pressure
        self.pressureValid = pressureValid
        self.pressureValidFraction = pressureValidFraction
        self.flipFraction = flipFraction
        self.rotationReliable = rotationReliable
        self.shoulderSpanImage = shoulderSpanImage
        self.scale = scale
        self.handPos = handPos
        self.handY = handY
        self.leadElbowAngle = leadElbowAngle
        self.trailKneeFlex = trailKneeFlex
        self.stanceWidth = stanceWidth
        self.turnFrom = turnFrom
        self.confidence = confidence
        self.pelvisAbsX = pelvisAbsX
        self.pelvisAbsY = pelvisAbsY
        self.torsoAbsX = torsoAbsX
        self.torsoAbsY = torsoAbsY
        self.torsoAbsZ = torsoAbsZ
        self.armAngularVel = armAngularVel
        self.normalizedPelvisLift = normalizedPelvisLift
        self.normalizedPelvisSway = normalizedPelvisSway
        self.normalizedTorsoSway = normalizedTorsoSway
        self.normalizedTorsoThrust = normalizedTorsoThrust
        self.normalizedTorsoLift = normalizedTorsoLift
        self.leverArmReleaseRatio = leverArmReleaseRatio
        self.stabilityScores = stabilityScores
        self.leadWristFlexion = leadWristFlexion
        self.leadWristDeviation = leadWristDeviation
        self.flightEfficiency = flightEfficiency
    }

    /*
      Compute the address to top and downswing stability metrics from the stored
      per frame paths, given the phase indices. Call this once phases exist,
      typically right after Phases.segment, with p1 address, p4 top, p7 impact.

      Lift and sway and thrust are the movement of the pelvis and torso centres
      from address to top, lift normalised by body height, sway by stance width,
      so they read as percentages that mean the same thing for a tall and a short
      golfer. Lever arm release is the peak ratio of arm angular speed to pelvis
      angular speed across the downswing, high when the release is late and sharp.

      Signs match the paths: Y is stored up positive, so a positive lift is the
      pelvis rising, an early extension fault. Nothing is written when the inputs
      are missing, so a metric stays nil and its card reads unavailable rather
      than showing a made up number.
    */
    public mutating func fillStability(p1: Int, p4: Int, p7: Int) {
        guard scale > 0 else { return }
        let has: ([Double], Int) -> Bool = { $0.indices.contains($1) }

        if has(pelvisAbsY, p1), has(pelvisAbsY, p4) {
            normalizedPelvisLift = (pelvisAbsY[p4] - pelvisAbsY[p1]) / scale * 100
        }
        if stanceWidth > 0, has(pelvisAbsX, p1), has(pelvisAbsX, p4) {
            normalizedPelvisSway = (pelvisAbsX[p4] - pelvisAbsX[p1]) / stanceWidth * 100
        }
        if has(torsoAbsY, p1), has(torsoAbsY, p4) {
            normalizedTorsoLift = (torsoAbsY[p4] - torsoAbsY[p1]) / scale * 100
        }
        if stanceWidth > 0, has(torsoAbsX, p1), has(torsoAbsX, p4) {
            normalizedTorsoSway = (torsoAbsX[p4] - torsoAbsX[p1]) / stanceWidth * 100
        }
        if has(torsoAbsZ, p1), has(torsoAbsZ, p4) {
            normalizedTorsoThrust = (torsoAbsZ[p4] - torsoAbsZ[p1]) / scale * 100
        }

        if p7 > p4 {
            var maxRatio = 0.0
            let upper = Swift.min(p7, n - 1)
            if upper >= p4 {
                for i in p4...upper where pelvisVel.indices.contains(i) && armAngularVel.indices.contains(i) {
                    let pv = abs(pelvisVel[i])
                    if pv > 1e-6 { maxRatio = Swift.max(maxRatio, abs(armAngularVel[i]) / pv) }
                }
            }
            if maxRatio > 0 { leverArmReleaseRatio = maxRatio }
        }
    }
}

public struct PhaseResult {
    public var idx: [PhaseKey: Int]
    public var times: [PhaseKey: Double]
    public var backswingMs: Double
    public var downswingMs: Double
    public var tempoRatio: Double
    public var confidence: [PhaseKey: Double]

    public init(idx: [PhaseKey: Int], times: [PhaseKey: Double], backswingMs: Double, downswingMs: Double, tempoRatio: Double, confidence: [PhaseKey: Double]) {
        self.idx = idx
        self.times = times
        self.backswingMs = backswingMs
        self.downswingMs = downswingMs
        self.tempoRatio = tempoRatio
        self.confidence = confidence
    }
}

// MARK: - Sequencing

public enum SegmentKey: String, Codable, Hashable, CaseIterable {
    case pelvis, torso, arm, club
}

public struct SequencePeak {
    public var index: Int
    public var time: Double
    public var value: Double
    public var relative: Double

    public init(index: Int, time: Double, value: Double, relative: Double) {
        self.index = index
        self.time = time
        self.value = value
        self.relative = relative
    }
}

public struct SequenceGap {
    public var from: SegmentKey
    public var to: SegmentKey
    public var ms: Double

    public init(from: SegmentKey, to: SegmentKey, ms: Double) {
        self.from = from
        self.to = to
        self.ms = ms
    }
}

public struct SequenceResult {
    public var peaks: [SegmentKey: SequencePeak]
    public var gaps: [SequenceGap]
    public var observedOrder: [SegmentKey]
    public var orderCorrect: Bool
    public var inversions: Int
    public var goodGaps: Int
    public var okGaps: Int
    public var upperBodyFirst: Bool
    public var armsFirst: Bool
    public var allAtOnce: Bool
    public var speedsAscend: Bool

    public init(peaks: [SegmentKey: SequencePeak], gaps: [SequenceGap], observedOrder: [SegmentKey], orderCorrect: Bool, inversions: Int, goodGaps: Int, okGaps: Int, upperBodyFirst: Bool, armsFirst: Bool, allAtOnce: Bool, speedsAscend: Bool) {
        self.peaks = peaks
        self.gaps = gaps
        self.observedOrder = observedOrder
        self.orderCorrect = orderCorrect
        self.inversions = inversions
        self.goodGaps = goodGaps
        self.okGaps = okGaps
        self.upperBodyFirst = upperBodyFirst
        self.armsFirst = armsFirst
        self.allAtOnce = allAtOnce
        self.speedsAscend = speedsAscend
    }
}

public struct XFactorResult {
    public var atTop: Double
    public var peak: Double
    public var peakIndex: Int
    public var stretch: Double
    public var shoulderTurn: Double
    public var hipTurn: Double
    public var earlyReversalMs: Double?

    public init(atTop: Double, peak: Double, peakIndex: Int, stretch: Double, shoulderTurn: Double, hipTurn: Double, earlyReversalMs: Double?) {
        self.atTop = atTop
        self.peak = peak
        self.peakIndex = peakIndex
        self.stretch = stretch
        self.shoulderTurn = shoulderTurn
        self.hipTurn = hipTurn
        self.earlyReversalMs = earlyReversalMs
    }
}

// MARK: - Measurement gates

public struct Measurement: Codable, Hashable {
    public var value: Double
    public var valid: Bool
    public var why: String?

    public init(value: Double, valid: Bool, why: String? = nil) {
        self.value = value
        self.valid = valid
        self.why = why
    }
}

public typealias MeasuredSet = [String: Measurement]

// MARK: - Validity

public enum ValidityReason: String, Codable, Hashable, CaseIterable {
    case tooShort = "too-short"
    case noBody = "no-body"
    case partialBody = "partial-body"
    case notHumanScale = "not-human-scale"
    case noMotion = "no-motion"
    case lowConfidence = "low-confidence"
    case tooSmall = "too-small"
}

public struct ValidityDetail: Codable, Hashable {
    public var visibleFraction: Double
    public var humanFraction: Double
    public var feetFraction: Double
    public var travelInWidths: Double
    public var shoulderWidth: Double
    public var subjectFill: Double

    public init(visibleFraction: Double, humanFraction: Double, feetFraction: Double, travelInWidths: Double, shoulderWidth: Double, subjectFill: Double) {
        self.visibleFraction = visibleFraction
        self.humanFraction = humanFraction
        self.feetFraction = feetFraction
        self.travelInWidths = travelInWidths
        self.shoulderWidth = shoulderWidth
        self.subjectFill = subjectFill
    }
}

public struct ValidityResult: Codable, Hashable {
    public var ok: Bool
    public var reasons: [ValidityReason]
    public var confidence: Double
    public var degraded: Bool
    public var fill: Double?
    public var detail: ValidityDetail?
    public var measured: MeasuredSet?

    public init(ok: Bool, reasons: [ValidityReason], confidence: Double, degraded: Bool, fill: Double?, detail: ValidityDetail?, measured: MeasuredSet? = nil) {
        self.ok = ok
        self.reasons = reasons
        self.confidence = confidence
        self.degraded = degraded
        self.fill = fill
        self.detail = detail
        self.measured = measured
    }

    /* Older records stored subject fill inside detail rather than at the top
       level. Repeatability's capture fingerprint needs whichever one is
       present, so it asks for fill first and falls back to this. */
    public var subjectFill: Double? { detail?.subjectFill }
}

public enum CameraViewKind: String, Codable, Hashable, CaseIterable {
    case faceOn = "face-on"
    case angled = "angled"
    case downTheLine = "down-the-line"
    case unknown = "unknown"
}

public struct CameraView: Codable, Hashable {
    public var view: CameraViewKind
    public var faceOnScore: Double
    public var pressureReadable: Bool?

    public init(view: CameraViewKind, faceOnScore: Double, pressureReadable: Bool? = nil) {
        self.view = view
        self.faceOnScore = faceOnScore
        self.pressureReadable = pressureReadable
    }
}

// MARK: - Categories

public enum CategoryKey: String, Codable, Hashable, CaseIterable {
    case sequencing = "sequencing"
    case rotation = "rotation"
    case balance = "balance"
    case finish = "finish"

    /* The label used on screen. No biomechanics term ever reaches the
       interface, so this is the whole vocabulary the golfer sees. */
    public var label: String {
        switch self {
        case .sequencing: return "Sequencing"
        case .rotation: return "Rotation"
        case .balance: return "Balance"
        case .finish: return "Finish"
        }
    }
}

public struct ScoreBands {
    public var good: (Double, Double)
    public var ok: (Double, Double)
    public var hard: (Double, Double)

    public init(good: (Double, Double), ok: (Double, Double), hard: (Double, Double)) {
        self.good = good
        self.ok = ok
        self.hard = hard
    }
}

public struct Fundamentals: Codable, Hashable {
    public var headSway: Double
    public var pressureShift: Double
    public var topPressure: Double
    public var stanceRatio: Double
    public var spineDrift: Double
    public var finishPressure: Double
    public var finishHoldMs: Double
    public var takeawayWidth: Double

    public init(headSway: Double, pressureShift: Double, topPressure: Double, stanceRatio: Double, spineDrift: Double, finishPressure: Double, finishHoldMs: Double, takeawayWidth: Double) {
        self.headSway = headSway
        self.pressureShift = pressureShift
        self.topPressure = topPressure
        self.stanceRatio = stanceRatio
        self.spineDrift = spineDrift
        self.finishPressure = finishPressure
        self.finishHoldMs = finishHoldMs
        self.takeawayWidth = takeawayWidth
    }
}

public struct ScoredMetric {
    public var id: String
    public var category: CategoryKey
    public var label: String
    public var plain: String
    public var value: Double
    public var unit: String?
    public var display: String
    public var score: Int?
    public var measurable: Bool
    public var why: String?
    public var gate: String?

    public init(id: String, category: CategoryKey, label: String, plain: String, value: Double, unit: String? = nil, display: String, score: Int?, measurable: Bool, why: String? = nil, gate: String? = nil) {
        self.id = id
        self.category = category
        self.label = label
        self.plain = plain
        self.value = value
        self.unit = unit
        self.display = display
        self.score = score
        self.measurable = measurable
        self.why = why
        self.gate = gate
    }
}

public struct ScoreResult {
    public var metrics: [ScoredMetric]
    public var categoryScores: [CategoryKey: Int?]
    public var categoryMeasurable: [CategoryKey: Bool]
    public var overall: Int?
    public var weakest: CategoryKey?
    public var measuredCategories: Int

    public init(metrics: [ScoredMetric], categoryScores: [CategoryKey: Int?], categoryMeasurable: [CategoryKey: Bool], overall: Int?, weakest: CategoryKey?, measuredCategories: Int) {
        self.metrics = metrics
        self.categoryScores = categoryScores
        self.categoryMeasurable = categoryMeasurable
        self.overall = overall
        self.weakest = weakest
        self.measuredCategories = measuredCategories
    }
}

// MARK: - Rating

/*
  updatedAt is epoch milliseconds, not a Date.

  Scoring.updateRating ages the deviation by dividing an elapsed interval by
  86400000, and treats a zero as "never rated before". Both of those are
  milliseconds arithmetic carried straight over from the TypeScript engine, so
  the field is the unit the engine actually works in rather than the unit
  Foundation would prefer.
*/
public struct Rating: Codable, Hashable {
    public var rating: Double
    public var rd: Double
    public var swings: Int
    public var updatedAt: Double

    static let rdStart: Double = 24
    static let rdCeiling: Double = 30
    static let driftPerDay: Double = 0.55

    public init(rating: Double, rd: Double, swings: Int, updatedAt: Double) {
        self.rating = rating
        self.rd = rd
        self.swings = swings
        self.updatedAt = updatedAt
    }

    public static func new(seed: Double = 55) -> Rating {
        Rating(rating: seed, rd: rdStart, swings: 0, updatedAt: Date().timeIntervalSince1970 * 1000)
    }

    public var band: (low: Int, high: Int, point: Int, settled: Bool) {
        let half = 1.96 * rd
        let low = Int(min(max(rating - half, 0), 100).rounded())
        let high = Int(min(max(rating + half, 0), 100).rounded())
        return (low, high, Int(rating.rounded()), half < 6)
    }

    public var bandLabel: String {
        let b = band
        return b.settled ? "\(b.point)" : "\(b.low) to \(b.high)"
    }
}

public struct RatingBand: Codable, Hashable {
    public var low: Int
    public var high: Int
    public var point: Int
    public var settled: Bool

    public init(low: Int, high: Int, point: Int, settled: Bool) {
        self.low = low
        self.high = high
        self.point = point
        self.settled = settled
    }
}

// MARK: - Diagnosis

public struct DiagnosisContext {
    public var series: SwingSeries
    public var phases: PhaseResult
    public var sequence: SequenceResult
    public var xf: XFactorResult
    public var fundamentals: Fundamentals
    public var scores: ScoreResult
    public var measured: MeasuredSet

    public init(series: SwingSeries, phases: PhaseResult, sequence: SequenceResult, xf: XFactorResult, fundamentals: Fundamentals, scores: ScoreResult, measured: MeasuredSet) {
        self.series = series
        self.phases = phases
        self.sequence = sequence
        self.xf = xf
        self.fundamentals = fundamentals
        self.scores = scores
        self.measured = measured
    }
}

public struct DiagnosisFaultSummary: Codable, Hashable {
    public var id: String
    public var category: CategoryKey
    public var headline: String
    public var drill: String?

    public init(id: String, category: CategoryKey, headline: String, drill: String?) {
        self.id = id
        self.category = category
        self.headline = headline
        self.drill = drill
    }
}

public struct DiagnosisResult: Codable, Hashable {
    public var headline: String
    public var detail: String
    public var category: CategoryKey?
    public var drill: String?
    public var faultId: String?
    public var faults: [DiagnosisFaultSummary]
    public var clean: Bool
    public var unscored: Bool?

    public init(headline: String, detail: String, category: CategoryKey?, drill: String?, faultId: String?, faults: [DiagnosisFaultSummary], clean: Bool, unscored: Bool? = nil) {
        self.headline = headline
        self.detail = detail
        self.category = category
        self.drill = drill
        self.faultId = faultId
        self.faults = faults
        self.clean = clean
        self.unscored = unscored
    }
}

public struct StoredSwingDiagnosis: Codable, Hashable {
    public var faultId: String?
    public var category: CategoryKey?
    public var faults: [DiagnosisFaultSummary]?

    public init(faultId: String? = nil, category: CategoryKey? = nil, faults: [DiagnosisFaultSummary]? = nil) {
        self.faultId = faultId
        self.category = category
        self.faults = faults
    }
}

public struct StoredSwingScores: Codable, Hashable {
    public var categoryScores: [CategoryKey: Int]?

    public init(categoryScores: [CategoryKey: Int]? = nil) {
        self.categoryScores = categoryScores
    }
}

/*
  The narrow shape didDrillWork needs from a stored swing.

  Deliberately a struct rather than a protocol. Nothing constructs one yet, and
  an existential parameter would need writing as `any StoredSwingLike` under
  Swift 6, which is a second edit waiting to happen for no benefit.
*/
public struct StoredSwingLike {
    public var diagnosis: StoredSwingDiagnosis?
    public var scores: StoredSwingScores?

    public init(diagnosis: StoredSwingDiagnosis? = nil, scores: StoredSwingScores? = nil) {
        self.diagnosis = diagnosis
        self.scores = scores
    }
}

public struct DrillWorkResult: Hashable {
    public var faultId: String
    public var category: CategoryKey
    /* Whether the named fault stopped firing, which is the only question the
       drill was accountable for. */
    public var cleared: Bool
    public var delta: Int

    public init(faultId: String, category: CategoryKey, cleared: Bool, delta: Int) {
        self.faultId = faultId
        self.category = category
        self.cleared = cleared
        self.delta = delta
    }
}

// MARK: - Cues

public struct CueEntry {
    public var cue: String
    public var distal: String?
    public var constraint: String
    public var internal_: String

    public init(cue: String, distal: String?, constraint: String, internal_: String) {
        self.cue = cue
        self.distal = distal
        self.constraint = constraint
        self.internal_ = internal_
    }
}

public enum CueFocus: String, Codable, Hashable {
    case proximal = "proximal"
    case distal = "distal"
}

public struct CueResult {
    public var cue: String
    public var constraint: String
    public var internal_: String
    public var focus: CueFocus

    public init(cue: String, constraint: String, internal_: String, focus: CueFocus) {
        self.cue = cue
        self.constraint = constraint
        self.internal_ = internal_
        self.focus = focus
    }
}

// MARK: - Repeatability

public struct SessionFingerprint: Hashable {
    public var view: CameraViewKind
    public var fill: Double?

    public init(view: CameraViewKind, fill: Double?) {
        self.view = view
        self.fill = fill
    }
}

/*
  The narrow shape repeatability needs from a stored swing. Same reasoning as
  StoredSwingLike above: a struct, not a protocol.
*/
public struct RepeatabilitySwingLike {
    /* Epoch milliseconds, used only to cut a history into sessions. */
    public var at: Double?
    public var analysed: Bool?
    public var phases: PhaseSummary?
    public var fundamentals: Fundamentals?
    public var validity: ValidityResult?
    public var view: CameraView?

    public init(at: Double? = nil, analysed: Bool? = nil, phases: PhaseSummary? = nil, fundamentals: Fundamentals? = nil, validity: ValidityResult? = nil, view: CameraView? = nil) {
        self.at = at
        self.analysed = analysed
        self.phases = phases
        self.fundamentals = fundamentals
        self.validity = validity
        self.view = view
    }
}

public struct RepeatabilityTrack: Hashable {
    public var key: String
    public var label: String
    public var note: String
    public var cv: Double
    public var score: Int
    public var typical: Double
    public var spread: Double
    public var n: Int

    public init(key: String, label: String, note: String, cv: Double, score: Int, typical: Double, spread: Double, n: Int) {
        self.key = key
        self.label = label
        self.note = note
        self.cv = cv
        self.score = score
        self.typical = typical
        self.spread = spread
        self.n = n
    }
}

public struct RepeatabilityBandInfo: Hashable {
    public var key: String
    public var label: String
    public var note: String

    public init(key: String, label: String, note: String) {
        self.key = key
        self.label = label
        self.note = note
    }
}

public enum RepeatabilityFailReason: String, Hashable {
    case notEnoughSwings
    case setupChanged
    case nothingMeasurable
}

public struct RepeatabilityFailure: Hashable {
    public var reason: RepeatabilityFailReason
    public var have: Int?
    public var need: Int?
    public var message: String

    public init(reason: RepeatabilityFailReason, have: Int? = nil, need: Int? = nil, message: String) {
        self.reason = reason
        self.have = have
        self.need = need
        self.message = message
    }
}

public struct RepeatabilitySuccess: Hashable {
    public var overall: Int
    public var swings: Int
    public var tracks: [RepeatabilityTrack]
    public var leastConsistent: RepeatabilityTrack
    public var mostConsistent: RepeatabilityTrack
    public var band: RepeatabilityBandInfo

    public init(overall: Int, swings: Int, tracks: [RepeatabilityTrack], leastConsistent: RepeatabilityTrack, mostConsistent: RepeatabilityTrack, band: RepeatabilityBandInfo) {
        self.overall = overall
        self.swings = swings
        self.tracks = tracks
        self.leastConsistent = leastConsistent
        self.mostConsistent = mostConsistent
        self.band = band
    }
}

/*
  Returns the reason it cannot answer rather than a number, because a confident
  figure built on two swings is exactly the kind of invented number this app
  exists not to produce.
*/
public enum RepeatabilityResult {
    case failure(RepeatabilityFailure)
    case success(RepeatabilitySuccess)

    public var ok: Bool {
        switch self {
        case .failure: return false
        case .success: return true
        }
    }
}

// MARK: - Tempo

public enum TempoJudgementKey: String, Codable, Hashable {
    case perfect = "perfect"
    case great = "great"
    case good = "good"
    case off = "off"
}

public enum TempoDirection: String, Codable, Hashable {
    case rushed = "rushed"
    case dragged = "dragged"
}

public struct TempoJudgement: Hashable {
    public var ratio: Double
    public var error: Double
    public var direction: TempoDirection
    public var judgement: TempoJudgementKey
    public var label: String
    public var points: Int
    public var backswingMs: Double
    public var downswingMs: Double
    public var message: String

    public init(ratio: Double, error: Double, direction: TempoDirection, judgement: TempoJudgementKey, label: String, points: Int, backswingMs: Double, downswingMs: Double, message: String) {
        self.ratio = ratio
        self.error = error
        self.direction = direction
        self.judgement = judgement
        self.label = label
        self.points = points
        self.backswingMs = backswingMs
        self.downswingMs = downswingMs
        self.message = message
    }
}

// MARK: - DTW

public struct DtwResult {
    public var cost: Double
    public var path: [(Int, Int)]
    public var normalised: Double

    public init(cost: Double, path: [(Int, Int)], normalised: Double) {
        self.cost = cost
        self.path = path
        self.normalised = normalised
    }
}

public typealias FeatureVector = [Double]

public struct DeltaChannel {
    public var key: String
    public var label: String
    public var category: CategoryKey
    public var scale: Double

    public init(key: String, label: String, category: CategoryKey, scale: Double) {
        self.key = key
        self.label = label
        self.category = category
        self.scale = scale
    }
}

public struct DeltaPoint {
    public var progress: Double
    public var i: Int
    public var j: Int
    public var deltas: [String: Double]

    public init(progress: Double, i: Int, j: Int, deltas: [String: Double]) {
        self.progress = progress
        self.i = i
        self.j = j
        self.deltas = deltas
    }
}

public struct DeltaWorst {
    public var magnitude: Double
    public var progress: Double
    public var label: String
    public var category: CategoryKey

    public init(magnitude: Double, progress: Double, label: String, category: CategoryKey) {
        self.magnitude = magnitude
        self.progress = progress
        self.label = label
        self.category = category
    }
}

public struct DeltaTrace {
    public var channels: [DeltaChannel]
    public var points: [DeltaPoint]
    public var worst: [String: DeltaWorst]

    public init(channels: [DeltaChannel], points: [DeltaPoint], worst: [String: DeltaWorst]) {
        self.channels = channels
        self.points = points
        self.worst = worst
    }
}

// MARK: - Stored summaries

/*
  These are what a SwingRecord actually persists. They are summaries, not the
  full engine results, because a stored swing has to survive a schema change
  and a full ScoreResult carries closures and raw series that have no business
  in a saved record.
*/
public struct Scores: Codable, Hashable {
    public var overall: Int
    public var categoryScores: [CategoryKey: Int]
    /* The weakest measured category, carried on the record so the timeline and
       the home screen do not have to recompute it from the metrics. */
    public var weakest: CategoryKey?

    public init(overall: Int, categoryScores: [CategoryKey: Int], weakest: CategoryKey? = nil) {
        self.overall = overall
        self.categoryScores = categoryScores
        self.weakest = weakest
    }

    public func score(for category: CategoryKey) -> Int? {
        categoryScores[category]
    }
}

public struct PhaseSummary: Codable, Hashable {
    public var idx: [String: Int]
    public var tempoRatio: Double
    public var backswingMs: Double
    public var downswingMs: Double

    public init(idx: [String: Int], tempoRatio: Double, backswingMs: Double, downswingMs: Double) {
        self.idx = idx
        self.tempoRatio = tempoRatio
        self.backswingMs = backswingMs
        self.downswingMs = downswingMs
    }
}

public struct SequenceSummary: Codable, Hashable {
    public var observedOrder: [String]
    public var orderCorrect: Bool
    public var gaps: [Double]

    public init(observedOrder: [String], orderCorrect: Bool, gaps: [Double]) {
        self.observedOrder = observedOrder
        self.orderCorrect = orderCorrect
        self.gaps = gaps
    }
}
