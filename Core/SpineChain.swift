//
//  SpineChain.swift
//  Swingline
//
//  The articulated spine, computed from the landmarks the tracker actually
//  measures. MediaPipe reports no spine joints at all, only hips (23, 24)
//  and shoulders (11, 12), which is why the rig has been drawing the torso
//  as ONE rigid segment from the hip centre to the shoulder centre: with a
//  single segment there is nothing to bend, so the figure looks like a
//  plank swinging a stick, and every coaching cue about posture, side bend
//  and thoracic rotation has nothing on screen to point at.
//
//  This file derives a four-joint chain, pelvis, lumbar, thoracic and
//  cervical, from the measured hip and shoulder lines, plus per-joint
//  LATERAL AXES that distribute the measured axial twist up the chain. The
//  positions bend the spine's line; the axes bend its ROLL, so a torso
//  built from stacked segments shows the X factor as an actual wind-up
//  between its lower and upper parts rather than as a rigid block jump.
//
//  WHAT IS ASSERTED AND WHAT IS MEASURED, the house distinction:
//
//    MEASURED: the pelvis centre, the shoulder (cervical base) centre, the
//    hip line direction, the shoulder line direction, and the head centre
//    when the ears carry it. Everything the chain returns is interpolated
//    between these measurements.
//
//    ASSERTED: only the interpolation weights, i.e. where along the spine
//    the lumbar and thoracic joints sit (anatomical fractions) and how
//    much of the total axial twist each level carries. The defaults follow
//    the standard distribution (the lumbar spine contributes little axial
//    rotation, the thoracic most of it): lumbar about a third of the
//    hip-to-shoulder twist, thoracic about two thirds, cervical all of it.
//    No position is ever invented off the measured spine line by default;
//    the optional sagittal bow ships at zero.
//
//  INTEGRATION (HumanoidLoader):
//
//    1. In HumanoidRig, replace the single torso segment with three
//       stacked segments: pelvis to lumbar, lumbar to thoracic, thoracic
//       to cervical. Size them off the same RigScale the torso used.
//
//    2. In apply(world:), call
//
//           guard let chain = SpineChain.build(world: world) else { ... }
//
//       and place each segment between its two chain positions, orienting
//       its local x axis along the joint's `lateral` and its local y along
//       the segment direction (the usual look-at plus roll). The lateral
//       axes are what make the wind-up visible; a segment aligned by
//       position alone would still read rigid in roll.
//
//    3. The neck: run the cervical position toward chain.headBase (the
//       mid-ear point when measured, nil otherwise) instead of toward the
//       nose, which sits forward of the neck and used to tip the head
//       segment.
//
//    4. Keep drawing NOTHING for the palm. The backend moves the index
//       and pinky knuckles (hand collapse guard) for the analytics, but
//       the rendered hand ends at the wrist per the design: a palm node
//       was never part of the figure and this chain adds none.
//
//  House rule: no em dashes anywhere.
//

import Foundation

public enum SpineChain {

    /// One joint of the chain: where it sits, and the lateral (left to
    /// right) axis at that level after the twist distribution. The axis is
    /// unit length and perpendicular to the local spine direction.
    public struct Joint {
        public var position: Vec3
        public var lateral: Vec3
    }

    /// The articulated spine for one frame.
    public struct Chain {
        /// Pelvis centre (the hip midpoint), the chain's root.
        public var pelvis: Joint
        /// Lumbar joint, a third of the way up the measured spine line.
        public var lumbar: Joint
        /// Thoracic joint, two thirds of the way up.
        public var thoracic: Joint
        /// Cervical base (the shoulder midpoint), the chain's top.
        public var cervical: Joint
        /// The caller-supplied head centre (see build), passed through for
        /// aiming the neck segment. Nil when the head was not there to
        /// measure, in which case the rig should keep its previous aim
        /// rather than inventing one.
        public var headBase: Vec3?

        public var joints: [Joint] { [pelvis, lumbar, thoracic, cervical] }
    }

    /// Where along the pelvis-to-cervical line the two interior joints
    /// sit, and how much of the measured axial twist each of the four
    /// levels carries. Anatomical defaults; override for stylised rigs.
    public struct Config {
        public var lumbarHeightFraction: Double = 0.35
        public var thoracicHeightFraction: Double = 0.68
        public var twistFractions: (pelvis: Double, lumbar: Double, thoracic: Double, cervical: Double) = (0, 0.3, 0.65, 1)
        /// Optional forward bow of the interior joints, as a fraction of
        /// the spine length, along the body-forward axis. Zero by
        /// default: the bow is an assertion, not a measurement.
        public var sagittalBowFraction: Double = 0
        public init() {}
    }

    // MARK: - Build

    /// The chain for one frame's WORLD landmarks. Returns nil when the
    /// four torso landmarks were not all measured, which is the honest
    /// answer; the rig should hold its last chain rather than guess.
    ///
    /// headCentre is caller-supplied on purpose: the natural choice is
    /// the mid-ear point (in HumanoidLoader, something like the midpoint
    /// of the two ear landmarks when both are finite), but this file
    /// asserts nothing about which head landmarks the project's enum
    /// carries. Pass nil and the chain simply reports no head base.
    public static func build(world: LandmarkSet, headCentre: Vec3? = nil, config: Config = Config()) -> Chain? {
        guard world.count > Landmarks.RIGHT_HIP else { return nil }
        guard
            let lh = finite(world[Landmarks.LEFT_HIP]),
            let rh = finite(world[Landmarks.RIGHT_HIP]),
            let ls = finite(world[Landmarks.LEFT_SHOULDER]),
            let rs = finite(world[Landmarks.RIGHT_SHOULDER])
        else { return nil }

        let pelvis = mid(lh, rh)
        let cervical = mid(ls, rs)

        var axis = sub(cervical, pelvis)
        let spineLength = len(axis)
        guard spineLength > 1e-6 else { return nil }
        axis = scale(axis, 1 / spineLength)

        // The measured lateral directions at the two ends, made
        // perpendicular to the spine axis so the twist below is a pure
        // rotation about it. Right to left on both lines, so the two
        // directions agree about which way "left" points.
        guard
            let hipLateral = perpendicularised(sub(lh, rh), to: axis),
            let shoulderLateral = perpendicularised(sub(ls, rs), to: axis)
        else { return nil }

        // The measured axial twist from hip line to shoulder line, signed
        // about the spine axis. This IS the X factor, per frame, in the
        // torso's own frame of reference.
        let twist = signedAngle(from: hipLateral, to: shoulderLateral, about: axis)

        // The optional bow direction: body-forward, perpendicular to both
        // the spine axis and the hip line.
        let forward = normalised(cross(hipLateral, axis))

        func joint(heightFraction t: Double, twistFraction w: Double) -> Joint {
            var p = add(pelvis, scale(sub(cervical, pelvis), t))
            if config.sagittalBowFraction != 0, let f = forward {
                // A parabolic bow, zero at both ends, peaking mid spine.
                let bow = config.sagittalBowFraction * spineLength * 4 * t * (1 - t)
                p = add(p, scale(f, bow))
            }
            let lateral = rotated(hipLateral, about: axis, by: twist * w)
            return Joint(position: p, lateral: lateral)
        }

        return Chain(
            pelvis: joint(heightFraction: 0, twistFraction: config.twistFractions.pelvis),
            lumbar: joint(heightFraction: config.lumbarHeightFraction, twistFraction: config.twistFractions.lumbar),
            thoracic: joint(heightFraction: config.thoracicHeightFraction, twistFraction: config.twistFractions.thoracic),
            cervical: joint(heightFraction: 1, twistFraction: config.twistFractions.cervical),
            headBase: headCentre
        )
    }

    // MARK: - Small vector helpers
    //
    // Local on purpose: Geometry.v covers most of these, but this file is
    // meant to drop into the rig layer with no dependency beyond CoreTypes
    // and Landmarks, and the two extras (cross, rotation about an axis)
    // belong nowhere else yet.

    private static func finite(_ l: Landmark) -> Vec3? {
        guard l.x.isFinite, l.y.isFinite else { return nil }
        let z = l.z ?? 0
        return Vec3(x: l.x, y: l.y, z: z.isFinite ? z : 0)
    }
    private static func add(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.x + b.x, y: a.y + b.y, z: (a.z ?? 0) + (b.z ?? 0))
    }
    private static func sub(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.x - b.x, y: a.y - b.y, z: (a.z ?? 0) - (b.z ?? 0))
    }
    private static func scale(_ a: Vec3, _ k: Double) -> Vec3 {
        Vec3(x: a.x * k, y: a.y * k, z: (a.z ?? 0) * k)
    }
    private static func mid(_ a: Vec3, _ b: Vec3) -> Vec3 {
        scale(add(a, b), 0.5)
    }
    private static func len(_ a: Vec3) -> Double {
        let z = a.z ?? 0
        return (a.x * a.x + a.y * a.y + z * z).squareRoot()
    }
    private static func dot(_ a: Vec3, _ b: Vec3) -> Double {
        a.x * b.x + a.y * b.y + (a.z ?? 0) * (b.z ?? 0)
    }
    private static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
        let az = a.z ?? 0, bz = b.z ?? 0
        return Vec3(
            x: a.y * bz - az * b.y,
            y: az * b.x - a.x * bz,
            z: a.x * b.y - a.y * b.x
        )
    }
    private static func normalised(_ a: Vec3) -> Vec3? {
        let l = len(a)
        guard l > 1e-9 else { return nil }
        return scale(a, 1 / l)
    }

    /// The component of v perpendicular to the unit axis, normalised.
    private static func perpendicularised(_ v: Vec3, to axis: Vec3) -> Vec3? {
        let along = dot(v, axis)
        return normalised(sub(v, scale(axis, along)))
    }

    /// The signed angle from a to b about the unit axis, both a and b
    /// already perpendicular to it.
    private static func signedAngle(from a: Vec3, to b: Vec3, about axis: Vec3) -> Double {
        let cosA = Geometry.clamp(dot(a, b), -1, 1)
        let sinA = dot(cross(a, b), axis)
        return atan2(sinA, cosA)
    }

    /// Rodrigues rotation of unit vector v about the unit axis by angle.
    private static func rotated(_ v: Vec3, about axis: Vec3, by angle: Double) -> Vec3 {
        let c = cos(angle), s = sin(angle)
        let term1 = scale(v, c)
        let term2 = scale(cross(axis, v), s)
        let term3 = scale(axis, dot(axis, v) * (1 - c))
        return add(add(term1, term2), term3)
    }
}
