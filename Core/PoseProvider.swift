//
//  PoseProvider.swift
//  Swingline
//
//  The protocol both pose backends conform to: MediaPipePoseProvider for the
//  web/upload path and VisionPoseProvider for the iOS live capture path.
//  CaptureViewModel holds `any PoseProvider` and calls detect/close without
//  knowing which backend is behind it.
//
//  House rule: no em dashes anywhere.
//

import Foundation
import CoreMedia

// MARK: - Pose provider protocol

public protocol PoseProvider: AnyObject {
    var maxPeople: Int { get }
    func detect(frame: CMSampleBuffer, timestampMs: Double) async throws -> [PersonDetection]
    func close()
}

// MARK: - Provider options

public struct PoseProviderOptions {
    public init() {}
}
