//
//  Models.swift
//  Swingline
//
//  The app level records: what a saved swing is, what the plan is, and the two
//  derived shapes the timeline draws from.
//
//  The engine types those records are built out of, Scores, DiagnosisResult,
//  PhaseSummary, SequenceSummary, ValidityResult, all live in CoreTypes.swift.
//  This file holds only the things that would not mean anything to the engine.
//
//  House rule: no em dashes anywhere.
//

import Foundation

// MARK: - Categories

/*
  The four plain language categories, under the name the interface uses.

  This used to be a second enum that duplicated CategoryKey case for case,
  which meant a score could be keyed by one and read by the other. One type
  with two names is safer than two types with the same cases.
*/
public typealias ScoreCategory = CategoryKey

// MARK: - Quota

/*
  What the free tier meters, and what it never does.

  Recording, storage and the golfer's whole history are free and unlimited.
  Only new analysis runs are counted. Nothing already recorded is ever taken
  away, which is why there is no field here that could gate reading a swing.
*/
public struct Quota: Codable, Hashable {
    public var plan: String
    public var unlimited: Bool
    public var limit: Int
    public var used: Int
    public var resetsOn: Date?

    public init(plan: String = "free", unlimited: Bool = false, limit: Int = 15, used: Int = 0, resetsOn: Date? = nil) {
        self.plan = plan
        self.unlimited = unlimited
        self.limit = limit
        self.used = used
        self.resetsOn = resetsOn
    }

    public var remaining: Int {
        unlimited ? .max : max(0, limit - used)
    }

    /* A fresh install, and the value the store boots with before any
       persistence layer has had a chance to say otherwise. */
    public static let free = Quota(
        plan: "free",
        unlimited: false,
        limit: 15,
        used: 0,
        resetsOn: Quota.startOfNextMonth()
    )

    public static let unlimitedPlan = Quota(plan: "unlimited", unlimited: true, limit: 0, used: 0, resetsOn: nil)

    static func startOfNextMonth(from date: Date = Date()) -> Date? {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let startOfThisMonth = calendar.date(from: components) else { return nil }
        return calendar.date(byAdding: .month, value: 1, to: startOfThisMonth)
    }
}

// MARK: - Swing record

/*
  Field for field mirror of the IndexedDB swing record in the web build.

  Every optional here is genuinely optional. A swing that failed validity has
  no scores, no diagnosis and no phases, and it is still kept, still listed and
  still openable, because a golfer who loses a recording because the app could
  not read it learns not to trust the app with recordings.
*/
public struct SwingRecord: Codable, Identifiable, Hashable {
    public var id: String
    public var createdAt: Date
    /* yyyy-MM-dd, used for streaks and for grouping the timeline. Stored
       rather than derived so a swing does not move between days if the device
       time zone changes. */
    public var day: String
    public var club: String
    public var note: String
    public var source: String
    public var timeBase: String
    public var clipStart: Double?
    public var favourite: Bool
    public var analysed: Bool
    public var confidence: Double
    public var failure: String?

    public var scores: Scores?
    public var diagnosis: DiagnosisResult?
    public var phases: PhaseSummary?
    public var sequence: SequenceSummary?
    public var view: String?
    public var validity: ValidityResult?
    /*
      Ball flight estimates from the last analysis, persisted so the timeline can
      show them without reopening the swing. Optional and nil on older records
      and on any swing where no estimate was produced. Model figures, always
      shown as estimates.
    */
    public var ballSpeedEstimate: Double?
    public var carryDistanceEstimate: Double?
    public var launchAngleEstimate: Double?
    public var spinRateEstimate: Int?

    public var drillDone: Bool
    public var videoDropped: Bool

    public init(
        id: String,
        createdAt: Date,
        day: String,
        club: String,
        note: String = "",
        source: String = "capture",
        timeBase: String = "video",
        clipStart: Double? = nil,
        favourite: Bool = false,
        analysed: Bool = false,
        confidence: Double = 0,
        failure: String? = nil,
        scores: Scores? = nil,
        diagnosis: DiagnosisResult? = nil,
        phases: PhaseSummary? = nil,
        sequence: SequenceSummary? = nil,
        view: String? = nil,
        validity: ValidityResult? = nil,
        drillDone: Bool = false,
        videoDropped: Bool = false,
        ballSpeedEstimate: Double? = nil,
        carryDistanceEstimate: Double? = nil,
        launchAngleEstimate: Double? = nil,
        spinRateEstimate: Int? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.day = day
        self.club = club
        self.note = note
        self.source = source
        self.timeBase = timeBase
        self.clipStart = clipStart
        self.favourite = favourite
        self.analysed = analysed
        self.confidence = confidence
        self.failure = failure
        self.scores = scores
        self.diagnosis = diagnosis
        self.phases = phases
        self.sequence = sequence
        self.view = view
        self.validity = validity
        self.drillDone = drillDone
        self.videoDropped = videoDropped
        self.ballSpeedEstimate = ballSpeedEstimate
        self.carryDistanceEstimate = carryDistanceEstimate
        self.launchAngleEstimate = launchAngleEstimate
        self.spinRateEstimate = spinRateEstimate
    }
}

// MARK: - Trend

public struct TrendPoint: Identifiable, Hashable {
    public var id: String { day }
    public var day: String
    /* Earliest swing on that day, which is what the points are ordered by. */
    public var at: Date
    public var count: Int
    public var overall: Int
    public var categories: [String: Int]

    public init(day: String, at: Date, count: Int, overall: Int, categories: [String: Int]) {
        self.day = day
        self.at = at
        self.count = count
        self.overall = overall
        self.categories = categories
    }

    /* The chart switches between overall and the four categories using the
       same key the change dictionary is keyed by. */
    public func value(for series: String) -> Int {
        series == "overall" ? overall : (categories[series] ?? 0)
    }
}

public struct Trend: Hashable {
    public var points: [TrendPoint]
    public var days: Int
    public var change: [String: Int]

    public init(points: [TrendPoint], days: Int, change: [String: Int]) {
        self.points = points
        self.days = days
        self.change = change
    }
}

// MARK: - Streak

public struct StreakSummary: Hashable {
    public var current: Int
    public var longest: Int

    public init(current: Int, longest: Int) {
        self.current = current
        self.longest = longest
    }

    public var best: Int { longest }

    public static let none = StreakSummary(current: 0, longest: 0)
}

// MARK: - Legacy settings shape

/*
  Kept, not used.

  The live settings model is AppSettings, which mirrors src/storage/settings.js
  default for default. This struct predates it and nothing in the ported files
  references it. It stays only because AnalysisView.swift has not been reviewed
  in this pass and may still name it. Delete it once that file is confirmed
  clear, and delete this comment with it.
*/
public struct Settings: Codable, Hashable {
    public var dominantHand: DominantHand
    public var cameraFacing: String
    public var guideStyle: String
    public var cameraQuality: String
    public var recordMode: String
    public var language: String
    public var onboarded: Bool
    public var theme: String
    public var autoCapture: Bool
    public var captureSound: Bool
    public var mirrorPreview: Bool?

    public init(
        dominantHand: DominantHand = .right,
        cameraFacing: String = "environment",
        guideStyle: String = "faceon",
        cameraQuality: String = "1080p60",
        recordMode: String = "single",
        language: String = "en",
        onboarded: Bool = false,
        theme: String = "dark",
        autoCapture: Bool = true,
        captureSound: Bool = true,
        mirrorPreview: Bool? = nil
    ) {
        self.dominantHand = dominantHand
        self.cameraFacing = cameraFacing
        self.guideStyle = guideStyle
        self.cameraQuality = cameraQuality
        self.recordMode = recordMode
        self.language = language
        self.onboarded = onboarded
        self.theme = theme
        self.autoCapture = autoCapture
        self.captureSound = captureSound
        self.mirrorPreview = mirrorPreview
    }
}
