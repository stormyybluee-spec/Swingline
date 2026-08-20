import Foundation
import CoreMedia

// Mirrors packages/ports/src/PoseProvider.ts exactly in shape. See
// VisionPoseProvider.swift for the real implementation and, importantly,
// for an open question this protocol cannot resolve by itself: whether
// Vision's 3D body pose request can return more than one candidate person
// per frame the way MediaPipe does. If it cannot, maxPeople on iOS is
// always 1 and golferSelect.ts's whole multi-candidate selection strategy
// has nothing to select among once it is ported. That is a real
// architectural gap, not a detail, and it is flagged where the
// implementation lives rather than buried here.
//
// TFrame is generic in the TypeScript version because the web adapter
// consumes an HTMLVideoElement and ports.ts deliberately does not assume
// that shape is universal. Swift has no equivalent way to leave that open
// without an associated type, and an associated type would make this
// protocol unusable as an existential (no `any PoseProvider` variable),
// which the app needs for dependency injection into SwiftUI views. So this
// is written directly against CMSampleBuffer, the shape AVFoundation
// actually delivers from both a live camera feed and an AVAssetReader
// backed video import. If a second iOS frame source with a genuinely
// different shape shows up later, it should get its own protocol rather
// than forcing this one to generalise for a case that does not exist yet.
public protocol PoseProvider {
    /// Run detection on one frame at one timestamp.
    ///
    /// timestampMs must strictly increase across calls on the same provider
    /// instance, matching the TypeScript contract exactly, even though
    /// Vision itself does not require this the way MediaPipe's video mode
    /// does. Keeping the contract identical means a caller never needs to
    /// know which implementation it is talking to.
    ///
    /// Returns an empty array, never nil, when nobody was found in the
    /// frame. An empty array is a normal outcome, not a failure.
    func detect(frame: CMSampleBuffer, timestampMs: Double) async throws -> [PersonDetection]

    /// How many candidate people this provider is configured to return per
    /// frame. Read only, set at construction. Mirrors numPoses in the web
    /// poseEngine.js, currently 3 there. See the note above and in
    /// VisionPoseProvider.swift about whether this can honestly be
    /// anything above 1 on the Vision backed implementation today.
    var maxPeople: Int { get }

    /// Release whatever Vision request handler or session backs this
    /// provider. Safe to call more than once.
    func close()
}

// What a caller asks for when it builds a provider. model is a loose
// string rather than a shared enum on purpose. The web build chooses
// between MediaPipe's lite, full and heavy model bundles. Vision on iOS has
// no equivalent concept, its accuracy is closer to a fixed cost of running
// on the Neural Engine, so each platform's factory is free to define and
// validate its own values rather than forcing one enum to cover both.
public struct PoseProviderOptions {
    public var maxPeople: Int
    public var minDetectionConfidence: Double

    public init(maxPeople: Int = 3, minDetectionConfidence: Double = 0.5) {
        self.maxPeople = maxPeople
        self.minDetectionConfidence = minDetectionConfidence
    }
}
