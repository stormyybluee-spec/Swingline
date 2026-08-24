//
//  SceneKitView.swift
//  Swingline
//
//  The SwiftUI surface for the 3D view. Owns an SCNView, builds the scene once,
//  and from then on does exactly one thing per frame: hand the current frame's
//  world landmarks to the rig and the current frame index to the traces.
//
//  THE ONE RULE THIS FILE OBEYS
//
//  frameIndex arrives as a plain Int, not as a reference to PlaybackState.
//  That is deliberate. SwiftUI diffs value types, so passing the integer means
//  updateUIView is called exactly when the frame changes and not on every
//  unrelated redraw of the analysis screen. It also keeps the scene a pure
//  function of one number, which is the property that makes scrubbing backwards
//  look identical to playing forwards.
//
//  WHY THE SCENE IS NEVER REBUILT HERE
//
//  Building the rig means allocating around forty nodes and their geometry.
//  Doing that inside updateUIView would rebuild the figure sixty times a second
//  while the swing plays. So the scene is built once in makeUIView, and a change
//  of swing is handled by the caller putting an .id() on this view so SwiftUI
//  tears the whole thing down and makes a new one. That is the correct seam:
//  cheap changes go through updateUIView, structural ones go through identity.
//
//  RENDER LOOP AND BATTERY
//
//  rendersContinuously is OFF, and the view is repainted on demand instead. The
//  scene only changes on two events: the frame index moves, or the camera moves.
//  apply() calls setNeedsDisplay on the first, SceneKitControls calls it on the
//  second, and preferredFramesPerSecond caps the resulting redraws at sixty a
//  second. This matters most on the record screen, where a sixty times a second
//  idle draw of a static figure would compete with the capture pipeline for the
//  GPU and show up as dropped camera frames. The one thing to remember when
//  editing this file: anything that mutates the scene graph from outside an
//  SCNTransaction animation must ask for a redraw, or it will not appear until
//  the next event does.
//
//  House rule: no em dashes anywhere.
//

import SwiftUI
import SceneKit
import UIKit
import simd

struct SceneKitView: UIViewRepresentable {

    // Data
    let frames: [Frame]
    let frameIndex: Int
    let anchor: SwingAnchor
    let handTrace: WorldFrameSeries?
    let clubTrace: WorldFrameSeries?
    let topFrame: Int?

    // Appearance
    let dominantHand: DominantHand
    let jointColorStyle: JointColorStyle
    var palette: HumanoidPalette = .blockout
    var markerPalette: JointMarkerPalette = .standard
    var showTraces: Bool = true
    var showGrid: Bool = true
    /* Whether the body segments (the connecting lines between joints) are drawn.
       Off leaves the joint markers, so the figure reads as a dot skeleton. Mirrors
       the "Show connecting lines" switch the 2D overlay obeys. */
    var showConnectingLines: Bool = true
    /* Joints whose own connecting lines the golfer switched off, from the
       skeleton sheet. Empty in the common case. */
    var hiddenLineJoints: Set<JointKey> = []

    // Interaction. Owned by the host so its buttons can drive the same object.
    let controls: SceneKitControls
    let isUnlocked: Bool

    // MARK: Coordinator

    @MainActor
    final class Coordinator {
        var rig: HumanoidRig?
        var handTraceNode: SwingTraceNode?
        var clubTraceNode: SwingTraceNode?
        var panGesture: UIPanGestureRecognizer?
        var pinchGesture: UIPinchGestureRecognizer?
        var tapGesture: UITapGestureRecognizer?
        var lastFrameIndex: Int = -1
        var lastConnectingLines: Bool = true
        var lastHiddenJoints: Set<JointKey> = []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: Build

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        let scene = SCNScene()
        view.scene = scene

        /* Transparent, so the panel's own gradient background shows through and
           the 3D view sits inside the app's surface rather than on a black
           rectangle punched into it. */
        view.backgroundColor = .clear
        scene.background.contents = UIColor.clear
        view.antialiasingMode = .multisampling4X
        /* The orbit is ours. SceneKit's built in camera control has different
           limits, different inertia and no lock, and having both live at once
           means two things fighting over one finger. */
        view.allowsCameraControl = false
        /* rendersContinuously is OFF. The scene is static between frame index
           changes and camera moves, so redrawing sixty times a second when
           nothing has changed is wasted GPU and battery, and on the record and
           analysis screens that idle draw competes with the capture pipeline.
           Instead the view is repainted on demand: apply() calls setNeedsDisplay
           when the frame index changes, and SceneKitControls calls it after every
           camera move. See both call sites. */
        view.rendersContinuously = false
        /* Caps the redraw rate so a burst of setNeedsDisplay calls, for instance
           a fast scrub, cannot ask for more than sixty frames a second. */
        view.preferredFramesPerSecond = 60

        let root = scene.rootNode

        // Camera. Give the controls the view first, so any camera move it makes
        // can request the one redraw it needs now that continuous rendering is
        // off.
        controls.attachView(view)
        controls.attachAimNode(to: root)
        root.addChildNode(controls.makeCameraNode(anchor: anchor))

        // Lights.
        Self.addLighting(to: root, anchor: anchor, scene: scene)

        // Grid floor.
        if showGrid {
            root.addChildNode(Self.makeGrid(anchor: anchor))
        }

        // The figure.
        let rig = HumanoidRig(
            anchor: anchor,
            palette: palette,
            markerPalette: markerPalette,
            dominantHand: dominantHand,
            style: jointColorStyle
        )
        root.addChildNode(rig.node)
        // Honour the connecting lines switch from the first paint, so the figure
        // never briefly shows its limbs before the setting is applied.
        rig.setConnectingLinesVisible(showConnectingLines)
        rig.setHiddenLineJoints(hiddenLineJoints)
        context.coordinator.rig = rig
        context.coordinator.lastConnectingLines = showConnectingLines
        context.coordinator.lastHiddenJoints = hiddenLineJoints

        // Traces.
        if showTraces {
            let scale = RigScale(anchor: anchor)
            let hand = SwingTraceNode(
                series: handTrace,
                topFrame: topFrame,
                radius: scale.traceRadius,
                gapped: false,
                showHead: true
            )
            /* The club path is a geometric estimate, not a detection, so it is
               drawn thinner and gapped and carries no head marker. A head marker
               would say "the club head is here", which this cannot know. */
            let club = SwingTraceNode(
                series: clubTrace,
                topFrame: topFrame,
                radius: scale.traceRadius * 0.72,
                gapped: true,
                showHead: false
            )
            root.addChildNode(hand.node)
            root.addChildNode(club.node)
            context.coordinator.handTraceNode = hand
            context.coordinator.clubTraceNode = club
        }

        // Gestures.
        let pan = UIPanGestureRecognizer(target: controls, action: #selector(SceneKitControls.handlePan(_:)))
        let pinch = UIPinchGestureRecognizer(target: controls, action: #selector(SceneKitControls.handlePinch(_:)))
        let tap = UITapGestureRecognizer(target: controls, action: #selector(SceneKitControls.handleDoubleTap(_:)))
        tap.numberOfTapsRequired = 2
        for g in [pan, pinch, tap] as [UIGestureRecognizer] {
            g.delegate = controls
            g.isEnabled = isUnlocked
            view.addGestureRecognizer(g)
        }
        context.coordinator.panGesture = pan
        context.coordinator.pinchGesture = pinch
        context.coordinator.tapGesture = tap

        // First frame, so the panel is never briefly empty.
        apply(context.coordinator, frameIndex: frameIndex, view: view)

        return view
    }

    // MARK: Update

    func updateUIView(_ view: SCNView, context: Context) {
        controls.isUnlocked = isUnlocked
        context.coordinator.panGesture?.isEnabled = isUnlocked
        context.coordinator.pinchGesture?.isEnabled = isUnlocked
        context.coordinator.tapGesture?.isEnabled = isUnlocked

        /* Both of these no op when nothing changed, so calling them on every
           update is free. When the style does change, the markers repaint, so a
           redraw is requested below alongside the frame index case. */
        let styleChanged = context.coordinator.rig?.jointColorStyle != jointColorStyle
        context.coordinator.rig?.setJointColorStyle(jointColorStyle)
        context.coordinator.rig?.setDominantHand(dominantHand)

        /* Hide or show the body segments when the connecting lines switch changes.
           No op when it did not, so calling it on every update is free. */
        var linesChanged = context.coordinator.lastConnectingLines != showConnectingLines
        if linesChanged {
            context.coordinator.rig?.setConnectingLinesVisible(showConnectingLines)
            context.coordinator.lastConnectingLines = showConnectingLines
        }
        /* Per joint line switches. Compared as a set so a change at any one joint
           is caught, and applied before the frame is placed so a newly suppressed
           segment is not shown for one frame first. */
        if context.coordinator.lastHiddenJoints != hiddenLineJoints {
            context.coordinator.rig?.setHiddenLineJoints(hiddenLineJoints)
            context.coordinator.lastHiddenJoints = hiddenLineJoints
            linesChanged = true
        }

        if context.coordinator.lastFrameIndex != frameIndex {
            apply(context.coordinator, frameIndex: frameIndex, view: view)
        } else if styleChanged || linesChanged {
            /* The frame did not move but the marker colours or the body visibility
               did, so one redraw is still needed to show the change. */
            view.setNeedsDisplay()
        }
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        view.rendersContinuously = false
    }

    private func apply(_ coordinator: Coordinator, frameIndex: Int, view: SCNView) {
        coordinator.lastFrameIndex = frameIndex
        let world = frames.indices.contains(frameIndex) ? frames[frameIndex].world : nil
        coordinator.rig?.apply(world: world)
        coordinator.handTraceNode?.apply(frameIndex: frameIndex)
        coordinator.clubTraceNode?.apply(frameIndex: frameIndex)
        /* The scene graph just changed, and continuous rendering is off, so ask
           for the one frame that shows it. This is the frame index half of the
           on demand redraw; the camera half lives in SceneKitControls. */
        view.setNeedsDisplay()
    }

    // MARK: Lighting

    /*
      Four lights, matching the intent of the web scene.

      A key from the front and above so the form reads, a cool fill from the
      opposite side so the shadowed half does not go to black, a rim from behind
      to separate the figure from the background, and an ambient floor so nothing
      is ever unlit. Directional lights aim along their node's negative z axis,
      so each one is constrained to look at the body rather than having its euler
      angles worked out by hand.

      Intensities are in lumens and are tuned for physicallyBased materials. If
      the figure comes out too dark or too washed out on device, these and the
      lightingEnvironment intensity below are the two knobs, in that order.
    */
    private static func addLighting(to root: SCNNode, anchor: SwingAnchor, scene: SCNScene) {
        let aim = SCNNode()
        aim.simdPosition = SIMD3(0, anchor.floorY + anchor.bodyHeight * 0.5, 0)
        aim.name = "light.aim"
        root.addChildNode(aim)

        func directional(_ colour: UIColor, _ intensity: CGFloat, at position: SIMD3<Float>) -> SCNNode {
            let light = SCNLight()
            light.type = .directional
            light.color = colour
            light.intensity = intensity
            light.castsShadow = false
            let node = SCNNode()
            node.light = light
            node.simdPosition = position * anchor.bodyHeight
            let look = SCNLookAtConstraint(target: aim)
            look.isGimbalLockEnabled = true
            node.constraints = [look]
            return node
        }

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = UIColor(red: 0.87, green: 0.95, blue: 0.90, alpha: 1)
        ambient.intensity = 340
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        root.addChildNode(ambientNode)

        root.addChildNode(directional(.white, 780, at: SIMD3(1.4, 2.0, 1.15)))
        root.addChildNode(directional(UIColor(red: 0.62, green: 0.85, blue: 1.0, alpha: 1), 340, at: SIMD3(-1.7, 0.8, 0.85)))
        root.addChildNode(directional(UIColor(red: 0.78, green: 1.0, blue: 0.30, alpha: 1), 460, at: SIMD3(-0.6, 1.15, -2.0)))

        /* physicallyBased materials want something to reflect. With no HDR cube
           map in the bundle a flat colour is the honest substitute: it lifts the
           diffuse response without pretending to be a real environment. Swap in
           a real cube map here if the figure ever needs to look photographic. */
        scene.lightingEnvironment.contents = UIColor(red: 0.20, green: 0.28, blue: 0.24, alpha: 1)
        scene.lightingEnvironment.intensity = 1.4
    }

    // MARK: Grid floor

    /*
      A dark, subtle grid at the golfer's own ground level.

      Three metres across in twelve divisions, the same as the web GridHelper,
      with the two centre lines picked out in the brand green so there is a
      visible target line and a visible stance line to read the figure against.

      Built from thin boxes rather than from a line geometry because SceneKit's
      line primitive renders one pixel wide with no control over thickness, which
      on a modern display is almost invisible. The whole grid is flattened into a
      single node afterwards, so twenty six boxes cost one draw call, not twenty
      six.
    */
    private static func makeGrid(anchor: SwingAnchor) -> SCNNode {
        let extent: CGFloat = 3.0
        let divisions = 12
        let step = extent / CGFloat(divisions)
        let thickness: CGFloat = 0.006

        let minor = SCNMaterial()
        minor.lightingModel = .constant
        minor.diffuse.contents = UIColor(red: 0.09, green: 0.157, blue: 0.114, alpha: 1)
        minor.transparency = 0.85
        minor.writesToDepthBuffer = false

        let major = SCNMaterial()
        major.lightingModel = .constant
        major.diffuse.contents = UIColor(red: 0.247, green: 0.851, blue: 0.549, alpha: 1)
        major.transparency = 0.35
        major.writesToDepthBuffer = false

        let container = SCNNode()
        container.name = "grid"

        for i in 0...divisions {
            let offset = -extent / 2 + step * CGFloat(i)
            let isCentre = i == divisions / 2
            let material = isCentre ? major : minor

            /* offset is CGFloat, so it is narrowed to Float here. SCNVector3
               has Float, Double and CGFloat initialisers, and passing a CGFloat
               alongside bare 0 literals leaves the type checker unable to pick
               one, which is a build error rather than a runtime one. An explicit
               Float and Float zeros resolve it unambiguously. */
            let axisOffset = Float(offset)

            let alongZ = SCNBox(width: thickness, height: thickness, length: extent, chamferRadius: 0)
            alongZ.firstMaterial = material
            let zNode = SCNNode(geometry: alongZ)
            zNode.simdPosition = SIMD3<Float>(axisOffset, 0, 0)
            container.addChildNode(zNode)

            let alongX = SCNBox(width: extent, height: thickness, length: thickness, chamferRadius: 0)
            alongX.firstMaterial = material
            let xNode = SCNNode(geometry: alongX)
            xNode.simdPosition = SIMD3<Float>(0, 0, axisOffset)
            container.addChildNode(xNode)
        }

        let flattened = container.flattenedClone()
        flattened.name = "grid"
        /* The grid sits at the lowest foot position over the whole clip, so the
           figure stands on it and stays standing on it, rather than bobbing
           through it frame to frame as the tracker's hip origin shifts. */
        flattened.simdPosition = SIMD3(0, anchor.floorY, 0)
        /* Drawn before the body so a translucent inferred foot never blends with
           a grid line showing through it. */
        flattened.renderingOrder = -10
        return flattened
    }
}

