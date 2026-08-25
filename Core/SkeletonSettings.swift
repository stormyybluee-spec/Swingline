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
//  say "Coming with the native app" for line colour and thickness. Per joint line
//  colour remains future work, so JointSetting carries only what is wired to real
//  drawing today: track, the two angle readouts, and whether this joint's bones
//  are drawn. Adding fields it cannot honour yet would be the dead placeholder the
//  brief rules out.
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

    /*
      The joint that owns a landmark index, or nil when no row on the sheet
      governs it.

      The reverse of `landmark`, built once as a dictionary rather than searched
      per call, because the overlay asks this for both endpoints of every bone on
      every frame. Landmarks with no row (the nose, the finger tips, the heels and
      the toes) return nil and are left to whichever joint their limb hangs from,
      so turning the ankle off takes the whole foot with it.
    */
    static func owning(landmark index: Int) -> JointKey? {
        byLandmark[index]
    }

    private static let byLandmark: [Int: JointKey] = {
        var map: [Int: JointKey] = [:]
        for key in JointKey.allCases { map[key.landmark] = key }
        return map
    }()

    // True when this joint sits on the golfer's left, from the case itself
    // rather than from a landmark index, so the 3D rig can ask directly.
    var isLeft: Bool {
        switch self {
        case .leftShoulder, .leftElbow, .leftWrist, .leftHip, .leftKnee, .leftAnkle:
            return true
        default:
            return false
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
    /*
      Whether the bones meeting at this joint are drawn. On by default, so a
      golfer who never opens the sheet sees the full figure. Off drops just this
      joint's connecting lines and leaves its dot, which is what makes it useful:
      hide the legs and keep the arms, or strip everything back to the one limb
      being worked on. Sits alongside the global showConnectingLines switch, which
      still wins when it is off.
    */
    var showLine: Bool = true

    init(track: Bool = false, innerAngle: Bool = false, outerAngle: Bool = false, showLine: Bool = true) {
        self.track = track
        self.innerAngle = innerAngle
        self.outerAngle = outerAngle
        self.showLine = showLine
    }

    /*
      Decoded by hand rather than by the synthesised initialiser.

      showLine was added after golfers already had settings on disk, and a
      synthesised decoder treats a missing key as an error, which would throw the
      whole payload away and silently reset every joint. decodeIfPresent defaults
      it to true instead, so an older blob loads with the lines on, which is the
      figure that golfer last saw.
    */
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        track = try c.decodeIfPresent(Bool.self, forKey: .track) ?? false
        innerAngle = try c.decodeIfPresent(Bool.self, forKey: .innerAngle) ?? false
        outerAngle = try c.decodeIfPresent(Bool.self, forKey: .outerAngle) ?? false
        showLine = try c.decodeIfPresent(Bool.self, forKey: .showLine) ?? true
    }
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
    // 14 rather than 11: the readout is outlined and drawn over video, where an
    // 11 point figure is legible only on a still. This is the size the reference
    // readouts sit at.
    var fontSize: Double = 14
    var fontColorHex: String = "#c8ff4d"

    var showArc: Bool = true
    var arcThickness: Double = 2
    var arcColorHex: String = "#c8ff4d"
    /*
      How far from the joint the arc sweeps, in points. A request rather than a
      command: the overlay caps it to half the shorter limb meeting at the joint,
      so a large setting cannot spill an ankle's arc past the knee.
    */
    var arcRadius: Double = 28

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
      Whether the skeleton draws the bones between joints. On by default, which is
      the figure everyone expects. Off leaves the joint dots and their angle
      readouts in place but drops the connecting lines, the spine and the foot
      triangles in 2D, and the body segments in 3D, so a golfer who only wants to
      read joint positions gets a clean dot skeleton.
    */
    var showConnectingLines: Bool = true { didSet { persist() } }

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

    /*
      The joints whose connecting lines are switched off.

      Stored the other way round from the toggle (a joint absent from the map is
      on), so this collects the explicit offs. Empty in the common case, which
      makes the overlay's per bone test a lookup in an empty set. The global
      showConnectingLines switch is separate and still wins when it is off.
    */
    var hiddenLineJoints: Set<JointKey> {
        Set(jointSettings.filter { !$0.value.showLine }.map(\.key))
    }

    /*
      Whether the bone between two landmarks should be drawn.

      A bone is hidden when either end sits on a joint the golfer switched off.
      Landmarks with no row of their own (finger tips, heels, toes) never veto,
      so they follow the joint their limb hangs from: switching the ankle off
      takes the ankle to heel and heel to toe lines with it.
    */
    func drawsLine(from a: Int, to b: Int) -> Bool {
        guard showConnectingLines else { return false }
        for end in [a, b] {
            if let key = JointKey.owning(landmark: end), !setting(for: key).showLine {
                return false
            }
        }
        return true
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
        showConnectingLines = true
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
        // Added later, so optional: a payload saved before this existed decodes
        // fine and falls back to the default of on.
        var showConnectingLines: Bool?
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
            angle: angle,
            showConnectingLines: showConnectingLines
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
        showConnectingLines = payload.showConnectingLines ?? showConnectingLines
        var map: [JointKey: JointSetting] = [:]
        for (raw, value) in payload.jointSettings {
            if let key = JointKey(rawValue: raw) { map[key] = value }
        }
        jointSettings = map
        loading = false
    }
}

