//
//  HumanoidLoader.swift
//  Swingline
//
//  The segmented humanoid rig for the 3D view, built entirely from SceneKit
//  primitives. No external model file, no rigging, no skinning. Every part is a
//  cone, a sphere, a cylinder or a chamfered box, positioned and oriented from
//  the stored world landmarks each frame.
//
//  WHY PRIMITIVES RATHER THAN A MODEL FILE
//
//  A skinned character would need a bind pose, a bone hierarchy and a retarget
//  from thirteen tracked points onto a rig that expects far more. Every one of
//  those steps is a place to invent motion the golfer never made. Primitives
//  placed directly between two measured points cannot drift from the data,
//  because there is no intermediate representation to drift through.
//
//  WHAT THE WEB BUILD DECIDED, AND WHY THIS DIVERGES
//
//  src/components/Pose3D.jsx contains a solid rig that was built and then
//  switched off. The reason is recorded in that file: watched against a real
//  swing it drew limbs that were not there and joints bent at angles the golfer
//  had not reached, and a single camera cannot resolve depth well enough for a
//  solid body to be a measurement. Wire is the only mode the web app ships.
//
//  This file deliberately builds the solid figure the web app rejected, because
//  it was asked for. Three guards carry the web build's concern across rather
//  than discarding it:
//
//    1. A segment whose endpoints fall below the confidence floor is hidden,
//       never drawn to a guessed position. The figure loses an arm rather than
//       inventing one. Same floor the 2D overlay uses, 0.35.
//    2. Parts that are inferred rather than tracked, the hands and the feet,
//       render at reduced opacity so they read as sketch rather than as
//       measurement.
//    3. The host panel carries a SKETCH badge. See AnalysisView.
//
//  This belongs in BUILD-NOTES.md as a deliberate divergence, not a silent one.
//
//  WHAT VISION ACTUALLY GIVES THIS FILE
//
//  Thirteen joints. Read VisionPoseProvider.swift: head centre, both shoulders,
//  elbows, wrists, hips, knees and ankles. There are no heels, no foot indices,
//  no hand points and no face points, and those slots arrive as visibility zero
//  placeholders. So:
//
//    neck, chest, abdomen, pelvis   derived from shoulder and hip midpoints,
//                                   which is geometry, not invention
//    hands, feet                    inferred from the segment pointing into
//                                   them, drawn faded, honestly stylised
//
//  COORDINATE CONVENTION, DETECTED RATHER THAN ASSUMED
//
//  The web engine runs on MediaPipe world landmarks, where y increases
//  downward, which is why Pose3D.jsx negates y on every point. Apple's Vision
//  3D pose is documented with y increasing upward. Rather than hard code a sign
//  that is right for one backend and silently upside down for the other, the
//  anchor measures it: whichever of the head and the ankles sits at the larger
//  y over the whole clip tells us which way down is. See SwingAnchor.
//
//  A NOTE ON WHAT THE 3D VIEW CANNOT SHOW
//
//  World landmarks are hip relative, so the hip centre is the origin on every
//  frame. The figure rotates and the limbs move, but the body never translates.
//  Pelvis sway is therefore invisible here by construction, in this build and in
//  the web build equally. The metrics bar is where sway is read, not this panel.
//
//  House rule: no em dashes anywhere.
//

import Foundation
import SceneKit
import UIKit
import simd

// MARK: - Joint marker styling

/*
  How the joint markers are coloured.

  single  every marker one colour, which reads as a neutral marker set and does
          not imply anything about which side is which
  dual    lead side one colour, trail side another, which is the convention the
          reference apps use and the fastest thing to read at a glance

  Lead and trail are resolved from AppSettings.dominantHand through
  Landmarks.sides, so a left handed golfer is a settings change and not a second
  code path. Note that the web Pose3D.jsx hard codes left as blue and right as
  red, which is only correct for a right handed golfer. That is a web side bug
  and belongs in BUILD-NOTES.md rather than being copied here.
*/
public enum JointColorStyle: String, CaseIterable, Codable, Hashable {
    case single
    case dual

    public var label: String {
        switch self {
        case .single: return "Single"
        case .dual: return "Lead and trail"
        }
    }
}

/*
  Marker colours.

  The defaults are the same values the rest of the app already uses, so a golfer
  who has learned that blue is the backswing and red is the downswing on the 2D
  trace reads the same blue and red as lead and trail here.

    single    #FFE14D, identical to the joint colour in SkeletonOverlay.swift
    lead      #4DA6FF, identical to the backswing colour in TraceOverlay.swift
    trail     #FF3B30, identical to the downswing colour in TraceOverlay.swift
    neutral   #F0EADC, the bone token, used for the head in dual mode because
              the head has no side and colouring it either way would be a lie
*/
public struct JointMarkerPalette: Equatable {
    public var single: UIColor
    public var lead: UIColor
    public var trail: UIColor
    public var neutral: UIColor
    /* Marker radius as a fraction of shoulder span, so a tall golfer and a
       short one get markers that read the same size against their own body. */
    public var radiusInShoulders: CGFloat

    public init(
        single: UIColor = UIColor(red: 1.00, green: 0.882, blue: 0.302, alpha: 1),
        lead: UIColor = UIColor(red: 0.302, green: 0.651, blue: 1.00, alpha: 1),
        trail: UIColor = UIColor(red: 1.00, green: 0.231, blue: 0.188, alpha: 1),
        neutral: UIColor = UIColor(red: 0.941, green: 0.918, blue: 0.863, alpha: 1),
        radiusInShoulders: CGFloat = 0.088
    ) {
        self.single = single
        self.lead = lead
        self.trail = trail
        self.neutral = neutral
        self.radiusInShoulders = radiusInShoulders
    }

    public static let standard = JointMarkerPalette()
}

// MARK: - Body palette

/*
  The colour blocked body.

  Sampled from the anatomy blockout reference: pastel, low saturation, matte.
  Each anatomical block gets its own flat colour so the form reads as segments
  rather than as one extruded mass, which is the whole point of the style. The
  shading comes from the lights, not from the texture, so there is nothing to
  author and nothing to load.

  Customisable by construction. Build a palette, hand it to the loader, done.
  When Phase 5 wires this into SettingsView, a colourway is a stored
  HumanoidPalette rather than a branch in this file.
*/
public struct HumanoidPalette: Equatable {
    public var head: UIColor
    public var neck: UIColor
    public var chest: UIColor
    public var abdomen: UIColor
    public var pelvis: UIColor
    public var shoulderCap: UIColor
    public var upperArm: UIColor
    public var elbowCap: UIColor
    public var forearm: UIColor
    public var hand: UIColor
    public var thigh: UIColor
    public var kneeCap: UIColor
    public var shin: UIColor
    public var foot: UIColor

    public init(
        head: UIColor, neck: UIColor, chest: UIColor, abdomen: UIColor,
        pelvis: UIColor, shoulderCap: UIColor, upperArm: UIColor, elbowCap: UIColor,
        forearm: UIColor, hand: UIColor, thigh: UIColor, kneeCap: UIColor,
        shin: UIColor, foot: UIColor
    ) {
        self.head = head
        self.neck = neck
        self.chest = chest
        self.abdomen = abdomen
        self.pelvis = pelvis
        self.shoulderCap = shoulderCap
        self.upperArm = upperArm
        self.elbowCap = elbowCap
        self.forearm = forearm
        self.hand = hand
        self.thigh = thigh
        self.kneeCap = kneeCap
        self.shin = shin
        self.foot = foot
    }

    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> UIColor {
        UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /* The default, matching the anatomy blockout reference. */
    public static let blockout = HumanoidPalette(
        head: rgb(157, 191, 168),
        neck: rgb(212, 201, 176),
        chest: rgb(176, 164, 212),
        abdomen: rgb(212, 168, 188),
        pelvis: rgb(168, 212, 188),
        shoulderCap: rgb(166, 152, 205),
        upperArm: rgb(212, 201, 160),
        elbowCap: rgb(184, 168, 212),
        forearm: rgb(168, 196, 217),
        hand: rgb(169, 214, 165),
        thigh: rgb(212, 201, 160),
        kneeCap: rgb(184, 168, 212),
        shin: rgb(168, 196, 217),
        foot: rgb(224, 201, 188)
    )

    /* Bone and grey, for a golfer who finds the pastel blocks noisy. Still
       segmented, just quieter, so the form still reads without the colour. */
    public static let bone = HumanoidPalette(
        head: rgb(226, 219, 203),
        neck: rgb(198, 192, 178),
        chest: rgb(178, 172, 160),
        abdomen: rgb(198, 192, 178),
        pelvis: rgb(178, 172, 160),
        shoulderCap: rgb(160, 155, 145),
        upperArm: rgb(206, 200, 186),
        elbowCap: rgb(160, 155, 145),
        forearm: rgb(186, 181, 169),
        hand: rgb(214, 208, 194),
        thigh: rgb(206, 200, 186),
        kneeCap: rgb(160, 155, 145),
        shin: rgb(186, 181, 169),
        foot: rgb(214, 208, 194)
    )

    /* One colour everywhere, for reading pure silhouette and nothing else. */
    public static func uniform(_ colour: UIColor) -> HumanoidPalette {
        HumanoidPalette(
            head: colour, neck: colour, chest: colour, abdomen: colour,
            pelvis: colour, shoulderCap: colour, upperArm: colour, elbowCap: colour,
            forearm: colour, hand: colour, thigh: colour, kneeCap: colour,
            shin: colour, foot: colour
        )
    }
}

// MARK: - Clip anchor

/*
  Everything measured once per swing rather than per frame.

  The figure used to float or sink in the web build because the grid sat at a
  fixed height while the tracker's coordinates are centred on the hips, wherever
  those happen to be. Taking the extreme foot position across the whole clip
  gives one ground plane, so the figure stands on it and stays standing on it.

  ySign is the piece that is measured rather than assumed. See the file header.
*/
public struct SwingAnchor: Equatable {
    /* Multiply landmark y by this to get SceneKit y, which points up. */
    public var ySign: Float
    /* Ground level in SceneKit space, already ySign corrected. */
    public var floorY: Float
    /* Foot to head, in metres. Drives camera framing and every body proportion. */
    public var bodyHeight: Float
    /* Shoulder to shoulder, in metres. Drives limb thickness. */
    public var shoulderSpan: Float

    public init(ySign: Float, floorY: Float, bodyHeight: Float, shoulderSpan: Float) {
        self.ySign = ySign
        self.floorY = floorY
        self.bodyHeight = bodyHeight
        self.shoulderSpan = shoulderSpan
    }

    /* A sane figure when there are no frames, so an empty panel still lays out
       rather than collapsing to zero and dividing by it somewhere downstream. */
    public static let fallback = SwingAnchor(ySign: 1, floorY: -0.9, bodyHeight: 1.7, shoulderSpan: 0.38)

    public static func measure(frames: [Frame]) -> SwingAnchor {
        guard !frames.isEmpty else { return .fallback }

        let ankles = [Landmarks.LEFT_ANKLE, Landmarks.RIGHT_ANKLE]
        var ankleSum = 0.0
        var ankleCount = 0
        var headSum = 0.0
        var headCount = 0
        var spanSum = 0.0
        var spanCount = 0

        for frame in frames {
            let w = frame.world
            for j in ankles where Self.trusted(w, j) {
                ankleSum += w[j].y
                ankleCount += 1
            }
            if Self.trusted(w, Landmarks.NOSE) {
                headSum += w[Landmarks.NOSE].y
                headCount += 1
            }
            if Self.trusted(w, Landmarks.LEFT_SHOULDER), Self.trusted(w, Landmarks.RIGHT_SHOULDER) {
                let a = w[Landmarks.LEFT_SHOULDER]
                let b = w[Landmarks.RIGHT_SHOULDER]
                let dx = a.x - b.x
                let dy = a.y - b.y
                let dz = (a.z ?? 0) - (b.z ?? 0)
                spanSum += (dx * dx + dy * dy + dz * dz).squareRoot()
                spanCount += 1
            }
        }

        guard ankleCount > 0, headCount > 0 else { return .fallback }
        let ankleMean = ankleSum / Double(ankleCount)
        let headMean = headSum / Double(headCount)

        /* If the feet sit at a larger y than the head, y increases downward and
           has to be flipped for SceneKit. If they sit at a smaller y, y already
           points up and flipping would stand the golfer on their head. This is
           the one line that lets the same view render MediaPipe frames and
           Vision frames without a backend flag. */
        let ySign: Float = ankleMean > headMean ? -1 : 1

        /* Ground is the lowest foot anywhere in the clip, in SceneKit space. */
        var floorY = Float.greatestFiniteMagnitude
        var topY = -Float.greatestFiniteMagnitude
        for frame in frames {
            let w = frame.world
            for j in ankles where Self.trusted(w, j) {
                floorY = min(floorY, Float(w[j].y) * ySign)
            }
            if Self.trusted(w, Landmarks.NOSE) {
                topY = max(topY, Float(w[Landmarks.NOSE].y) * ySign)
            }
        }
        guard floorY.isFinite, topY.isFinite, topY > floorY else { return .fallback }

        /* The head centre is not the crown, so add a little for the skull the
           tracker does not report. Stylistic, and it only affects framing. */
        let measured = (topY - floorY) * 1.06
        let span = spanCount > 0 ? Float(spanSum / Double(spanCount)) : measured * 0.22

        return SwingAnchor(
            ySign: ySign,
            floorY: floorY,
            bodyHeight: max(0.9, measured),
            shoulderSpan: max(0.18, span)
        )
    }

    /* The same floor the 2D overlay draws to. A joint Vision filled in has a nil
       visibility and reads as 1. A slot Vision never filled has visibility 0 and
       reads as absent, which is exactly what it is. */
    static func trusted(_ set: LandmarkSet, _ index: Int) -> Bool {
        guard set.indices.contains(index) else { return false }
        let p = set[index]
        return (p.visibility ?? p.score ?? 1) >= Rig.confidenceFloor
    }
}

// MARK: - Shared constants

public enum Rig {
    /* Matches SkeletonOverlay.swift, which matches the web SkeletonOverlay.jsx.
       Three files agreeing on one number by copying it is how they drift, so if
       this ever changes it changes in all three. */
    public static let confidenceFloor: Double = 0.35

    /* Inferred parts render at this alpha so they read as sketch. */
    public static let inferredAlpha: CGFloat = 0.55
}

// MARK: - Resolved pose

/*
  One frame of landmarks turned into named points in SceneKit space.

  Everything downstream asks for `pose.leftElbow` rather than indexing slot 13,
  and asks for `pose.neck` without caring that no tracker ever reported a neck.
  Confidence travels with the point, so a segment can decide to hide itself
  without going back to the raw set.
*/
struct PosePoint {
    var p: SIMD3<Float>
    var ok: Bool

    static let missing = PosePoint(p: .zero, ok: false)
}

struct ResolvedPose {
    var head = PosePoint.missing
    var neck = PosePoint.missing
    var chestTop = PosePoint.missing
    var chestLow = PosePoint.missing
    var abdomen = PosePoint.missing
    var pelvis = PosePoint.missing

    var leftShoulder = PosePoint.missing
    var rightShoulder = PosePoint.missing
    var leftElbow = PosePoint.missing
    var rightElbow = PosePoint.missing
    var leftWrist = PosePoint.missing
    var rightWrist = PosePoint.missing
    var leftHand = PosePoint.missing
    var rightHand = PosePoint.missing

    var leftHip = PosePoint.missing
    var rightHip = PosePoint.missing
    var leftKnee = PosePoint.missing
    var rightKnee = PosePoint.missing
    var leftAnkle = PosePoint.missing
    var rightAnkle = PosePoint.missing
    var leftFoot = PosePoint.missing
    var rightFoot = PosePoint.missing

    /* Across the shoulders, from the golfer's right to their left. The roll
       reference for every block that is not radially symmetric. */
    var lateral: SIMD3<Float> = SIMD3(1, 0, 0)

    static func resolve(_ world: LandmarkSet, anchor: SwingAnchor, scale: RigScale) -> ResolvedPose {
        var pose = ResolvedPose()

        func read(_ index: Int) -> PosePoint {
            guard world.indices.contains(index) else { return .missing }
            let l = world[index]
            let visible = (l.visibility ?? l.score ?? 1) >= Rig.confidenceFloor
            guard visible, l.x.isFinite, l.y.isFinite else { return .missing }
            return PosePoint(
                p: SIMD3(Float(l.x), Float(l.y) * anchor.ySign, Float(l.z ?? 0)),
                ok: true
            )
        }

        func between(_ a: PosePoint, _ b: PosePoint) -> PosePoint {
            guard a.ok, b.ok else { return .missing }
            return PosePoint(p: (a.p + b.p) * 0.5, ok: true)
        }

        func lerp(_ a: PosePoint, _ b: PosePoint, _ k: Float) -> PosePoint {
            guard a.ok, b.ok else { return .missing }
            return PosePoint(p: a.p + (b.p - a.p) * k, ok: true)
        }

        pose.head = read(Landmarks.NOSE)
        pose.leftShoulder = read(Landmarks.LEFT_SHOULDER)
        pose.rightShoulder = read(Landmarks.RIGHT_SHOULDER)
        pose.leftElbow = read(Landmarks.LEFT_ELBOW)
        pose.rightElbow = read(Landmarks.RIGHT_ELBOW)
        pose.leftWrist = read(Landmarks.LEFT_WRIST)
        pose.rightWrist = read(Landmarks.RIGHT_WRIST)
        pose.leftHip = read(Landmarks.LEFT_HIP)
        pose.rightHip = read(Landmarks.RIGHT_HIP)
        pose.leftKnee = read(Landmarks.LEFT_KNEE)
        pose.rightKnee = read(Landmarks.RIGHT_KNEE)
        pose.leftAnkle = read(Landmarks.LEFT_ANKLE)
        pose.rightAnkle = read(Landmarks.RIGHT_ANKLE)

        /* Derived, not invented. A neck is where the shoulders meet and a pelvis
           is where the hips meet, and both are measured points averaged, not
           guesses about anatomy the tracker did not see. */
        pose.neck = between(pose.leftShoulder, pose.rightShoulder)
        pose.pelvis = between(pose.leftHip, pose.rightHip)
        pose.chestTop = lerp(pose.neck, pose.pelvis, 0.10)
        pose.chestLow = lerp(pose.neck, pose.pelvis, 0.46)
        pose.abdomen = lerp(pose.neck, pose.pelvis, 0.72)

        /* Lateral axis. The shoulder line if it is there, the hip line if it is
           not, and a fixed axis only when neither is, which is a frame with
           almost nothing in it anyway. */
        if pose.leftShoulder.ok, pose.rightShoulder.ok {
            pose.lateral = pose.leftShoulder.p - pose.rightShoulder.p
        } else if pose.leftHip.ok, pose.rightHip.ok {
            pose.lateral = pose.leftHip.p - pose.rightHip.p
        }
        if simd_length(pose.lateral) < 1e-5 {
            pose.lateral = SIMD3(1, 0, 0)
        }

        /* INFERRED. The hand continues the line of the forearm past the wrist.
           Vision reports nothing beyond the wrist, so this is a stylised stand
           in for a hand and is drawn faded to say so. It is not a grip
           measurement and must never be read as one. */
        func hand(wrist: PosePoint, elbow: PosePoint) -> PosePoint {
            guard wrist.ok, elbow.ok else { return .missing }
            let dir = wrist.p - elbow.p
            guard let unit = Self.unit(dir) else { return .missing }
            return PosePoint(p: wrist.p + unit * (scale.handLength * 0.5), ok: true)
        }
        pose.leftHand = hand(wrist: pose.leftWrist, elbow: pose.leftElbow)
        pose.rightHand = hand(wrist: pose.rightWrist, elbow: pose.rightElbow)

        /* INFERRED. The foot points along the body's forward axis from the
           ankle and sits on the floor. Vision has no heel and no toe, so this
           is a shoe shaped block placed where a shoe would be, faded for the
           same reason as the hands. */
        let up = SIMD3<Float>(0, 1, 0)
        var forward = simd_cross(up, pose.lateral)
        if simd_length(forward) < 1e-5 {
            forward = SIMD3(0, 0, 1)
        }
        forward = simd_normalize(forward)

        func foot(ankle: PosePoint) -> PosePoint {
            guard ankle.ok else { return .missing }
            /* 0.75 rather than a smaller factor because the rendered shoe spans
               ankle to this point, not zero to this point. Checked numerically:
               at a 40cm shoulder span this gives a 23cm shoe. An earlier 0.34
               gave 12cm, which is a foot half the length of the hand. */
            var p = ankle.p + forward * (scale.footLength * 0.75)
            p.y = min(p.y, anchor.floorY + scale.footHeight * 0.5)
            return PosePoint(p: p, ok: true)
        }
        pose.leftFoot = foot(ankle: pose.leftAnkle)
        pose.rightFoot = foot(ankle: pose.rightAnkle)

        return pose
    }

    static func unit(_ v: SIMD3<Float>) -> SIMD3<Float>? {
        let length = simd_length(v)
        guard length > 1e-6, length.isFinite else { return nil }
        return v / length
    }
}

// MARK: - Proportions

/*
  Every dimension as a fraction of the golfer's own shoulder span.

  These are stylistic, not measurements, and they are the only numbers in this
  file that were chosen by eye rather than derived from data. Tying them to
  shoulder span rather than to absolute metres means a junior and an adult both
  get a figure with the same proportions instead of one looking like a doll.
*/
struct RigScale {
    let span: Float

    init(anchor: SwingAnchor) {
        self.span = anchor.shoulderSpan
    }

    var headRadius: Float { span * 0.275 }
    var neckRadius: Float { span * 0.135 }
    var chestWidth: Float { span * 1.02 }
    var chestDepth: Float { span * 0.56 }
    var abdomenWidth: Float { span * 0.80 }
    var abdomenDepth: Float { span * 0.50 }
    var pelvisWidth: Float { span * 0.92 }
    var pelvisDepth: Float { span * 0.54 }

    var shoulderCapRadius: Float { span * 0.190 }
    var upperArmRadius: Float { span * 0.118 }
    var elbowCapRadius: Float { span * 0.130 }
    var forearmRadius: Float { span * 0.100 }
    var wristRadius: Float { span * 0.078 }

    var handLength: Float { span * 0.46 }
    var handWidth: Float { span * 0.26 }
    var handThickness: Float { span * 0.11 }

    var thighRadius: Float { span * 0.172 }
    var kneeCapRadius: Float { span * 0.162 }
    var shinRadius: Float { span * 0.126 }
    var ankleRadius: Float { span * 0.092 }

    var footLength: Float { span * 0.66 }
    var footWidth: Float { span * 0.27 }
    var footHeight: Float { span * 0.17 }

    var traceRadius: Float { span * 0.030 }
}

// MARK: - Orientation

/*
  Turning two points into a node transform.

  A node's local +Y is mapped onto the segment axis. The roll about that axis is
  taken from a reference direction by Gram Schmidt, which is stable except when
  the reference is parallel to the axis, where the roll is genuinely undefined
  and any answer is arbitrary.

  That degenerate case is real, not theoretical. The lateral axis runs across
  the shoulders, and at the top of the backswing the lead arm can come close to
  lying along it. So the rule this file follows, and the reason the geometry is
  chosen the way it is:

    radially symmetric geometry for anything whose axis can align with the roll
    reference, which is every limb, so an unstable roll is invisible
    non symmetric geometry only for the torso stack, whose axis is the spine and
    is near perpendicular to the shoulder line by anatomy, so its roll is stable

  simd_quatf(from:to:) is not used. It is undefined for anti parallel vectors,
  which is a NaN transform and a segment that vanishes or explodes, and it gives
  no control over roll at all.
*/
enum Orientation {

    /* Below this the reference is effectively parallel to the axis and the roll
       it implies is numerical noise, so a fixed fallback is used instead. */
    static let rollResidualFloor: Float = 1e-3

    static func basis(axis: SIMD3<Float>, rollReference: SIMD3<Float>) -> simd_float3x3? {
        guard let up = ResolvedPose.unit(axis) else { return nil }

        var residual = rollReference - up * simd_dot(rollReference, up)
        if simd_length(residual) < rollResidualFloor {
            let alternate: SIMD3<Float> = abs(up.x) > 0.9 ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0)
            residual = alternate - up * simd_dot(alternate, up)
        }
        guard let right = ResolvedPose.unit(residual) else { return nil }

        let forward = simd_cross(right, up)
        return simd_float3x3(columns: (right, up, forward))
    }

    /* A transform that puts a unit tall, origin centred geometry between two
       points, scaled to span exactly the distance between them. */
    static func transform(
        from a: SIMD3<Float>,
        to b: SIMD3<Float>,
        rollReference: SIMD3<Float>,
        crossScale: SIMD2<Float> = SIMD2(1, 1)
    ) -> (matrix: simd_float4x4, length: Float)? {
        let delta = b - a
        let length = simd_length(delta)
        guard length > 1e-5, length.isFinite else { return nil }
        guard let basis = basis(axis: delta, rollReference: rollReference) else { return nil }
        let centre = a + delta * 0.5
        return (compose(basis: basis, scale: SIMD3(crossScale.x, length, crossScale.y), position: centre), length)
    }

    /* A transform for a geometry centred on one point rather than spanning two. */
    static func transform(
        at point: SIMD3<Float>,
        axis: SIMD3<Float>,
        rollReference: SIMD3<Float>,
        scale: SIMD3<Float>
    ) -> simd_float4x4? {
        guard let basis = basis(axis: axis, rollReference: rollReference) else { return nil }
        return compose(basis: basis, scale: scale, position: point)
    }

    static func compose(basis: simd_float3x3, scale: SIMD3<Float>, position: SIMD3<Float>) -> simd_float4x4 {
        /* simd is column major and SceneKit reads simdTransform the same way, so
           column 0 is the local x axis, column 1 the local y axis, column 2 the
           local z axis and column 3 the translation. */
        simd_float4x4(
            SIMD4(basis.columns.0 * scale.x, 0),
            SIMD4(basis.columns.1 * scale.y, 0),
            SIMD4(basis.columns.2 * scale.z, 0),
            SIMD4(position, 1)
        )
    }
}

// MARK: - Segment identity

enum SegmentID: Hashable {
    case head, neck, chest, abdomen, pelvisBlock
    case shoulderCap(Bool)   // true is the golfer's left
    case upperArm(Bool)
    case elbowCap(Bool)
    case forearm(Bool)
    case hand(Bool)
    case thigh(Bool)
    case kneeCap(Bool)
    case shin(Bool)
    case foot(Bool)
}

/*
  Which landmark each marker sits on.

  Exactly the joints Vision reports, which is also exactly the set the request
  asked for: shoulder, elbow, wrist, hip, knee, ankle and head. Putting a marker
  on a slot Vision never fills would put a bead at the origin on every frame.
*/
struct MarkerID: Hashable {
    var landmark: Int
    var side: MarkerSide
}

enum MarkerSide {
    case left, right, centre
}

// MARK: - The rig

@MainActor
public final class HumanoidRig {

    public let node = SCNNode()

    private let anchor: SwingAnchor
    private let scale: RigScale
    private var palette: HumanoidPalette
    private var markerPalette: JointMarkerPalette
    private var dominantHand: DominantHand
    private var style: JointColorStyle

    private var segments: [SegmentID: SCNNode] = [:]
    private var markers: [MarkerID: SCNNode] = [:]
    private var markerMaterials: [MarkerID: SCNMaterial] = [:]

    private let bodyNode = SCNNode()
    private let markerNode = SCNNode()

    public init(
        anchor: SwingAnchor,
        palette: HumanoidPalette = .blockout,
        markerPalette: JointMarkerPalette = .standard,
        dominantHand: DominantHand = .right,
        style: JointColorStyle = .dual
    ) {
        self.anchor = anchor
        self.scale = RigScale(anchor: anchor)
        self.palette = palette
        self.markerPalette = markerPalette
        self.dominantHand = dominantHand
        self.style = style

        node.name = "humanoid"
        node.addChildNode(bodyNode)
        node.addChildNode(markerNode)

        buildBody()
        buildMarkers()
        applyMarkerColours()
    }

    // MARK: Materials

    /*
      Matte, not metal.

      physicallyBased with metalness zero and a high roughness gives the soft,
      smooth, unlit looking pastel of the reference blockout. There is no
      environment map in this scene, so the diffuse response comes entirely from
      the lights placed in SceneKitView.

      IF IT RENDERS TOO DARK ON DEVICE, and this is the one thing here that
      cannot be checked without running it, change lightingModel to .blinn and
      drop specular to near black. That is a one line change and it is a more
      forgiving model without image based lighting.
    */
    private func material(_ colour: UIColor, alpha: CGFloat = 1) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = alpha < 1 ? colour.withAlphaComponent(alpha) : colour
        m.metalness.contents = 0.0
        m.roughness.contents = 0.72
        m.isDoubleSided = false
        if alpha < 1 {
            m.transparency = alpha
            m.blendMode = .alpha
            /* An inferred part must not occlude a measured one behind it, so it
               does not write depth. */
            m.writesToDepthBuffer = false
        }
        return m
    }

    private func makeNode(_ geometry: SCNGeometry, _ colour: UIColor, alpha: CGFloat = 1) -> SCNNode {
        geometry.firstMaterial = material(colour, alpha: alpha)
        let n = SCNNode(geometry: geometry)
        /* Hidden until a frame proves the joints behind it were actually seen.
           A segment is never shown on the strength of the build alone. */
        n.isHidden = true
        return n
    }

    // MARK: Build

    private func buildBody() {
        let s = scale

        /* Torso stack. Ellipsoids rather than boxes, because the reference reads
           as soft masses rather than as crates, and because a sphere scaled per
           axis costs one geometry and gives full control of width and depth.
           A unit radius sphere is scaled directly, so radius 0.5 makes the local
           unit box exactly one unit across and the scale numbers below are the
           real dimensions in metres. */
        add(.head, sphere(0.5), palette.head)
        add(.neck, cylinder(radius: s.neckRadius), palette.neck)
        add(.chest, sphere(0.5), palette.chest)
        add(.abdomen, sphere(0.5), palette.abdomen)
        add(.pelvisBlock, sphere(0.5), palette.pelvis)

        for left in [true, false] {
            add(.shoulderCap(left), sphere(s.shoulderCapRadius), palette.shoulderCap)
            add(.upperArm(left), cone(top: s.elbowCapRadius * 0.82, bottom: s.upperArmRadius), palette.upperArm)
            add(.elbowCap(left), sphere(s.elbowCapRadius), palette.elbowCap)
            add(.forearm(left), cone(top: s.wristRadius, bottom: s.forearmRadius), palette.forearm)
            add(.hand(left), box(width: s.handWidth, height: 1, length: s.handThickness), palette.hand, alpha: Rig.inferredAlpha)

            add(.thigh(left), cone(top: s.kneeCapRadius * 0.86, bottom: s.thighRadius), palette.thigh)
            add(.kneeCap(left), sphere(s.kneeCapRadius), palette.kneeCap)
            add(.shin(left), cone(top: s.ankleRadius, bottom: s.shinRadius), palette.shin)
            add(.foot(left), box(width: s.footWidth, height: 1, length: s.footHeight), palette.foot, alpha: Rig.inferredAlpha)
        }
    }

    private func add(_ id: SegmentID, _ geometry: SCNGeometry, _ colour: UIColor, alpha: CGFloat = 1) {
        let n = makeNode(geometry, colour, alpha: alpha)
        segments[id] = n
        bodyNode.addChildNode(n)
    }

    /* A unit tall cone, so scaling y by the bone length spans the bone exactly.
       The taper is what gives the limbs their shape, and because a cone is
       radially symmetric its roll is invisible, which is what makes the unstable
       roll case described in Orientation harmless. */
    private func cone(top: Float, bottom: Float) -> SCNGeometry {
        SCNCone(
            topRadius: CGFloat(top),
            bottomRadius: CGFloat(bottom),
            height: 1
        )
    }

    private func cylinder(radius: Float) -> SCNGeometry {
        SCNCylinder(radius: CGFloat(radius), height: 1)
    }

    private func sphere(_ radius: Float) -> SCNGeometry {
        let g = SCNSphere(radius: CGFloat(radius))
        g.segmentCount = 24
        return g
    }

    private func box(width: Float, height: Float, length: Float) -> SCNGeometry {
        SCNBox(
            width: CGFloat(width),
            height: CGFloat(height),
            length: CGFloat(length),
            /* A generous chamfer is what stops the hands and feet reading as
               dice next to the rounded masses of the body. */
            chamferRadius: CGFloat(min(width, length) * 0.38)
        )
    }

    private func buildMarkers() {
        let radius = Float(markerPalette.radiusInShoulders) * scale.span
        let geometry = SCNSphere(radius: CGFloat(radius))
        geometry.segmentCount = 16

        for id in Self.markerIDs {
            /* Each marker owns its material so its colour can change when the
               style is toggled without rebuilding the scene. Thirteen materials
               is nothing, and sharing one would make the toggle repaint every
               marker the same colour, which is the bug this avoids. */
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.metalness.contents = 0.0
            m.roughness.contents = 0.38
            /* A faint self illumination keeps a marker readable when it turns
               into shadow, since a marker that disappears at the top of the
               backswing is a marker that is not doing its job. */
            m.emission.contents = UIColor(white: 1, alpha: 0.12)

            /* copy() returns Any and is force cast in most SceneKit sample code,
               but a force cast is exactly the line a compile and crash audit is
               meant to remove. A fresh SCNSphere at the same radius is the safe
               fallback and behaves identically, so a future change to the base
               geometry type can never turn this into a runtime trap. */
            let shape = (geometry.copy() as? SCNSphere) ?? SCNSphere(radius: CGFloat(radius))
            shape.segmentCount = 16
            shape.firstMaterial = m
            let n = SCNNode(geometry: shape)
            n.isHidden = true
            /* Markers render after the body so they are never swallowed by the
               segment they sit on. */
            n.renderingOrder = 10

            markers[id] = n
            markerMaterials[id] = m
            markerNode.addChildNode(n)
        }
    }

    static let markerIDs: [MarkerID] = [
        MarkerID(landmark: Landmarks.NOSE, side: .centre),
        MarkerID(landmark: Landmarks.LEFT_SHOULDER, side: .left),
        MarkerID(landmark: Landmarks.RIGHT_SHOULDER, side: .right),
        MarkerID(landmark: Landmarks.LEFT_ELBOW, side: .left),
        MarkerID(landmark: Landmarks.RIGHT_ELBOW, side: .right),
        MarkerID(landmark: Landmarks.LEFT_WRIST, side: .left),
        MarkerID(landmark: Landmarks.RIGHT_WRIST, side: .right),
        MarkerID(landmark: Landmarks.LEFT_HIP, side: .left),
        MarkerID(landmark: Landmarks.RIGHT_HIP, side: .right),
        MarkerID(landmark: Landmarks.LEFT_KNEE, side: .left),
        MarkerID(landmark: Landmarks.RIGHT_KNEE, side: .right),
        MarkerID(landmark: Landmarks.LEFT_ANKLE, side: .left),
        MarkerID(landmark: Landmarks.RIGHT_ANKLE, side: .right),
    ]

    // MARK: Marker colour

    /*
      Toggle the marker styling.

      Cheap by design. It repaints thirteen materials and touches nothing else,
      so it can be driven from a control that changes on every tap without the
      scene flickering or the figure rebuilding.
    */
    public func setJointColorStyle(_ newStyle: JointColorStyle) {
        guard newStyle != style else { return }
        style = newStyle
        applyMarkerColours()
    }

    public func setDominantHand(_ hand: DominantHand) {
        guard hand != dominantHand else { return }
        dominantHand = hand
        applyMarkerColours()
    }

    public func setMarkerPalette(_ palette: JointMarkerPalette) {
        markerPalette = palette
        applyMarkerColours()
    }

    public var jointColorStyle: JointColorStyle { style }

    private func applyMarkerColours() {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        for (id, material) in markerMaterials {
            material.diffuse.contents = colour(for: id)
        }
        SCNTransaction.commit()
    }

    /*
      Lead and trail resolved from the setting, not from left and right.

      Landmarks.sides is the one place in the app that knows which physical side
      is the lead side, so asking it here means a left handed golfer gets the
      correct split without this file knowing anything about handedness.
    */
    private func colour(for id: MarkerID) -> UIColor {
        switch style {
        case .single:
            return markerPalette.single
        case .dual:
            /* The head sits on the midline and has no side. Colouring it either
               way would state something the anatomy does not support. */
            guard id.side != .centre else { return markerPalette.neutral }
            let sides = Landmarks.sides(dominantHand)
            let leadSlots: Set<Int> = [
                sides.leadShoulder, sides.leadElbow, sides.leadWrist,
                sides.leadHip, sides.leadKnee, sides.leadAnkle,
            ]
            return leadSlots.contains(id.landmark) ? markerPalette.lead : markerPalette.trail
        }
    }

    // MARK: Per frame update

    /*
      The whole rig for one frame.

      Called on every frameIndex change and on nothing else. It reads world
      landmarks, writes node transforms, and returns. There is no clock here and
      no interpolation, which is what makes scrubbing backwards look identical to
      playing forwards.
    */
    public func apply(world: LandmarkSet?) {
        SCNTransaction.begin()
        /* Without this SceneKit animates every transform change over its default
           quarter second, which turns scrubbing into a smear and puts the figure
           permanently behind the frame index. */
        SCNTransaction.animationDuration = 0
        defer { SCNTransaction.commit() }

        guard let world, !world.isEmpty else {
            hideAll()
            return
        }

        let pose = ResolvedPose.resolve(world, anchor: anchor, scale: scale)
        let lateral = pose.lateral
        let s = scale

        // Torso stack.
        place(.chest, from: pose.neck, to: pose.chestLow, roll: lateral,
              cross: SIMD2(s.chestWidth, s.chestDepth), lengthGain: 1.14)
        place(.abdomen, from: pose.chestLow, to: pose.abdomen, roll: lateral,
              cross: SIMD2(s.abdomenWidth, s.abdomenDepth), lengthGain: 1.30)
        place(.pelvisBlock, from: pose.abdomen, to: pose.pelvis, roll: lateral,
              cross: SIMD2(s.pelvisWidth, s.pelvisDepth), lengthGain: 1.55)

        /* Neck and head hang off the shoulder midpoint toward the head point.
           If the head was not seen the neck goes with it, rather than a neck
           standing on its own pointing nowhere. */
        if pose.neck.ok, pose.head.ok {
            let axis = pose.head.p - pose.neck.p
            let gap = simd_length(axis)
            let neckLength = max(gap - s.headRadius * 0.85, s.neckRadius * 0.6)
            if let unit = ResolvedPose.unit(axis) {
                setTransform(
                    .neck,
                    Orientation.transform(
                        at: pose.neck.p + unit * (neckLength * 0.45),
                        axis: axis,
                        rollReference: lateral,
                        scale: SIMD3(1, neckLength, 1)
                    )
                )
                setTransform(
                    .head,
                    Orientation.transform(
                        at: pose.head.p,
                        axis: axis,
                        rollReference: lateral,
                        /* Narrower across than deep, because a real head is.
                           These three were checked against adult anthropometry
                           at a 40cm shoulder span: 15.6cm wide, 22.0cm tall,
                           20.5cm deep. An earlier 1.72 width factor gave an
                           18.9cm head, which read as a bobblehead from the
                           front and only looked right in profile. */
                        scale: SIMD3(s.headRadius * 1.42, s.headRadius * 2.0, s.headRadius * 1.86)
                    )
                )
            }
        } else {
            hide(.neck)
            hide(.head)
        }

        // Arms and legs, per side. true is the golfer's left.
        for left in [true, false] {
            let shoulder = left ? pose.leftShoulder : pose.rightShoulder
            let elbow = left ? pose.leftElbow : pose.rightElbow
            let wrist = left ? pose.leftWrist : pose.rightWrist
            let handPoint = left ? pose.leftHand : pose.rightHand
            let hip = left ? pose.leftHip : pose.rightHip
            let knee = left ? pose.leftKnee : pose.rightKnee
            let ankle = left ? pose.leftAnkle : pose.rightAnkle
            let footPoint = left ? pose.leftFoot : pose.rightFoot

            cap(.shoulderCap(left), at: shoulder)
            place(.upperArm(left), from: shoulder, to: elbow, roll: lateral)
            cap(.elbowCap(left), at: elbow)
            place(.forearm(left), from: elbow, to: wrist, roll: lateral)
            place(.hand(left), from: wrist, to: handPoint, roll: lateral,
                  cross: SIMD2(1, 1), lengthGain: 1.0)

            place(.thigh(left), from: hip, to: knee, roll: lateral)
            cap(.kneeCap(left), at: knee)
            place(.shin(left), from: knee, to: ankle, roll: lateral)
            place(.foot(left), from: ankle, to: footPoint, roll: lateral,
                  cross: SIMD2(1, 1), lengthGain: 1.15)
        }

        // Markers.
        for id in Self.markerIDs {
            guard let n = markers[id] else { continue }
            guard world.indices.contains(id.landmark) else {
                n.isHidden = true
                continue
            }
            let l = world[id.landmark]
            let visible = (l.visibility ?? l.score ?? 1) >= Rig.confidenceFloor
            guard visible, l.x.isFinite, l.y.isFinite else {
                n.isHidden = true
                continue
            }
            n.simdPosition = SIMD3(Float(l.x), Float(l.y) * anchor.ySign, Float(l.z ?? 0))
            n.isHidden = false
        }
    }

    // MARK: Placement helpers

    /*
      Span a segment between two points.

      lengthGain stretches the geometry past the two points it spans, which the
      torso masses need so they overlap into each other and read as one body
      rather than as a stack of separate beads with gaps at the seams.
    */
    private func place(
        _ id: SegmentID,
        from a: PosePoint,
        to b: PosePoint,
        roll: SIMD3<Float>,
        cross: SIMD2<Float> = SIMD2(1, 1),
        lengthGain: Float = 1
    ) {
        guard a.ok, b.ok else {
            hide(id)
            return
        }
        guard let result = Orientation.transform(from: a.p, to: b.p, rollReference: roll, crossScale: cross) else {
            hide(id)
            return
        }
        guard let node = segments[id] else { return }
        var m = result.matrix
        if lengthGain != 1 {
            /* Column 1 is the local y axis, which already carries the length, so
               scaling it scales the segment along its own axis only. */
            m.columns.1 *= lengthGain
        }
        node.simdTransform = m
        node.isHidden = false
    }

    private func cap(_ id: SegmentID, at point: PosePoint) {
        guard point.ok, let node = segments[id] else {
            hide(id)
            return
        }
        node.simdPosition = point.p
        node.simdScale = SIMD3(repeating: 1)
        node.isHidden = false
    }

    private func setTransform(_ id: SegmentID, _ matrix: simd_float4x4?) {
        guard let matrix, let node = segments[id] else {
            hide(id)
            return
        }
        node.simdTransform = matrix
        node.isHidden = false
    }

    private func hide(_ id: SegmentID) {
        segments[id]?.isHidden = true
    }

    private func hideAll() {
        for node in segments.values { node.isHidden = true }
        for node in markers.values { node.isHidden = true }
    }
}

// MARK: - 3D traces

/*
  The hand path and the estimated club head path, in world space.

  Same architecture as the Phase 2 overlay in TraceOverlay.swift, and
  deliberately so: the path is built once when the swing loads, and every frame
  asks one question, which points have happened by this frame index. That is a
  lookup, not an animation, so the trace grows while playing and shrinks exactly
  in step when the scrubber is dragged backwards.

  Why this is not just TrackingLayers with a z added. TrackingLayers builds from
  frames[k].norm, which is image space and has no depth at all. A 3D trace has to
  come from frames[k].world. Same formula, different coordinate set.
*/
public struct WorldTracePoint {
    public var i: Int
    public var t: Double
    public var p: SIMD3<Float>
}

public struct WorldFrameSeries {
    public let points: [WorldTracePoint]
    /* For every frame, the index of the last path point at or before it. */
    public let upto: [Int]

    public func countAt(_ frameIndex: Int) -> Int {
        guard !points.isEmpty, !upto.isEmpty else { return 0 }
        let f = min(max(frameIndex, 0), upto.count - 1)
        return upto[f] + 1
    }
}

public enum SwingTrace3D {

    /* Same constant as TrackingLayers.clubInShoulders. A driver sits a little
       over a shoulder width and a half beyond the hands. */
    private static let clubInShoulders: Float = 1.6

    public static func build(
        frames: [Frame],
        from: Int,
        to: Int,
        dominantHand: DominantHand,
        anchor: SwingAnchor
    ) -> (hand: WorldFrameSeries?, club: WorldFrameSeries?) {
        let count = frames.count
        let hand = series(handPath(frames, from: from, to: to, anchor: anchor), frameCount: count)
        let club = series(
            clubPath(frames, from: from, to: to, dominantHand: dominantHand, anchor: anchor),
            frameCount: count
        )
        return (hand, club)
    }

    /* Midpoint of the two wrists, which is where the hands actually are as a
       single point and steadier than either wrist alone, because independent
       tracking error on the two partly cancels when averaged. */
    public static func handPath(_ frames: [Frame], from: Int, to: Int, anchor: SwingAnchor) -> [WorldTracePoint] {
        guard !frames.isEmpty else { return [] }
        let lo = max(0, from)
        let hi = min(frames.count - 1, to)
        guard hi - lo >= 4 else { return [] }

        var raw: [WorldTracePoint] = []
        for k in lo...hi {
            let w = frames[k].world
            let lok = SwingAnchor.trusted(w, Landmarks.LEFT_WRIST)
            let rok = SwingAnchor.trusted(w, Landmarks.RIGHT_WRIST)
            guard lok || rok else { continue }
            let p: SIMD3<Float>
            if lok, rok {
                p = (vec(w[Landmarks.LEFT_WRIST], anchor) + vec(w[Landmarks.RIGHT_WRIST], anchor)) * 0.5
            } else {
                p = vec(w[lok ? Landmarks.LEFT_WRIST : Landmarks.RIGHT_WRIST], anchor)
            }
            raw.append(WorldTracePoint(i: k, t: frames[k].t, p: p))
        }
        return smooth(raw)
    }

    /* The club is roughly an extension of the lead forearm through the hands, so
       the direction from elbow to wrist continued past the hands by an estimated
       club length lands near the head. Geometry, not detection, which is why the
       node that draws it is gapped rather than solid. An estimate is never
       presented as a measurement. */
    public static func clubPath(
        _ frames: [Frame],
        from: Int,
        to: Int,
        dominantHand: DominantHand,
        anchor: SwingAnchor
    ) -> [WorldTracePoint] {
        guard !frames.isEmpty else { return [] }
        let sides = Landmarks.sides(dominantHand)
        let lo = max(0, from)
        let hi = min(frames.count - 1, to)
        guard hi - lo >= 4 else { return [] }

        var raw: [WorldTracePoint] = []
        for k in lo...hi {
            let w = frames[k].world
            guard SwingAnchor.trusted(w, sides.leadWrist), SwingAnchor.trusted(w, sides.leadElbow) else { continue }
            guard SwingAnchor.trusted(w, Landmarks.LEFT_SHOULDER), SwingAnchor.trusted(w, Landmarks.RIGHT_SHOULDER) else { continue }

            let wrist = vec(w[sides.leadWrist], anchor)
            let elbow = vec(w[sides.leadElbow], anchor)
            let span = simd_length(vec(w[Landmarks.LEFT_SHOULDER], anchor) - vec(w[Landmarks.RIGHT_SHOULDER], anchor))
            guard let unit = ResolvedPose.unit(wrist - elbow), span > 1e-4 else { continue }

            raw.append(WorldTracePoint(i: k, t: frames[k].t, p: wrist + unit * (span * clubInShoulders)))
        }
        return smooth(raw)
    }

    private static func vec(_ l: Landmark, _ anchor: SwingAnchor) -> SIMD3<Float> {
        SIMD3(Float(l.x), Float(l.y) * anchor.ySign, Float(l.z ?? 0))
    }

    /* Smoothed in the time domain against the real timestamps, with the same
       120ms window the 2D traces use, so the same real duration is covered
       whatever rate the clip was tracked at and the 2D and 3D traces describe
       the same curve. */
    private static func smooth(_ raw: [WorldTracePoint]) -> [WorldTracePoint] {
        guard raw.count >= 5 else { return raw }
        let times = raw.map(\.t)
        let sx = Geometry.savitzkyGolayMs(raw.map { Double($0.p.x) }, times, 120)
        let sy = Geometry.savitzkyGolayMs(raw.map { Double($0.p.y) }, times, 120)
        let sz = Geometry.savitzkyGolayMs(raw.map { Double($0.p.z) }, times, 120)
        return raw.enumerated().map { k, point in
            WorldTracePoint(i: point.i, t: point.t, p: SIMD3(Float(sx[k]), Float(sy[k]), Float(sz[k])))
        }
    }

    private static func series(_ points: [WorldTracePoint], frameCount: Int) -> WorldFrameSeries? {
        guard !points.isEmpty, frameCount > 0 else { return nil }
        var upto = [Int](repeating: -1, count: frameCount)
        var k = 0
        for f in 0..<frameCount {
            while k < points.count && points[k].i <= f { k += 1 }
            upto[f] = k - 1
        }
        return WorldFrameSeries(points: points, upto: upto)
    }
}

// MARK: - Trace node

/*
  A path drawn as a chain of thin cylinders.

  SceneKit has no thick line primitive. A line geometry renders one pixel wide
  with no control worth having, so the trace is built from real geometry: one
  short cylinder between each pair of consecutive points, oriented the same way
  the limbs are.

  The whole chain is built once. Revealing the trace is then setting isHidden on
  a prefix of it, which costs nothing and keeps the pure function of frame index
  property intact.

  Colour splits at the top of the backswing, blue going back and red coming down,
  which is the same convention and the same two hex values the 2D trace uses.
*/
@MainActor
public final class SwingTraceNode {

    public let node = SCNNode()
    private var segments: [SCNNode] = []
    private let head = SCNNode()
    private var pointCount = 0

    private static let backswing = UIColor(red: 0.302, green: 0.651, blue: 1.00, alpha: 1)
    private static let downswing = UIColor(red: 1.00, green: 0.231, blue: 0.188, alpha: 1)

    public init(
        series: WorldFrameSeries?,
        topFrame: Int?,
        radius: Float,
        /* An estimate is drawn with gaps, which is the 3D equivalent of the
           dashed stroke the 2D club path uses. */
        gapped: Bool,
        showHead: Bool
    ) {
        node.name = gapped ? "trace.estimated" : "trace.measured"
        guard let series, series.points.count >= 2 else { return }

        let points = series.points
        pointCount = points.count

        let backMaterial = Self.material(Self.backswing, gapped: gapped)
        let downMaterial = Self.material(Self.downswing, gapped: gapped)

        /* One geometry per colour, shared across every segment. Each segment
           still owns its transform, so length and direction vary freely while
           the geometry allocation stays at two. */
        let backGeometry = SCNCylinder(radius: CGFloat(radius), height: 1)
        backGeometry.radialSegmentCount = 8
        backGeometry.firstMaterial = backMaterial
        let downGeometry = SCNCylinder(radius: CGFloat(radius), height: 1)
        downGeometry.radialSegmentCount = 8
        downGeometry.firstMaterial = downMaterial

        for k in 0..<(points.count - 1) {
            /* Every other segment is dropped on an estimated path, which reads
               as a dashed line from any angle. */
            if gapped, k % 2 == 1 {
                segments.append(SCNNode())
                continue
            }
            let a = points[k].p
            let b = points[k + 1].p
            let isBack = topFrame.map { points[k].i <= $0 } ?? true
            guard let result = Orientation.transform(
                from: a,
                to: b,
                /* A trace segment is a cylinder, so its roll is invisible and any
                   stable reference will do. */
                rollReference: SIMD3(0, 1, 0)
            ) else {
                segments.append(SCNNode())
                continue
            }
            let n = SCNNode(geometry: isBack ? backGeometry : downGeometry)
            n.simdTransform = result.matrix
            n.isHidden = true
            segments.append(n)
            node.addChildNode(n)
        }

        if showHead {
            let g = SCNSphere(radius: CGFloat(radius * 2.1))
            g.segmentCount = 12
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = UIColor.white
            g.firstMaterial = m
            head.geometry = g
            head.isHidden = true
            head.renderingOrder = 12
            node.addChildNode(head)
        }

        self.seriesRef = series
    }

    private var seriesRef: WorldFrameSeries?

    /* Reveal the portion of the path that has happened by this frame. */
    public func apply(frameIndex: Int) {
        guard let seriesRef, !segments.isEmpty else { return }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        defer { SCNTransaction.commit() }

        let visible = seriesRef.countAt(frameIndex)
        for (k, segment) in segments.enumerated() {
            segment.isHidden = k >= max(0, visible - 1)
        }

        if head.geometry != nil {
            if visible >= 1, visible <= pointCount {
                head.simdPosition = seriesRef.points[visible - 1].p
                head.isHidden = false
            } else {
                head.isHidden = true
            }
        }
    }

    private static func material(_ colour: UIColor, gapped: Bool) -> SCNMaterial {
        let m = SCNMaterial()
        /* constant means unlit, so a trace keeps the same colour wherever it
           travels around the body instead of dimming as it turns away from the
           key light. A trace is annotation, not anatomy. */
        m.lightingModel = .constant
        m.diffuse.contents = gapped ? colour.withAlphaComponent(0.75) : colour
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = true
        return m
    }
}
