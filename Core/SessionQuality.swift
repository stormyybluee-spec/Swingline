//
//  SessionQuality.swift
//  Swingline
//
//  Per swing confidence and a Z axis reliability flag, plus the data a later UI
//  pass turns into a badge. Deliberately values only, no SwiftUI, so the badge
//  text and colour are decided here and rendered elsewhere.
//
//  It consumes the existing CameraViewKind rather than inventing a second view
//  enum, so it stays in step with the detection the pipeline already does.
//
//  House rule: no em dashes anywhere.
//

import Foundation

public struct SessionQuality: Codable, Hashable {
    var averageConfidence: Double
    var lowConfidence: Bool
    var zAxisDisabled: Bool
    var view: CameraViewKind
    var deviceTier: DeviceTier
    var effectiveFps: Double

    // Below this mean tracked confidence, depth is not trustworthy and the app
    // falls back to 2D estimates.
    static let lowConfidenceThreshold = 0.65

    init(confidences: [Double], view: CameraViewKind, deviceTier: DeviceTier, times: [Double]) {
        self.view = view
        self.deviceTier = deviceTier
        self.effectiveFps = Geometry.effectiveFps(times)

        let valid = confidences.filter { $0 > 0 && $0.isFinite }
        self.averageConfidence = valid.isEmpty ? 0 : valid.reduce(0, +) / Double(valid.count)
        self.lowConfidence = averageConfidence < Self.lowConfidenceThreshold

        // Depth is unreliable when tracking confidence is low, and it is
        // unrecoverable down the line where the swing runs along the camera
        // axis. Either way, Z gated metrics should be withheld.
        self.zAxisDisabled = lowConfidence || view == .downTheLine
    }

    // Data for the UI pass. Nil means show nothing.
    var badgeText: String? {
        if lowConfidence && view == .downTheLine { return "Low light and down the line, using 2D estimates" }
        if lowConfidence { return "Low light, using 2D estimates" }
        if view == .downTheLine { return "Down the line, depth metrics unavailable" }
        return nil
    }

    // RGB in 0...1, or nil to show no colour. The UI pass builds a Color.
    var badgeColorRGB: (red: Double, green: Double, blue: Double)? {
        if lowConfidence { return (1.0, 0.6, 0.0) }   // amber
        if view == .downTheLine { return (0.2, 0.5, 1.0) } // blue
        return nil
    }
}

