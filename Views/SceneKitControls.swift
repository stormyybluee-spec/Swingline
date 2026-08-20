//
//  SceneKitControls.swift
//  Swingline
//
//  The camera orbit for the 3D view. Holds yaw, pitch and distance, converts
//  gestures into changes to them, and writes the result onto the camera node.
//
//  WHY A MAIN ACTOR CLASS AND NOT AN ACTOR
//
//  Every method here ends in a mutation of an SCNNode, and SceneKit's scene
//  graph is not safe to mutate off the main thread. An actor would move this
//  work to its own executor and then need a hop back for every write, which
//  turns a gesture handler that already runs on the main thread into a chain of
//  awaits for no isolation benefit. @MainActor is the correct isolation here,
//  and it is what lets a UIGestureRecognizer target these methods directly.
//
//  ONE DELIBERATE DIVERGENCE FROM THE WEB
//
//  Pose3D.jsx orbits the camera around the world origin while aiming it at
//  chest height, which is why the framing there drifts as the pitch changes.
//  This orbits around the aim point instead, so pitching up and down keeps the
//  golfer centred. Cosmetic only, no data implication, but it belongs in
//  BUILD-NOTES.md so the two builds do not look different by accident.
//
//  WHY THE VIEWPORT IS LOCKED BY DEFAULT
//
//  Carried over from the web build, and not a style choice. The 3D panel lives
//  inside a scrolling screen. A pan recogniser that is always live swallows the
//  vertical drag the golfer meant as a scroll, and the page stops moving
//  whenever a finger lands on the panel. Locked by default means a drag scrolls
//  the page, exactly as it does everywhere else, until the golfer explicitly
//  unlocks the panel.
//
//  House rule: no em dashes anywhere.
//

import Foundation
import SceneKit
import UIKit
import simd

@MainActor
public final class SceneKitControls: NSObject {

    // MARK: Tunables, all carried over from Pose3D.jsx

    private enum Limits {
        static let yawPerPoint: Float = 0.008
        static let pitchPerPoint: Float = 0.006
        static let pitchMin: Float = -0.5
        static let pitchMax: Float = 0.9
        /* Distance as a multiple of the golfer's own height, so every swing
           fills the panel by the same amount whoever recorded it. */
        static let restingDistanceInHeights: Float = 1.95
        static let minDistanceInHeights: Float = 1.0
        static let maxDistanceInHeights: Float = 4.0
        /* Aim point, measured up from the ground as a fraction of body height.
           Roughly the sternum, which keeps head and feet both in frame. */
        static let aimHeightFraction: Float = 0.52
        static let defaultYaw: Float = 0.35
        static let defaultPitch: Float = 0.12
        /* Radians per second when the auto orbit is on. One full turn takes
           about twenty five seconds, slow enough to read rather than to watch. */
        static let autoOrbitRate: Float = 0.25
    }

    // MARK: State

    public private(set) var yaw: Float = Limits.defaultYaw
    public private(set) var pitch: Float = Limits.defaultPitch
    public private(set) var distance: Float = 3.3

    /* False means gestures are ignored and the host screen keeps its scroll. */
    public var isUnlocked = false

    private var anchor: SwingAnchor = .fallback
    private var aimPoint = SIMD3<Float>(0, 0, 0)

    private weak var cameraNode: SCNNode?

    /*
      The view to repaint after a camera move.

      With rendersContinuously off, moving the camera does not automatically
      repaint. A pan, a pinch, a reset or an auto orbit tick all change the
      camera and then have to ask for one frame. Weak, because the view owns the
      controls indirectly through the SwiftUI coordinator, not the other way
      round, and a strong reference here would outlive the panel.
    */
    private weak var sceneView: SCNView?

    /* Called by the host once the view exists. */
    public func attachView(_ view: SCNView) {
        sceneView = view
    }

    /* One repaint. Cheap, and a no op when the view is gone. */
    private func requestRedraw() {
        sceneView?.setNeedsDisplay()
    }
    private let aimNode = SCNNode()

    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    public private(set) var isAutoOrbiting = false

    // Gesture bookkeeping.
    private var panStartYaw: Float = 0
    private var panStartPitch: Float = 0
    private var pinchStartDistance: Float = 0

    /*
      Deliberately nonisolated.

      A SwiftUI view holds this in @State, and a @State property initialiser runs
      outside main actor isolation, so a @MainActor init here would be rejected.
      This is safe because it does nothing but give stored properties their
      default values. Everything that touches the scene graph is isolated and
      stays isolated.

      If the build objects to this, the alternative is to hold the controls as an
      optional and build it inside .task on the host view. Recorded here because
      it is one of the more likely first build frictions in this batch.
    */
    public nonisolated override init() {
        super.init()
    }

    // MARK: Wiring

    /*
      Build the camera and hand it back for the caller to add to the scene.

      The aim point is a real node with a look at constraint on the camera rather
      than a matrix built here. SceneKit already solves that correctly, including
      keeping the horizon level, and a hand rolled look at is a well known place
      to get a sign wrong and never notice until the figure is upside down at one
      particular pitch.
    */
    public func makeCameraNode(anchor: SwingAnchor) -> SCNNode {
        /*
          A new anchor means a different swing, so the framing is recomputed. The
          same anchor means the scene was rebuilt underneath us for a cosmetic
          reason, a palette change or a grid toggle, and the golfer's orbit is
          kept.

          Without this split, turning the figure to down the line and then
          switching palette snaps the camera back to the default three quarter
          view, and the golfer loses the angle they were reading. The 3D panel
          exists so they can get to that angle, so throwing it away for a colour
          change is the wrong trade.
        */
        let isNewSwing = self.anchor != anchor
        self.anchor = anchor
        aimPoint = SIMD3(0, anchor.floorY + anchor.bodyHeight * Limits.aimHeightFraction, 0)
        aimNode.simdPosition = aimPoint
        aimNode.name = "camera.aim"

        let camera = SCNCamera()
        camera.fieldOfView = 42
        camera.zNear = 0.05
        camera.zFar = 40
        camera.wantsDepthOfField = false

        let node = SCNNode()
        node.camera = camera
        node.name = "camera"

        let constraint = SCNLookAtConstraint(target: aimNode)
        /* Without this the camera rolls as it orbits and the grid tilts, which
           reads as the ground moving rather than the camera. */
        constraint.isGimbalLockEnabled = true
        node.constraints = [constraint]

        cameraNode = node
        if isNewSwing {
            reset()
        } else {
            place()
        }
        return node
    }

    /*
      The aim node has to be in the scene for the look at constraint to resolve.

      Reparenting rather than a nil check, and this is not defensive coding, it
      is a real bug that was traced rather than guessed at. The host puts an
      .id() on the 3D panel, so changing the palette or toggling the grid builds
      a new SCNScene while this controls object survives, because it lives in
      @State. A nil parent check would leave the aim node attached to the scene
      that was just thrown away, the constraint would target a node outside the
      live graph, and the camera would aim at nothing from the first palette tap
      onward.
    */
    public func attachAimNode(to root: SCNNode) {
        guard aimNode.parent !== root else { return }
        aimNode.removeFromParentNode()
        root.addChildNode(aimNode)
    }

    // MARK: Framing

    public func reset() {
        yaw = Limits.defaultYaw
        pitch = Limits.defaultPitch
        distance = anchor.bodyHeight * Limits.restingDistanceInHeights
        place()
    }

    /* Straight on from the front, the view a face on recording was filmed from. */
    public func faceOn() {
        yaw = 0
        pitch = Limits.defaultPitch
        place()
    }

    /* Ninety degrees round, the down the line view most rotation faults only
       become visible from. This is the reason the 3D panel exists at all. */
    public func downTheLine() {
        yaw = .pi / 2
        pitch = Limits.defaultPitch
        place()
    }

    private func place() {
        guard let cameraNode else { return }
        let clampedPitch = min(max(pitch, Limits.pitchMin), Limits.pitchMax)
        let minDistance = anchor.bodyHeight * Limits.minDistanceInHeights
        let maxDistance = anchor.bodyHeight * Limits.maxDistanceInHeights
        let clampedDistance = min(max(distance, minDistance), maxDistance)
        pitch = clampedPitch
        distance = clampedDistance

        let offset = SIMD3<Float>(
            sin(yaw) * cos(clampedPitch) * clampedDistance,
            sin(clampedPitch) * clampedDistance,
            cos(yaw) * cos(clampedPitch) * clampedDistance
        )

        SCNTransaction.begin()
        /* The camera is driven directly by a finger, so any implicit animation
           here reads as lag rather than as smoothing. */
        SCNTransaction.animationDuration = 0
        cameraNode.simdPosition = aimPoint + offset
        SCNTransaction.commit()

        /* rendersContinuously is off, so ask for the one frame this move needs.
           Without this a pan would move the camera in the scene graph but the
           screen would not update until something else triggered a redraw. */
        requestRedraw()
    }

    // MARK: Gestures

    @objc public func handlePan(_ recogniser: UIPanGestureRecognizer) {
        guard isUnlocked else { return }
        switch recogniser.state {
        case .began:
            stopAutoOrbit()
            panStartYaw = yaw
            panStartPitch = pitch
        case .changed:
            let t = recogniser.translation(in: recogniser.view)
            yaw = panStartYaw - Float(t.x) * Limits.yawPerPoint
            pitch = panStartPitch + Float(t.y) * Limits.pitchPerPoint
            place()
        default:
            break
        }
    }

    @objc public func handlePinch(_ recogniser: UIPinchGestureRecognizer) {
        guard isUnlocked else { return }
        switch recogniser.state {
        case .began:
            stopAutoOrbit()
            pinchStartDistance = distance
        case .changed:
            let s = Float(recogniser.scale)
            guard s > 0.01, s.isFinite else { return }
            distance = pinchStartDistance / s
            place()
        default:
            break
        }
    }

    @objc public func handleDoubleTap(_ recogniser: UITapGestureRecognizer) {
        guard isUnlocked else { return }
        stopAutoOrbit()
        reset()
    }

    // MARK: Auto orbit

    /*
      A slow turn, off by default.

      Worth being explicit about why this does not break the one clock rule that
      PlaybackState.swift sets out. That rule is about data: no overlay may
      animate what it shows, because everything visible has to stay a pure
      function of frameIndex. This moves the camera, not the data. The figure at
      a given frame index is identical whether the camera is turning or still, so
      scrubbing backwards still shows exactly what scrubbing forwards showed.

      It stops the moment a finger touches the panel, because a view that keeps
      moving under a drag fights the person doing the dragging.
    */
    public func setAutoOrbit(_ on: Bool) {
        if on {
            startAutoOrbit()
        } else {
            stopAutoOrbit()
        }
    }

    public func toggleAutoOrbit() {
        setAutoOrbit(!isAutoOrbiting)
    }

    private func startAutoOrbit() {
        guard displayLink == nil else { return }
        isAutoOrbiting = true
        lastTick = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopAutoOrbit() {
        displayLink?.invalidate()
        displayLink = nil
        isAutoOrbiting = false
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastTick, 0), 0.1))
        lastTick = now
        yaw += Limits.autoOrbitRate * dt
        if yaw > .pi * 2 { yaw -= .pi * 2 }
        place()
    }

    /* The host calls this when the panel leaves the screen. A display link with
       a strong target that nobody invalidates is a retain cycle that quietly
       keeps rendering behind a screen the golfer has already left. */
    public func teardown() {
        stopAutoOrbit()
    }
}

// MARK: - Gesture coexistence

/*
  Letting the pan gesture and the enclosing scroll view share a touch.

  With the panel unlocked the pan recogniser should win, otherwise a horizontal
  drag to turn the figure becomes a scroll. With it locked the recogniser is
  disabled outright, so the scroll view never has to compete for the touch.
*/
extension SceneKitControls: UIGestureRecognizerDelegate {

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        /* Pan and pinch on the same panel need to coexist so a two finger
           gesture can turn and zoom at once. */
        true
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        isUnlocked
    }
}
