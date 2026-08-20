//
//  AppSettings.swift
//  Swingline
//
//  Every default below is copied from src/storage/settings.js DEFAULTS. Do not
//  adjust them without changing the web app too, or the two builds will
//  disagree about what a fresh install looks like.
//
//  Two fields have no web counterpart and are marked as such: height, which the
//  web app never asked for, and updateNotifications, which only means anything
//  for a shipped binary.
//
//  The web app persists the whole settings object as one record in IndexedDB
//  rather than as many keys. This does the same with one JSON blob in
//  UserDefaults, so a future migration or export reads as a single document.
//

import Foundation
import SwiftUI

struct AppSettings: Codable, Equatable {

    // You
    var language: String = Self.detectLanguage()
    var units: String = "metric"
    var dominantHand: String = "right"
    var theme: String = "dark"
    /*
      Native only. The golfer's height, always in centimetres whatever the units
      setting says, so switching units relabels the picker and never rewrites
      the stored number. Nil means not answered, which is not the same as a
      default height: anything reading this must handle nil rather than assume
      an average golfer.
    */
    var height: Double? = nil

    // Camera and tracking
    // Null in the web app means auto. Optional here for the same reason.
    var mirrorPreview: Bool? = nil
    var model: String = "full"
    var overlayStyle: String = "clean"
    // Phase 5: 3D joint marker colouring. "single" is one colour, "dual" splits
    // lead and trail. Read by Skeleton3DSettings when an analysis opens.
    var jointColorStyle: String = "dual"
    var micStrikeDetection: Bool = false

    // Notifications and feedback
    var notifyStreak: Bool = true
    var notifyDrill: Bool = true
    var soundEffects: Bool = true
    var captureSound: Bool = true
    var injuryNudges: Bool = true
    var playIntro: Bool = true
    // Native only. In-app notices when a new version is on the App Store. On by
    // default, and one tap to turn off, because it is a courtesy rather than
    // something the app needs.
    var updateNotifications: Bool = true

    // Capture
    var autoCapture: Bool = true
    var recordMode: String = "single"
    var cameraQuality: String = "1080p60"
    var maxRecordSeconds: Int = 10
    // Club the golfer is hitting, a user choice, never detected from pose. Drives
    // the ball flight estimates, which are club average models. Chosen on the
    // Record screen, not in Settings.
    var selectedClub: String = "driver"
    // Manual exposure, a capture control. Off means the camera auto exposes.
    // A fast shutter cuts the motion blur that smears a fast clubhead.
    var manualExposureEnabled: Bool = false
    /*
      The metrics on the bar, in the order the golfer arranged them. Ordered, not
      a set, because the order is the point. The four lead cards (tempo,
      backswing, downswing, score) are not stored here: they are always shown
      first and cannot be removed, so they never need persisting.
    */
    var metricOrder: [String] = SwingMetrics.defaults
    /*
      The two customisable metric pages, each its own ordered list. The eight
      Always First cards are fixed and not stored here. Bar 1 seeds from the old
      single order so an upgrade keeps the golfer's picks; bar 2 starts empty.
    */
    var metricOrderBar1: [String] = SwingMetrics.defaultBar1
    var metricOrderBar2: [String] = []
    var exposureDurationDenominator: Int = 2000
    var exposureISO: Float = 200.0
    var cameraFacing: String = "environment"
    var guideStyle: String = "faceon"

    // Ball flight
    // The Settings screen no longer exposes these four. They are still read by
    // the ball flight overlay, and still shared with the web app, so they stay.
    var ballColor: String = "#ffd60a"
    var ballWidth: Double = 3.5
    var ballFontSize: Int = 18
    var ballUnit: String = "percent"

    // Flags
    var betaFounder: Bool = false
    var seenRecordTips: Bool = false
    var onboarded: Bool = false

    static func detectLanguage() -> String {
        let supported = Language.all.map(\.code)
        for code in Locale.preferredLanguages {
            let base = String(code.prefix(2))
            if supported.contains(base) { return base }
        }
        return "en"
    }
}

// MARK: - Forgiving decode

/*
  Settings live in UserDefaults as one JSON document, so a blob written by an
  older build is simply missing any key added since. Synthesised decoding treats
  a missing non optional key as an error, which throws the entire document away
  and silently resets every choice the golfer had made, on upgrade, for the sake
  of one new field. This starts from the defaults and overlays whatever the
  stored document actually contains, so adding a field costs nothing.

  It lives in an extension rather than in the type body so the memberwise
  initialiser survives.
*/
extension AppSettings {
    init(from decoder: Decoder) throws {
        self.init()

        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return }

        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }

        language = read(.language, language)
        units = read(.units, units)
        dominantHand = read(.dominantHand, dominantHand)
        theme = read(.theme, theme)
        height = (try? container.decodeIfPresent(Double.self, forKey: .height)) ?? nil

        mirrorPreview = (try? container.decodeIfPresent(Bool.self, forKey: .mirrorPreview)) ?? nil
        model = read(.model, model)
        overlayStyle = read(.overlayStyle, overlayStyle)
        jointColorStyle = read(.jointColorStyle, jointColorStyle)
        micStrikeDetection = read(.micStrikeDetection, micStrikeDetection)

        notifyStreak = read(.notifyStreak, notifyStreak)
        notifyDrill = read(.notifyDrill, notifyDrill)
        soundEffects = read(.soundEffects, soundEffects)
        captureSound = read(.captureSound, captureSound)
        injuryNudges = read(.injuryNudges, injuryNudges)
        playIntro = read(.playIntro, playIntro)
        updateNotifications = read(.updateNotifications, updateNotifications)

        autoCapture = read(.autoCapture, autoCapture)
        recordMode = read(.recordMode, recordMode)
        cameraQuality = read(.cameraQuality, cameraQuality)
        maxRecordSeconds = read(.maxRecordSeconds, maxRecordSeconds)
        selectedClub = read(.selectedClub, selectedClub)
        manualExposureEnabled = read(.manualExposureEnabled, manualExposureEnabled)
        metricOrder = read(.metricOrder, metricOrder)
        metricOrderBar1 = read(.metricOrderBar1, metricOrderBar1)
        metricOrderBar2 = read(.metricOrderBar2, metricOrderBar2)
        exposureDurationDenominator = read(.exposureDurationDenominator, exposureDurationDenominator)
        exposureISO = read(.exposureISO, exposureISO)
        cameraFacing = read(.cameraFacing, cameraFacing)
        guideStyle = read(.guideStyle, guideStyle)

        ballColor = read(.ballColor, ballColor)
        ballWidth = read(.ballWidth, ballWidth)
        ballFontSize = read(.ballFontSize, ballFontSize)
        ballUnit = read(.ballUnit, ballUnit)

        betaFounder = read(.betaFounder, betaFounder)
        seenRecordTips = read(.seenRecordTips, seenRecordTips)
        onboarded = read(.onboarded, onboarded)
    }
}

// MARK: - Option lists

struct Option: Identifiable, Hashable {
    var value: String
    var label: String
    var note: String = ""
    var id: String { value }
}

enum SettingsOptions {

    // src/storage/settings.js UNITS
    static let units = [
        Option(value: "metric", label: "Metres and centimetres"),
        Option(value: "imperial", label: "Yards and inches"),
    ]

    // src/storage/settings.js HANDS
    static let hands = [
        Option(value: "right", label: "Right handed"),
        Option(value: "left", label: "Left handed"),
    ]

    // src/engine/poseEngine.js MODELS. Label and note are joined the same way
    // the web Settings screen joins them: "Fast, best on older phones".
    static let models = [
        Option(value: "lite", label: "Fast", note: "Best on older phones"),
        Option(value: "full", label: "Balanced", note: "Recommended"),
        Option(value: "heavy", label: "Most accurate", note: "Needs a recent device"),
    ]

    // src/storage/settings.js OVERLAY_STYLES
    static let overlayStyles = [
        Option(value: "clean", label: "Clean", note: "Thin lines, minimal joints"),
        Option(value: "broadcast", label: "Broadcast", note: "Heavier lines, labelled angles"),
        Option(value: "ghost", label: "Ghost", note: "Translucent, built for comparison"),
    ]

    static let ballColours = [
        Option(value: "#4da6ff", label: "Blue"),
        Option(value: "#ff453a", label: "Red"),
        Option(value: "#ffd60a", label: "Yellow"),
        Option(value: "#ffffff", label: "White"),
    ]

    static let ballTextSizes = [
        Option(value: "14", label: "Small"),
        Option(value: "18", label: "Medium"),
        Option(value: "24", label: "Large"),
    ]

    static let ballUnits = [
        Option(value: "percent", label: "Flight %"),
        Option(value: "yd", label: "Yards (rough)"),
        Option(value: "m", label: "Metres (rough)"),
    ]

    static let recordLengths = [
        Option(value: "6", label: "6 seconds"),
        Option(value: "10", label: "10 seconds, recommended"),
        Option(value: "15", label: "15 seconds"),
    ]

    // Phase 5: front or rear. Values match the web app's cameraFacing strings
    // ("environment" is the rear camera, "user" is the front).
    static let cameraFacings = [
        Option(value: "environment", label: "Rear camera"),
        Option(value: "user", label: "Front camera"),
    ]

    static let clubs = ClubType.allCases.map { Option(value: $0.rawValue, label: $0.label) }

    // Phase 5: resolution and frame rate. High frame rate is the real advantage
    // of the native build. Availability is hardware dependent; CaptureViewModel
    // falls back to the closest supported format rather than failing.
    static let cameraQualities = [
        Option(value: "720p60", label: "720p", note: "60fps, best on older phones"),
        Option(value: "1080p60", label: "1080p", note: "60fps, recommended"),
        Option(value: "1080p120", label: "1080p", note: "120fps, slow motion"),
        Option(value: "1080p240", label: "1080p", note: "240fps, needs a recent device"),
    ]

    // Phase 5: single colour markers, or lead and trail split. Values match
    // JointColorStyle.rawValue so the string maps straight onto the enum.
    static let jointStyles = [
        Option(value: "single", label: "One colour"),
        Option(value: "dual", label: "Lead and trail"),
    ]

    // Joined label, matching how the web app renders a model or overlay choice.
    static func joined(_ option: Option) -> String {
        option.note.isEmpty ? option.label : "\(option.label), \(option.note.lowercased())"
    }
}

// MARK: - Languages

struct Language: Identifiable, Hashable {
    var code: String
    var label: String
    var native: String
    var isRightToLeft: Bool = false
    var id: String { code }
}

extension Language {
    // src/lib/i18n.js LANGUAGES, in the same order.
    // Two of these are right to left. Any screen that hard codes a leading or
    // trailing edge needs to respect layoutDirection, or Arabic and Urdu will
    // read as broken rather than as translated.
    static let all: [Language] = [
        Language(code: "en", label: "English", native: "English"),
        Language(code: "zh", label: "Chinese", native: "\u{4E2D}\u{6587}"),
        Language(code: "hi", label: "Hindi", native: "\u{939}\u{93F}\u{928}\u{94D}\u{926}\u{940}"),
        Language(code: "es", label: "Spanish", native: "Espa\u{F1}ol"),
        Language(code: "fr", label: "French", native: "Fran\u{E7}ais"),
        Language(code: "ar", label: "Arabic", native: "\u{627}\u{644}\u{639}\u{631}\u{628}\u{64A}\u{629}", isRightToLeft: true),
        Language(code: "bn", label: "Bengali", native: "\u{9AC}\u{9BE}\u{982}\u{9B2}\u{9BE}"),
        Language(code: "pt", label: "Portuguese", native: "Portugu\u{EA}s"),
        Language(code: "ru", label: "Russian", native: "\u{420}\u{443}\u{441}\u{441}\u{43A}\u{438}\u{439}"),
        Language(code: "ur", label: "Urdu", native: "\u{627}\u{631}\u{62F}\u{648}", isRightToLeft: true),
    ]
}
