//
//  Biomechanics 2.swift
//  GOLF GPT
//
//  Created by Macintosh HD on 10/08/2026.
//


import Foundation

/*
  Biomechanics layer.

  Input is a list of captured frames:
    { t: milliseconds, world: [33 metric points], norm: [33 image points], conf }

  Output is a bundle of time series that every later stage reads from. Nothing
  above this layer touches raw landmarks again.

  A note on honesty: a single camera cannot measure ground reaction force. What
  it can measure is where the centre of mass sits over the base of support and
  how that changes through the swing, which is the visible consequence of the
  force. The app calls this pressure and never claims to be a force plate.

  Translated from packages/core/src/biomechanics.ts.
*/

public enum Biomechanics {

    /* Dempster segment mass fractions, summing to 1. Used for the centre of mass
       proxy. Two decimal places is well beyond the precision the pose data
       supports, but the relative weighting is what matters. */
    private static let MASS_HEAD = 0.081
    private static let MASS_TRUNK = 0.497
    private static let MASS_UPPER_ARM = 0.028
    private static let MASS_FOREARM_HAND = 0.022
    private static let MASS_THIGH = 0.1
    private static let MASS_SHANK_FOOT = 0.061

    public static func centreOfMass(_ landmarks: [Landmark]) -> Vec3 {
        let midShoulder = Geometry.v.mid(landmarks[Landmarks.LEFT_SHOULDER].vec, landmarks[Landmarks.RIGHT_SHOULDER].vec)
        let midHip = Geometry.v.mid(landmarks[Landmarks.LEFT_HIP].vec, landmarks[Landmarks.RIGHT_HIP].vec)
        let parts: [(Vec3, Double)] = [
            (landmarks[Landmarks.NOSE].vec, MASS_HEAD),
            (Geometry.v.mid(midShoulder, midHip), MASS_TRUNK),
            (Geometry.v.mid(landmarks[Landmarks.LEFT_SHOULDER].vec, landmarks[Landmarks.LEFT_ELBOW].vec), MASS_UPPER_ARM),
            (Geometry.v.mid(landmarks[Landmarks.RIGHT_SHOULDER].vec, landmarks[Landmarks.RIGHT_ELBOW].vec), MASS_UPPER_ARM),
            (Geometry.v.mid(landmarks[Landmarks.LEFT_ELBOW].vec, landmarks[Landmarks.LEFT_WRIST].vec), MASS_FOREARM_HAND),
            (Geometry.v.mid(landmarks[Landmarks.RIGHT_ELBOW].vec, landmarks[Landmarks.RIGHT_WRIST].vec), MASS_FOREARM_HAND),
            (Geometry.v.mid(landmarks[Landmarks.LEFT_HIP].vec, landmarks[Landmarks.LEFT_KNEE].vec), MASS_THIGH),
            (Geometry.v.mid(landmarks[Landmarks.RIGHT_HIP].vec, landmarks[Landmarks.RIGHT_KNEE].vec), MASS_THIGH),
            (Geometry.v.mid(landmarks[Landmarks.LEFT_KNEE].vec, landmarks[Landmarks.LEFT_ANKLE].vec), MASS_SHANK_FOOT),
            (Geometry.v.mid(landmarks[Landmarks.RIGHT_KNEE].vec, landmarks[Landmarks.RIGHT_ANKLE].vec), MASS_SHANK_FOOT),
        ]
        var acc = Vec3(x: 0, y: 0, z: 0)
        for (p, m) in parts {
            acc = Geometry.v.add(acc, Geometry.v.scale(p, m))
        }
        return acc
    }

    public struct PressureReading {
        public var value: Double
        public var valid: Bool
    }

    /*
      Where the centre of mass sits across the base of support.
      0 means fully over the trail ankle, 1 means fully over the lead ankle.

      The guard here used to be a tenth of a millimetre, which is not a guard at
      all. Filmed down the line the two ankles sit almost on top of each other along
      the camera's x axis, the span collapses toward zero, and dividing by it threw
      out readings like 336 and 643 percent front foot. The span now has to be a
      real fraction of the golfer's own shoulder width before the number means
      anything, and when it is not, this says so rather than returning a figure
      nobody should trust.
    */
    public static func pressureIndex(_ landmarks: [Landmark], _ S: Sides, _ scale: Double = 0.4) -> PressureReading {
        let com = centreOfMass(landmarks)
        let lead = landmarks[S.leadAnkle].vec
        let trail = landmarks[S.trailAnkle].vec
        let span = lead.x - trail.x

        /* Under about a third of a shoulder width there is not enough separation
           between the feet on screen to place the centre of mass between them. */
        if abs(span) < scale * 0.33 { return PressureReading(value: 0.5, valid: false) }

        let raw = (com.x - trail.x) / span
        return PressureReading(
            /* Clamped to just outside the feet. A centre of mass beyond that is a
               tracking failure, not a golfer leaning. */
            value: Geometry.clamp(raw, -0.25, 1.25),
            valid: raw > -0.5 && raw < 1.5
        )
    }

    public static func buildSeries(_ frames: [Frame], _ dominantHand: DominantHand = .right) -> SwingSeries {
        let S = Landmarks.sides(dominantHand)
        let n = frames.count
        let t = frames.map { $0.t }

        /* Shoulder width from the first usable frame, used to judge whether other
           measurements are on a sensible scale for this golfer. */
        let scale = bodyScale(frames)

        var rawPelvis: [Double] = []
        var rawTorso: [Double] = []
        var pressureValid: [Bool] = []
        var shoulderSpanImage: [Double] = []
        var spineTilt: [Double] = []
        var headX: [Double] = []
        var headY: [Double] = []
        var pressure: [Double] = []
        var comX: [Double] = []
        var comY: [Double] = []
        var handPos: [Vec3] = []
        var handY: [Double] = []
        var leadArmVec: [Vec3] = []
        var trailKneeFlex: [Double] = []
        var leadElbowAngle: [Double] = []
        var stanceWidths: [Double] = []

        /*
          Left and right flip guard.

          Pose trackers periodically swap which shoulder is anatomically left and
          which is right, most often when somebody is filmed from behind or in
          profile where the limbs occlude each other. A single swap inverts the body
          line by 180 degrees, and a turn that is really 90 degrees then reads as
          close to 180. That is where 177 degrees of shoulder turn came from.

          The speed limiter added previously did not help, because it is a smoother,
          not a validator: it slowed the drift toward the wrong value instead of
          refusing it. A body cannot rotate 120 degrees in a single frame at any
          frame rate this app runs at, so a step that large is a swap, and the line
          is negated to undo it rather than followed.

          The flip rate is counted, because a clip that needs constant correction is
          one whose rotation numbers should not be trusted at all.
        */
        var prevHipDir: Vec3? = nil
        var prevShoulderDir: Vec3? = nil
        var flipCount = 0

        func deflip(_ line: Vec3, _ prev: Vec3?) -> (line: Vec3, flipped: Bool) {
            guard let prev = prev else { return (line, false) }
            if Geometry.angleBetween(line, prev) > 120 { return (Geometry.v.scale(line, -1), true) }
            return (line, false)
        }

        for i in 0..<n {
            let w = frames[i].world

            let hip = deflip(Geometry.v.sub(w[S.leadHip].vec, w[S.trailHip].vec), prevHipDir)
            let shoulder = deflip(Geometry.v.sub(w[S.leadShoulder].vec, w[S.trailShoulder].vec), prevShoulderDir)
            if hip.flipped || shoulder.flipped { flipCount += 1 }
            prevHipDir = hip.line
            prevShoulderDir = shoulder.line

            let hipLine = hip.line
            let shoulderLine = shoulder.line
            rawPelvis.append(Geometry.transverseAngle(hipLine))
            rawTorso.append(Geometry.transverseAngle(shoulderLine))

            let midShoulder = Geometry.v.mid(w[Landmarks.LEFT_SHOULDER].vec, w[Landmarks.RIGHT_SHOULDER].vec)
            let midHip = Geometry.v.mid(w[Landmarks.LEFT_HIP].vec, w[Landmarks.RIGHT_HIP].vec)
            spineTilt.append(Geometry.tiltFromVertical(Geometry.v.sub(midShoulder, midHip)))

            headX.append(w[Landmarks.NOSE].x)
            headY.append(w[Landmarks.NOSE].y)

            let com = centreOfMass(w)
            comX.append(com.x)
            comY.append(com.y)
            let p = pressureIndex(w, S, scale)
            pressure.append(p.value)
            pressureValid.append(p.valid)

            let wrist = w[S.leadWrist].vec
            handPos.append(Vec3(x: wrist.x, y: wrist.y, z: wrist.z ?? 0))
            /* World y points down, so negating gives an intuitive height. */
            handY.append(-wrist.y)

            leadArmVec.append(Geometry.v.sub(w[S.leadWrist].vec, w[S.leadShoulder].vec))
            trailKneeFlex.append(180 - Geometry.angleBetween(
                Geometry.v.sub(w[S.trailHip].vec, w[S.trailKnee].vec),
                Geometry.v.sub(w[S.trailAnkle].vec, w[S.trailKnee].vec)
            ))
            leadElbowAngle.append(Geometry.angleBetween(
                Geometry.v.sub(w[S.leadShoulder].vec, w[S.leadElbow].vec),
                Geometry.v.sub(w[S.leadWrist].vec, w[S.leadElbow].vec)
            ))
            stanceWidths.append(abs(w[S.leadAnkle].x - w[S.trailAnkle].x))

            /* How wide the shoulders appear in the picture. Independent of the depth
               channel, so it is a useful second opinion on how far the golfer has
               turned and on which way the camera is pointing. */
            let normLm = frames[i].norm
            shoulderSpanImage.append(normLm.isEmpty ? 0 : abs(normLm[S.leadShoulder].x - normLm[S.trailShoulder].x))
        }

        /*
          Smooth, then differentiate. Never the other way round.

          Both lines are tracked as speed limited continuous angles rather than
          plainly unwrapped, so a wrap flip in noisy pose data cannot inject a full
          turn that never happened.
        */
        let pelvis = Geometry.savitzkyGolay(Geometry.continuousAngle(rawPelvis, t))
        let torso = Geometry.savitzkyGolay(Geometry.continuousAngle(rawTorso, t))

        /* Separation is a difference between two separately tracked bodies, so it
           has to be wrapped. Without this the two baselines can sit a full turn
           apart and report 341 degrees of separation between parallel lines. */
        var xFactor = [Double](repeating: 0, count: pelvis.count)
        for i in 0..<pelvis.count { xFactor[i] = Geometry.wrapDeg(torso[i] - pelvis[i]) }

        let pelvisVel = Geometry.derivative(pelvis, t)
        let torsoVel = Geometry.derivative(torso, t)

        /* Lead arm and club use a 3D rotation rate rather than a projected angle.
           The arm swings well out of the ground plane, so a transverse projection
           would understate its speed by a large factor near the top. */
        var armVel = [Double](repeating: 0, count: n)
        if n > 1 {
            for i in 1..<n {
                let dt = (t[i] - t[i - 1]) / 1000
                armVel[i] = dt > 1e-6 ? Geometry.angleBetween(leadArmVec[i], leadArmVec[i - 1]) / dt : 0
            }
        }

        /* Hand speed stands in for club head speed. Without a club tracker this is
           the most defensible proxy available, and the sequence check only needs
           the timing of the peak, not its absolute value. */
        var handSpeed = [Double](repeating: 0, count: n)
        if n > 1 {
            for i in 1..<n {
                let dt = (t[i] - t[i - 1]) / 1000
                handSpeed[i] = dt > 1e-6 ? Geometry.v.dist(handPos[i], handPos[i - 1]) / dt : 0
            }
        }

        let finalPelvis = pelvis
        let finalTorso = torso

        /*
          Per frame world space paths of the pelvis and torso centres, up
          positive so Y is negated. These need no phase indices, so they are
          filled here; the address to top deltas the stability metrics report are
          computed later by SwingSeries.fillStability, once phases exist.
        */
        let pelvisAbsX = frames.map { Geometry.v.mid($0.world[Landmarks.LEFT_HIP].vec, $0.world[Landmarks.RIGHT_HIP].vec).x }
        let pelvisAbsY = frames.map { -Geometry.v.mid($0.world[Landmarks.LEFT_HIP].vec, $0.world[Landmarks.RIGHT_HIP].vec).y }
        let torsoAbsX = frames.map { Geometry.v.mid($0.world[Landmarks.LEFT_SHOULDER].vec, $0.world[Landmarks.RIGHT_SHOULDER].vec).x }
        let torsoAbsY = frames.map { -Geometry.v.mid($0.world[Landmarks.LEFT_SHOULDER].vec, $0.world[Landmarks.RIGHT_SHOULDER].vec).y }
        let torsoAbsZ = frames.map { (Geometry.v.mid($0.world[Landmarks.LEFT_SHOULDER].vec, $0.world[Landmarks.RIGHT_SHOULDER].vec).z ?? 0) }

        /*
          Lead wrist control proxies from the body landmarks. The lead hand's
          index and pinky give two finger directions off the wrist; their mean
          cock relative to the forearm is deviation (radial or ulnar), and the
          roll between the two sides is a flexion proxy (bowed or cupped). One
          camera resolves one in plane angle, so these two are correlated, not
          independent, which is why both are marked depth sensitive. Smoothed the
          same way as the other angle tracks.
        */
        let leadIndex = S.leadWrist == Landmarks.LEFT_WRIST ? Landmarks.LEFT_INDEX : Landmarks.RIGHT_INDEX
        let leadPinky = S.leadWrist == Landmarks.LEFT_WRIST ? Landmarks.LEFT_PINKY : Landmarks.RIGHT_PINKY
        func signedAngle(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Double {
            let cross = ax * by - ay * bx
            let dot = ax * bx + ay * by
            return atan2(cross, dot) * 180.0 / Double.pi
        }
        var rawFlex = [Double](repeating: 0, count: n)
        var rawDev = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let nrm = frames[i].norm
            let elbow = nrm[S.leadElbow], wrist = nrm[S.leadWrist]
            let index = nrm[leadIndex], pinky = nrm[leadPinky]
            let fx = wrist.x - elbow.x, fy = wrist.y - elbow.y            // forearm
            let ix = index.x - wrist.x, iy = index.y - wrist.y           // index ray
            let px = pinky.x - wrist.x, py = pinky.y - wrist.y           // pinky ray
            let aIndex = signedAngle(fx, fy, ix, iy)
            let aPinky = signedAngle(fx, fy, px, py)
            rawDev[i] = (aIndex + aPinky) / 2                            // both cock together
            rawFlex[i] = (aIndex - aPinky) / 2                          // hand plane roll
        }
        let leadWristDeviation = Geometry.savitzkyGolay(rawDev)
        let leadWristFlexion = Geometry.savitzkyGolay(rawFlex)

        return SwingSeries(
            t: t,
            n: n,
            sides: S,
            pelvis: finalPelvis,
            torso: finalTorso,
            xFactor: xFactor,
            pelvisSpeed: Geometry.savitzkyGolay(pelvisVel.map { abs($0) }),
            torsoSpeed: Geometry.savitzkyGolay(torsoVel.map { abs($0) }),
            armSpeed: Geometry.savitzkyGolay(armVel),
            handSpeed: Geometry.savitzkyGolay(handSpeed),
            pelvisVel: pelvisVel,
            torsoVel: torsoVel,
            spineTilt: spineTilt,
            headX: headX,
            headY: headY,
            comX: comX,
            comY: comY,
            pressure: Geometry.savitzkyGolay(pressure),
            pressureValid: pressureValid,
            pressureValidFraction: Double(pressureValid.filter { $0 }.count) / Double(n == 0 ? 1 : n),
            /* Above roughly one frame in seven needing a flip correction, the rotation
               track is being held together by guesswork and should not be shown. */
            flipFraction: Double(flipCount) / Double(n == 0 ? 1 : n),
            rotationReliable: Double(flipCount) / Double(n == 0 ? 1 : n) < 0.15,
            shoulderSpanImage: shoulderSpanImage,
            scale: scale,
            handPos: handPos,
            handY: Geometry.savitzkyGolay(handY),
            leadElbowAngle: leadElbowAngle,
            trailKneeFlex: trailKneeFlex,
            stanceWidth: median(stanceWidths),
            /* Turn measured from a reference frame rather than as an absolute
               orientation. The interface used to print the absolute transverse angle
               under the label "shoulder turn", which is how 187 degrees of shoulder
               turn ended up on screen. */
            turnFrom: { refIndex in
                (
                    pelvis: finalPelvis.map { Geometry.wrapDeg($0 - finalPelvis[refIndex]) },
                    torso: finalTorso.map { Geometry.wrapDeg($0 - finalTorso[refIndex]) }
                )
            },
            confidence: frames.reduce(0.0) { $0 + $1.conf } / Double(n == 0 ? 1 : n),
            pelvisAbsX: pelvisAbsX,
            pelvisAbsY: pelvisAbsY,
            torsoAbsX: torsoAbsX,
            torsoAbsY: torsoAbsY,
            torsoAbsZ: torsoAbsZ,
            armAngularVel: armVel,
            leadWristFlexion: leadWristFlexion,
            leadWristDeviation: leadWristDeviation
        )
    }

    private static func median(_ arr: [Double]) -> Double {
        if arr.isEmpty { return 0 }
        let s = arr.sorted()
        return s[s.count / 2]
    }

    /*
      The golfer's size, used to normalise every distance and speed so the numbers
      hold whatever the camera distance.

      Taken as the median across every frame that has world data, not from the
      first frame. Reading frame zero was fragile in a way that only showed up once
      subject selection existed: selection can legitimately return no detection for
      the opening frames, since the golfer may not be in shot or confidently found
      yet, and a null there made this return NaN. Every speed divided by it then
      became NaN, and a NaN speed compares false against every threshold, so the
      swing finder reported that the hands were never moving fast enough. A real
      swing was rejected because of the first frame.

      The median also shrugs off the odd bad frame, which the first-frame version
      could not do by construction.
    */
    public static func bodyScale(_ frames: [Frame]) -> Double {
        if frames.isEmpty { return 0.4 }
        var widths: [Double] = []
        for f in frames {
            let w = f.world
            guard Landmarks.LEFT_SHOULDER < w.count, Landmarks.RIGHT_SHOULDER < w.count else { continue }
            let a = w[Landmarks.LEFT_SHOULDER].vec
            let b = w[Landmarks.RIGHT_SHOULDER].vec
            let d = Geometry.v.dist(a, b)
            if d.isFinite && d > 0.05 { widths.append(d) }
        }
        if widths.isEmpty { return 0.4 }
        widths.sort()
        return max(0.2, widths[widths.count / 2])
    }

    /* The angle of the shoulder line relative to the ground when viewed down the
       line, a usable stand in for swing plane steepness at the top. */
    public static func shoulderPlaneTilt(_ landmarks: [Landmark]) -> Double {
        let line = Geometry.v.sub(landmarks[Landmarks.LEFT_SHOULDER].vec, landmarks[Landmarks.RIGHT_SHOULDER].vec)
        return Geometry.deg(atan2(-line.y, (line.x * line.x + (line.z ?? 0) * (line.z ?? 0)).squareRoot()))
    }

    public struct ApparentWidthTurn {
        public var turn: [Double]
        public var reference: Double
    }

    /*
      Shoulder turn from apparent width.

      The depth channel is the least reliable thing a single camera produces, and
      the whole rotation measurement was resting on it. Horizontal position in the
      image is the most reliable thing it produces. This estimator uses only the
      latter.

      As a golfer turns away from a face on camera, the distance between their
      shoulders in the picture shrinks by the cosine of the turn. Squared up it is
      at its widest, at ninety degrees it is almost nothing. So the ratio of the
      current span to the span at address recovers the turn directly, with no depth
      involved at all.

      Two honest limits. It cannot tell a turn one way from a turn the other, so the
      direction is taken from the depth based estimate, which is unreliable in
      magnitude but adequate for sign. And it only works from a face on angle,
      filmed down the line the shoulders start already foreshortened, the span at
      address is near zero, and the ratio means nothing. It is used where it applies
      and ignored where it does not.
    */
    public static func turnFromApparentWidth(_ series: SwingSeries, _ phases: PhaseResult, _ signSource: [Double]?) -> ApparentWidthTurn? {
        let spans = series.shoulderSpanImage
        if spans.isEmpty { return nil }

        /* Reference taken as the widest span in the first stretch of the clip rather
           than the single address frame, so one bad frame cannot set the baseline. */
        let p2 = phases.idx[.p2] ?? 8
        let upTo = max(3, min(p2 == 0 ? 8 : p2, spans.count - 1))
        let reference = spans[0...upTo].max() ?? 0
        if !(reference > 0.02) { return nil }

        var out = [Double](repeating: 0, count: spans.count)
        for i in 0..<spans.count {
            let ratio = Geometry.clamp(spans[i] / reference, 0, 1)
            let magnitude = Geometry.deg(acos(ratio))
            let sign: Double = (signSource != nil && i < signSource!.count && signSource![i] < 0) ? -1 : 1
            out[i] = magnitude * sign
        }
        return ApparentWidthTurn(turn: out, reference: reference)
    }
}
// MARK: - Depth validity (Task 1.F)

/* A plain 2D point in normalised image space, for the depth validity check. */
public struct Point2D {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

extension Biomechanics {
    /*
      Is the tracked 3D depth channel trustworthy for this clip?

      The idea: a landmark's motion should look about as smooth in 3D as it does
      in 2D. When the depth estimate is unreliable, the Z channel adds jitter
      that is not present in the well tracked image plane, so the 3D path is much
      noisier than the 2D path for the same joint. The lead wrist is used because
      it is the fastest moving, best tracked landmark in the swing.

      Correction over the original draft. That version compared the raw jitter of
      2D against 3D, but 2D here is normalised image space and 3D is metric world
      space, so the two RMS numbers were in different units and the ratio was
      meaningless. This compares a dimensionless jitter fraction instead, the
      high frequency residual over the typical speed, which is unitless in both
      spaces and so comparable. The unused lead shoulder parameters from that
      draft are dropped.

      Returns true when the 3D jitter fraction is within threshold times the 2D
      one, false when depth is too noisy to trust or there is too little data.
    */
    public static func is3DValid(
        leadWrist2D: [Point2D],
        leadWrist3D: [Vec3],
        times: [TimeInterval],
        threshold: Double = 2.0
    ) -> Bool {
        guard leadWrist2D.count > 3, leadWrist3D.count > 3 else { return false }

        // Frame to frame speed magnitudes in each space.
        var v2D: [Double] = []
        for i in 1..<leadWrist2D.count {
            let dx = leadWrist2D[i].x - leadWrist2D[i - 1].x
            let dy = leadWrist2D[i].y - leadWrist2D[i - 1].y
            v2D.append((dx * dx + dy * dy).squareRoot())
        }
        var v3D: [Double] = []
        for i in 1..<leadWrist3D.count {
            let dx = leadWrist3D[i].x - leadWrist3D[i - 1].x
            let dy = leadWrist3D[i].y - leadWrist3D[i - 1].y
            let dz = (leadWrist3D[i].z ?? 0) - (leadWrist3D[i - 1].z ?? 0)
            v3D.append((dx * dx + dy * dy + dz * dz).squareRoot())
        }
        guard v2D.count >= 3, v3D.count >= 3 else { return false }

        // High frequency residual: what a heavy smooth throws away. Only the
        // window width comes from times, so the length mismatch with the speed
        // arrays is fine.
        let smooth2D = Geometry.savitzkyGolayMs(v2D, times, 200)
        let smooth3D = Geometry.savitzkyGolayMs(v3D, times, 200)
        let hf2D = zip(v2D, smooth2D).map { $0 - $1 }
        let hf3D = zip(v3D, smooth3D).map { $0 - $1 }

        let rms2D = rms(hf2D)
        let rms3D = rms(hf3D)

        // Dimensionless jitter fraction: residual over typical speed in the same
        // space, so the comparison is unit free.
        let speed2D = mean(v2D)
        let speed3D = mean(v3D)
        guard speed2D > 1e-9, speed3D > 1e-9 else { return false }
        let jitter2D = rms2D / speed2D
        let jitter3D = rms3D / speed3D

        return jitter3D <= threshold * jitter2D
    }

    private static func rms(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return (values.reduce(0) { $0 + $1 * $1 } / Double(values.count)).squareRoot()
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
