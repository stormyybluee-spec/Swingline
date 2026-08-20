//
//  SkeletonSettings.swift
//  Swingline
//
//  The skeleton and joints customisation state, ported from the web
//  SkeletonOverlay styling plus the native only per joint panel shown in the
//  reference. One Observable object owns thickness, joint size, the two colour
//  mode, and a per joint set of toggles, and it persists the whole thing to
//  UserDefaults so a golfer's overlay preferences survive a restart.
//
//  Persistence note. @AppStorage cannot store a dictionary of structs, so the
//  model persists itself by encoding to a single JSON blob under one key on
//  every change. That keeps the reactive Observable surface clean while still
//  surviving restarts, and it is cheap because the payload is a handful of bytes.
//
//  A design choice worth stating. The per joint gear popovers in the web build
//  say "Coming with the native app" for line colour and thickness. Those remain
//  future work, so JointSetting carries only what is wired to real drawing
//  today: track, and the two angle readouts. Adding fields it cannot honour yet
//  would be the dead placeholder the brief rules out.
//
//  House rule: no em dashes anywhere.
//

import SwiftUI
import Observation

// MARK: - Colour mode

enum SkeletonColorMode: String, Codable, CaseIterable {
    case dual    // lead side one colour, trail side another
    case single  // one colour for the whole figure
}

// MARK: - Joints

/*
  Every joint the panel exposes. Raw values are stable strings so the persisted
  blob keeps meaning across launches, and each maps to a MediaPipe landmark
  index through `landmark` so the overlays can look it up without a second table.
*/
enum JointKey: String, Codable, CaseIterable, Identifiable {
    case leftShoulder, rightShoulder
    case leftElbow, rightElbow
    case leftWrist, rightWrist
    case leftHip, rightHip
    case leftKnee, rightKnee
    case leftAnkle, rightAnkle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .leftShoulder: return "Left shoulder"
        case .rightShoulder: return "Right shoulder"
        case .leftElbow: return "Left elbow"
        case .rightElbow: return "Right elbow"
        case .leftWrist: return "Left wrist"
        case .rightWrist: return "Right wrist"
        case .leftHip: return "Left hip"
        case .rightHip: return "Right hip"
        case .leftKnee: return "Left knee"
        case .rightKnee: return "Right knee"
        case .leftAnkle: return "Left ankle"
        case .rightAnkle: return "Right ankle"
        }
    }

    // The MediaPipe landmark index this joint tracks.
    var landmark: Int {
        switch self {
        case .leftShoulder: return Landmarks.LEFT_SHOULDER
        case .rightShoulder: return Landmarks.RIGHT_SHOULDER
        case .leftElbow: return Landmarks.LEFT_ELBOW
        case .rightElbow: return Landmarks.RIGHT_ELBOW
        case .leftWrist: return Landmarks.LEFT_WRIST
        case .rightWrist: return Landmarks.RIGHT_WRIST
        case .leftHip: return Landmarks.LEFT_HIP
        case .rightHip: return Landmarks.RIGHT_HIP
        case .leftKnee: return Landmarks.LEFT_KNEE
        case .rightKnee: return Landmarks.RIGHT_KNEE
        case .leftAnkle: return Landmarks.LEFT_ANKLE
        case .rightAnkle: return Landmarks.RIGHT_ANKLE
        }
    }
}

// The joint groups, in the order the sheet lists them.
enum JointGroup: String, CaseIterable, Identifiable {
    case shoulders = "Shoulders"
    case elbows = "Elbows"
    case wrists = "Wrists"
    case hips = "Hips"
    case knees = "Knees"
    case ankles = "Ankles"

    var id: String { rawValue }

    var joints: [JointKey] {
        switch self {
        case .shoulders: return [.leftShoulder, .rightShoulder]
        case .elbows: return [.leftElbow, .rightElbow]
        case .wrists: return [.leftWrist, .rightWrist]
        case .hips: return [.leftHip, .rightHip]
        case .knees: return [.leftKnee, .rightKnee]
        case .ankles: return [.leftAnkle, .rightAnkle]
        }
    }
}

struct JointSetting: Codable, Equatable {
    var track: Bool = false
    var innerAngle: Bool = false
    var outerAngle: Bool = false
}

/*
  How a joint angle is drawn.

  Two parts that toggle independently: the degree figure itself, and an arc
  sweeping between the two segments that meet at the joint. Some golfers want the
  number alone, some want to see the sweep, so neither is forced on the other.
  Colours are hex so they persist as plain text.
*/
struct AngleStyle: Codable, Equatable {
    var showDegrees: Bool = true
    var fontSize: Double = 11
    var fontColorHex: String = "#c8ff4d"

    var showArc: Bool = true
    var arcThickness: Double = 2
    var arcColorHex: String = "#c8ff4d"
    // How far from the joint the arc sweeps, in points.
    var arcRadius: Double = 26

    static let fontSizeRange: ClosedRange<Double> = 8...24
    static let arcThicknessRange: ClosedRange<Double> = 1...5
    static let arcRadiusRange: ClosedRange<Double> = 14...60
}

// MARK: - The model

@Observable
final class SkeletonSettings {

    // Defaults chosen to match the reference sheet: 2.5 thickness, 0.7 joint
    // size, dual colour.
    var thickness: Double = 2.5 { didSet { persist() } }
    var jointSize: Double = 0.7 { didSet { persist() } }
    var colorMode: SkeletonColorMode = .dual { didSet { persist() } }
    var jointSettings: [JointKey: JointSetting] = [:] { didSet { persist() } }

    /*
      Side colours, as hex, so a golfer can pick their own rather than living with
      blue and red. Lead and trail are used in dual mode; single is the one colour
      used when the whole figure is drawn in a single tone.
    */
    var leadColorHex: String = "#4da6ff" { didSet { persist() } }
    var trailColorHex: String = "#ff3b30" { didSet { persist() } }
    var singleColorHex: String = "#c8ff4d" { didSet { persist() } }

    // How the joint angle readouts are drawn.
    var angle: AngleStyle = AngleStyle() { didSet { persist() } }

    // The set of joints the golfer has asked to trace, derived from the map so
    // the overlays can test membership cheaply.
    var trackedJoints: Set<JointKey> {
        Set(jointSettings.filter { $0.value.track }.map(\.key))
    }

    // The bounds the sliders use, kept here so the view and the model agree.
    static let thicknessRange: ClosedRange<Double> = 0...5
    static let jointSizeRange: ClosedRange<Double> = 0...2

    private static let storageKey = "skeletonSettings.v1"

    init() { load() }

    func setting(for joint: JointKey) -> JointSetting {
        jointSettings[joint] ?? JointSetting()
    }

    func binding(for joint: JointKey) -> Binding<JointSetting> {
        Binding(
            get: { [weak self] in self?.jointSettings[joint] ?? JointSetting() },
            set: { [weak self] newValue in self?.jointSettings[joint] = newValue }
        )
    }

    func resetAll() {
        thickness = 2.5
        jointSize = 0.7
        colorMode = .dual
        leadColorHex = "#4da6ff"
        trailColorHex = "#ff3b30"
        singleColorHex = "#c8ff4d"
        angle = AngleStyle()
        jointSettings = [:]
        // The three didSet writes above each persist, which is harmless.
    }

    // MARK: Persistence

    private struct Payload: Codable {
        var thickness: Double
        var jointSize: Double
        var colorMode: SkeletonColorMode
        var jointSettings: [String: JointSetting]
        // Added later, so optional: a payload saved before these existed decodes
        // fine and falls back to the defaults.
        var leadColorHex: String?
        var trailColorHex: String?
        var singleColorHex: String?
        var angle: AngleStyle?
    }

    // Set true while decoding so load does not trigger a save per assignment.
    private var loading = false

    private func persist() {
        guard !loading else { return }
        let payload = Payload(
            thickness: thickness,
            jointSize: jointSize,
            colorMode: colorMode,
            jointSettings: Dictionary(uniqueKeysWithValues: jointSettings.map { ($0.key.rawValue, $0.value) }),
            leadColorHex: leadColorHex,
            trailColorHex: trailColorHex,
            singleColorHex: singleColorHex,
            angle: angle
        )
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func load() {
        guard
            let data = UserDefaults.standard.data(forKey: Self.storageKey),
            let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return }
        loading = true
        thickness = payload.thickness
        jointSize = payload.jointSize
        colorMode = payload.colorMode
        leadColorHex = payload.leadColorHex ?? leadColorHex
        trailColorHex = payload.trailColorHex ?? trailColorHex
        singleColorHex = payload.singleColorHex ?? singleColorHex
        angle = payload.angle ?? angle
        var map: [JointKey: JointSetting] = [:]
        for (raw, value) in payload.jointSettings {
            if let key = JointKey(rawValue: raw) { map[key] = value }
        }
        jointSettings = map
        loading = false
    }
}

