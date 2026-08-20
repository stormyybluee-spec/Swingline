//
//  DeviceTier.swift
//  Swingline
//
//  Hardware capability tiering and thermal monitoring, used to set honest
//  expectations about tracking quality.
//
//  The mapping is by generation number, not a hand list of identifiers, for two
//  reasons. The hand list in the original plan was wrong (it called the iPhone
//  14 Pro an A17 Pro and left the real A17 Pro devices unclassified), and a rule
//  keeps working when a new phone ships instead of silently falling to the
//  lowest tier. The rule: iPhone16,x and newer carry an A17 Pro or better, so
//  they are green; iPhone14,x and iPhone15,x are A15 and A16, so yellow;
//  anything older, or a simulator, is red.
//
//  Uses uname rather than UIDevice, so it is safe to call from the analysis
//  pipeline off the main actor, and needs only Foundation.
//
//  House rule: no em dashes anywhere.
//

import Foundation

enum DeviceTier: String, Codable, CaseIterable {
    case green   // A17 Pro and newer, full 60fps 3D tracking
    case yellow  // A15 and A16, 30fps reliable, 60fps may degrade
    case red     // A14 and older, or unknown, limited 3D tracking

    var label: String {
        switch self {
        case .green: return "Full 60fps 3D tracking"
        case .yellow: return "30fps reliable, 60fps may degrade"
        case .red: return "Limited 3D tracking"
        }
    }

    static func detect() -> DeviceTier {
        guard let major = iPhoneMajor(from: deviceModelIdentifier()) else { return .red }
        if major >= 16 { return .green }        // iPhone 15 Pro (A17 Pro) and every later generation
        if major == 14 || major == 15 { return .yellow }  // iPhone 13 and 14 lines, plus 15 and 15 Plus
        return .red
    }

    static func thermalState() -> ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }

    static func isThermallyThrottled() -> Bool {
        let state = thermalState()
        return state == .serious || state == .critical
    }

    // Median gap based frame rate, forwarding to the single implementation in
    // Geometry so there is one definition, not two that can drift.
    static func effectiveFps(from times: [Double]) -> Double {
        Geometry.effectiveFps(times)
    }
}

// The raw hardware string, e.g. "iPhone16,2". uname is thread safe, so unlike
// UIDevice this can be read from the analysis pipeline.
func deviceModelIdentifier() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    let mirror = Mirror(reflecting: systemInfo.machine)
    return mirror.children.reduce(into: "") { identifier, element in
        if let value = element.value as? Int8, value != 0 {
            identifier.append(Character(UnicodeScalar(UInt8(value))))
        }
    }
}

// The generation number from an iPhone identifier, or nil for a simulator or a
// non iPhone device, which are treated conservatively as red.
private func iPhoneMajor(from identifier: String) -> Int? {
    guard identifier.hasPrefix("iPhone") else { return nil }
    let rest = identifier.dropFirst("iPhone".count)
    let majorDigits = rest.prefix { $0.isNumber }
    return Int(majorDigits)
}
