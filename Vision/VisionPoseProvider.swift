import Foundation
import Vision
import CoreMedia

/*
  Vision backed pose provider.

  THE CONTRACT THIS FILE OWES EVERYTHING DOWNSTREAM.

  Landmarks.swift documents a thirty three slot MediaPipe index map, and every
  consumer reads against it. Biomechanics indexes slot 23 for the left hip,
  Phases indexes the lead wrist, Validity indexes the shoulders. None of them
  bounds check, because the contract says the array is always thirty three long.

  The previous version returned a thirteen element array. That is what crashed
  the app: slot 23 did not exist. The fix is not to teach each consumer to cope
  with a short array, it is to honour the contract here, at the one place the
  two worlds meet.

  So this returns thirty three slots on every frame. The joints Vision reports
  are filled in. The joints Vision does not have, and there are twenty of them,
  are written in as placeholders at visibility zero, which every consumer already
  reads as "this joint was not seen". That is true, and it is the same thing
  MediaPipe reports for a joint it lost.

  WHAT VISION GENUINELY CANNOT GIVE, stated rather than faked.

  No per joint confidence. VNHumanBodyRecognizedPoint3D carries a position and a
  parent joint and nothing else. Confidence exists only on the observation as a
  whole, so that one number is written onto the frame and every mapped joint is
  left with a nil visibility. Validity.trust() reads a nil visibility as "fall
  back to the frame's confidence", which is honest. Writing an invented 0.9 onto
  each joint would not be.

  No heels, no foot indices, no hands beyond the wrist, no face beyond the head.
  Anything reading those slots gets a zero visibility placeholder. That matters
  for the overlay, which draws heels and foot indices: those bones will be
  missing on iOS until there is a second source for them.

  House rule: no em dashes anywhere.
*/

public final class VisionPoseProvider: PoseProvider {

    private let options: PoseProviderOptions
    private var closed = false

    /*
      Live path stabilisation state.

      Applied only in the instance detect (the live preview), never in the static
      upload path, which stays pure and whose clip is smoothed properly downstream
      by the Savitzky Golay pass in buildSeries. Kept per instance because a
      capture session owns one provider and delivers frames one at a time on its
      queue.

      Only the clamp and the short moving average from the brief are implemented.
      ROI and largest person selection are deliberately left out: Vision's 3D
      request returns a single observation with no bounding box, so neither has
      anything to act on here, and subject selection is already golferSelect's
      job at the clip level.
    */
    private var prevWorld: LandmarkSet?
    private var prevNorm: LandmarkSet?
    private var worldHistory: [LandmarkSet] = []
    private var normHistory: [LandmarkSet] = []
    private let historySize = 3
    // A joint that jumps more than this between frames is treated as a tracking
    // glitch and held at its previous position. Metres in world space.
    private let maxJumpMetres = 0.5

    // Reference bone lengths, learned once from the first steady frames, then
    // held for the rest of the clip to keep the limbs rigid.
    private var referenceBoneLengths: [String: Double] = [:]
    private var boneLengthSamples: [[String: Double]] = []

    /*
      One Euro filters for the live path, one bank for the world array and one for
      the image array. Tuned to smooth stillness firmly and let a fast downswing
      through: a low base cutoff with a speed term. These run instead of the plain
      moving average when a timestamp is available.
    */
    private let worldFilter = OneEuroVectorFilter(minCutoff: 1.2, beta: 0.02, dCutoff: 1.0)
    private let normFilter = OneEuroVectorFilter(minCutoff: 1.2, beta: 0.02, dCutoff: 1.0)

    // The learned floor: the lowest the ankles sat in the first steady frames, so
    // a later frame's ankle cannot snap far below it into the ground.
    private var floorWorldY: Double?
    private var floorSamples: [Double] = []

    public init(options: PoseProviderOptions = PoseProviderOptions()) {
        self.options = options
    }

    /*
      Vision's 3D body pose request returns one person. The web build asks
      MediaPipe for three candidates and golferSelect picks among them, and that
      whole strategy has nothing to select among here. Reported honestly as 1
      rather than echoing back what the caller asked for.
    */
    public var maxPeople: Int { 1 }

    // MARK: - Joint map

    /*
      Vision joint to MediaPipe slot.

      Vision reports seventeen joints, of which thirteen map cleanly onto the
      MediaPipe indices the engine uses. The other four, root, spine, neck and
      top of head, have no MediaPipe equivalent and are dropped rather than
      guessed at.

      centerHead maps onto NOSE because NOSE is what the engine uses as the head
      reference, in Phases.HEAD_INDEX and in the head sway measurement. It is not
      the same anatomical point. Head sway is measured as a change from the
      address frame, so a constant offset between the two subtracts out, but the
      absolute head position on iOS is not the absolute head position on the web
      and the two builds should not be compared on that number.
    */
    private static let jointMap: [(VNHumanBodyPose3DObservation.JointName, Int)] = [
        (.centerHead, Landmarks.NOSE),
        (.leftShoulder, Landmarks.LEFT_SHOULDER),
        (.rightShoulder, Landmarks.RIGHT_SHOULDER),
        (.leftElbow, Landmarks.LEFT_ELBOW),
        (.rightElbow, Landmarks.RIGHT_ELBOW),
        (.leftWrist, Landmarks.LEFT_WRIST),
        (.rightWrist, Landmarks.RIGHT_WRIST),
        (.leftHip, Landmarks.LEFT_HIP),
        (.rightHip, Landmarks.RIGHT_HIP),
        (.leftKnee, Landmarks.LEFT_KNEE),
        (.rightKnee, Landmarks.RIGHT_KNEE),
        (.leftAnkle, Landmarks.LEFT_ANKLE),
        (.rightAnkle, Landmarks.RIGHT_ANKLE),
    ]

    /* Thirty three slots, all unseen. Filled in per frame. */
    private static let LANDMARK_COUNT = 33

    private static func emptySet() -> LandmarkSet {
        LandmarkSet(
            repeating: Landmark(x: 0, y: 0, z: 0, visibility: 0),
            count: LANDMARK_COUNT
        )
    }

    // MARK: - Detection

    public func detect(frame: CMSampleBuffer, timestampMs: Double) async throws -> [PersonDetection] {
        if closed { return [] }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(frame) else { return [] }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        let raw = try Self.detect(with: handler)
        guard let person = raw.first else {
            // Lost the golfer, so drop the history rather than averaging across
            // the gap, which would smear the pose back in when they return.
            prevWorld = nil
            prevNorm = nil
            worldHistory.removeAll()
            normHistory.removeAll()
            return raw
        }
        return [stabilise(person, timestampMs: timestampMs)]
    }

    /*
      Clamp glitchy jumps, then average over a few frames.

      Both spaces are treated together, world and normalised, so the metrics and
      the on screen skeleton never drift apart. A joint that leaps more than the
      threshold in world space is held at its previous world and normalised
      position for that frame, then a short moving average takes the last of the
      hand shake off.
    */
    private func stabilise(_ person: PersonDetection, timestampMs: Double) -> PersonDetection {
        var world = person.world
        var norm = person.norm

        if let pw = prevWorld, let pn = prevNorm, pw.count == world.count {
            for i in 0..<world.count {
                let a = Vec3(x: world[i].x, y: world[i].y, z: world[i].z)
                let b = Vec3(x: pw[i].x, y: pw[i].y, z: pw[i].z)
                if Geometry.v.dist(a, b) > maxJumpMetres {
                    world[i] = pw[i]
                    if i < norm.count && i < pn.count { norm[i] = pn[i] }
                }
            }
        }
        prevWorld = world
        prevNorm = norm

        /*
          Temporal smoothing.

          The One Euro filter smooths per coordinate against the frame time, which
          kills the still hand jitter Vision shows without lagging a fast swing. It
          replaces the old fixed three frame average on the live path. If the
          timestamp is not usable the average still runs as a fallback.
        */
        let seconds = timestampMs / 1000.0
        if seconds > 0 {
            world = applyFilter(worldFilter, to: world, timestamp: seconds, hasZ: true)
            norm = applyFilter(normFilter, to: norm, timestamp: seconds, hasZ: false)
        } else {
            worldHistory.append(world)
            normHistory.append(norm)
            if worldHistory.count > historySize { worldHistory.removeFirst() }
            if normHistory.count > historySize { normHistory.removeFirst() }
            if worldHistory.count == historySize {
                world = averaged(worldHistory)
                norm = averaged(normHistory)
            }
        }

        // Make the limbs rigid. Vision's per frame depth wanders, which stretches
        // and shrinks the bones and is the main reason the figure looks rubbery.
        world = enforceBoneLengths(world)

        // The two wrists are left as measured. Grip fusion, which used to
        // collapse them into one point here, has been removed project-wide,
        // so the Vision skeleton shows two separate wrists like MediaPipe now
        // does. Anything that needs a single grip averages the two slots
        // where it needs one.

        // A crude estimated foot, so the ankle heel toe triangle draws at all.
        // Vision has no foot joints. Flagged low visibility and kept flat and
        // short, so it reads as a foot rather than spiking into the ground.
        estimateFeet(world: &world, norm: &norm)

        // Keep the ankles from snapping below the learned floor.
        clampToFloor(world: &world)

        return PersonDetection(norm: norm, world: world, conf: person.conf)
    }

    private func applyFilter(_ filter: OneEuroVectorFilter, to set: LandmarkSet, timestamp: Double, hasZ: Bool) -> LandmarkSet {
        // Flatten to channels, filter, rebuild. Z only where the space has depth.
        let stride = hasZ ? 3 : 2
        var flat: [Double] = []
        flat.reserveCapacity(set.count * stride)
        for l in set {
            flat.append(l.x)
            flat.append(l.y)
            if hasZ { flat.append(l.z ?? 0) }
        }
        let smoothed = filter.filter(flat, timestamp: timestamp)
        var out = set
        for i in 0..<set.count {
            let base = i * stride
            out[i] = Landmark(
                x: smoothed[base],
                y: smoothed[base + 1],
                z: hasZ ? smoothed[base + 2] : set[i].z,
                visibility: set[i].visibility,
                score: set[i].score
            )
        }
        return out
    }

    /*
      Estimate a foot for each ankle so the triangle draws.

      This is a stopgap for Vision, which has no heel or foot index. The foot is
      built flat: a small drop below the ankle and a short horizontal reach, heel
      toward the body and toe away from it, rather than extended down the shin
      which would spike into the ground. It is flagged at low visibility and is
      never fed to a measurement. The real feet arrive with MediaPipe in v2.
    */
    private func estimateFeet(world: inout LandmarkSet, norm: inout LandmarkSet) {
        guard world.count > Landmarks.RIGHT_FOOT_INDEX, norm.count > Landmarks.RIGHT_FOOT_INDEX else { return }
        let hipMidX = (world[Landmarks.LEFT_HIP].x + world[Landmarks.RIGHT_HIP].x) / 2
        let hipMidXNorm = (norm[Landmarks.LEFT_HIP].x + norm[Landmarks.RIGHT_HIP].x) / 2

        func build(ankle: Int, heel: Int, toe: Int) {
            let aW = world[ankle]
            // Outward is away from the body centre. Toe reaches outward, heel a
            // little inward, both dropped slightly below the ankle.
            let outW: Double = aW.x >= hipMidX ? 1 : -1
            world[heel] = Landmark(x: aW.x - outW * 0.03, y: aW.y - 0.03, z: aW.z, visibility: 0.5)
            world[toe] = Landmark(x: aW.x + outW * 0.10, y: aW.y - 0.03, z: aW.z, visibility: 0.5)

            let aN = norm[ankle]
            let outN: Double = aN.x >= hipMidXNorm ? 1 : -1
            // Image Y grows downward, so below the ankle is a larger Y.
            norm[heel] = Landmark(x: aN.x - outN * 0.015, y: aN.y + 0.012, z: nil, visibility: 0.5)
            norm[toe] = Landmark(x: aN.x + outN * 0.045, y: aN.y + 0.012, z: nil, visibility: 0.5)
        }

        build(ankle: Landmarks.LEFT_ANKLE, heel: Landmarks.LEFT_HEEL, toe: Landmarks.LEFT_FOOT_INDEX)
        build(ankle: Landmarks.RIGHT_ANKLE, heel: Landmarks.RIGHT_HEEL, toe: Landmarks.RIGHT_FOOT_INDEX)
    }

    /*
      Stop the ankles snapping into the ground.

      The floor is the lowest the ankles sat across the first few steady frames.
      Later frames may not drop more than a small margin below it. This catches
      the trail leg snap Vision shows without pinning the feet, so a real heel
      lift, which moves an ankle up and away from the floor, is left alone.
    */
    private func clampToFloor(world: inout LandmarkSet) {
        guard world.count > Landmarks.RIGHT_ANKLE else { return }
        let ankleMinY = min(world[Landmarks.LEFT_ANKLE].y, world[Landmarks.RIGHT_ANKLE].y)

        if floorWorldY == nil {
            floorSamples.append(ankleMinY)
            if floorSamples.count >= 5 {
                floorWorldY = floorSamples.min()
            }
            return
        }
        guard let floor = floorWorldY else { return }
        let limit = floor - 0.05  // world Y is up, so the floor is a lower bound
        for a in [Landmarks.LEFT_ANKLE, Landmarks.RIGHT_ANKLE] {
            if world[a].y < limit {
                world[a] = Landmark(x: world[a].x, y: limit, z: world[a].z, visibility: world[a].visibility, score: world[a].score)
            }
        }
    }

    /*
      Bone length consistency, applied hierarchically from the pelvis.

      Learns a reference length per bone from the median of the first few frames,
      then for each bone moves the child joint along the current bone direction so
      the length matches the reference. Working parent to child means a corrected
      parent carries its children with it, so the whole limb stays attached rather
      than each joint being fixed in isolation.

      World only. The 2D norm overlay is already stable, and rescaling it would
      fight the image it is drawn over.
    */
    private func enforceBoneLengths(_ input: LandmarkSet) -> LandmarkSet {
        guard input.count >= 33 else { return input }
        var world = input

        // Learn the reference lengths once there are a few clean frames.
        if referenceBoneLengths.isEmpty {
            boneLengthSamples.append(Self.boneLengths(of: world))
            if boneLengthSamples.count >= 5 {
                referenceBoneLengths = Self.medianBoneLengths(boneLengthSamples)
            } else {
                return world  // not enough yet, leave this frame as is
            }
        }

        let mid: (Int, Int) -> Vec3 = { a, b in
            Geometry.v.mid(world[a].vec, world[b].vec)
        }
        // A synthetic pelvis root, the hip midpoint, as the fixed origin.
        let root = mid(Landmarks.LEFT_HIP, Landmarks.RIGHT_HIP)

        for bone in Self.bones {
            guard let target = referenceBoneLengths[bone.id] else { continue }
            let parentPos = bone.parent < 0
                ? root
                : Vec3(x: world[bone.parent].x, y: world[bone.parent].y, z: world[bone.parent].z)
            let childPos = Vec3(x: world[bone.child].x, y: world[bone.child].y, z: world[bone.child].z)

            let dx = childPos.x - parentPos.x
            let dy = childPos.y - parentPos.y
            let dz = (childPos.z ?? 0) - (parentPos.z ?? 0)
            let len = (dx * dx + dy * dy + dz * dz).squareRoot()
            guard len > 1e-6 else { continue }

            let scale = target / len
            world[bone.child] = Landmark(
                x: parentPos.x + dx * scale,
                y: parentPos.y + dy * scale,
                z: (parentPos.z ?? 0) + dz * scale,
                visibility: world[bone.child].visibility
            )
        }
        return world
    }

    // Parent to child bones, ordered so a parent is corrected before its child.
    // A parent of minus one hangs off the synthetic pelvis root.
    private struct BoneLink {
        let id: String
        let parent: Int
        let child: Int
    }
    private static let bones: [BoneLink] = [
        BoneLink(id: "spine", parent: -1, child: Landmarks.LEFT_SHOULDER),
        BoneLink(id: "clav", parent: Landmarks.LEFT_SHOULDER, child: Landmarks.RIGHT_SHOULDER),
        BoneLink(id: "lUpperArm", parent: Landmarks.LEFT_SHOULDER, child: Landmarks.LEFT_ELBOW),
        BoneLink(id: "lForearm", parent: Landmarks.LEFT_ELBOW, child: Landmarks.LEFT_WRIST),
        BoneLink(id: "rUpperArm", parent: Landmarks.RIGHT_SHOULDER, child: Landmarks.RIGHT_ELBOW),
        BoneLink(id: "rForearm", parent: Landmarks.RIGHT_ELBOW, child: Landmarks.RIGHT_WRIST),
        BoneLink(id: "pelvis", parent: -1, child: Landmarks.LEFT_HIP),
        BoneLink(id: "pelvisR", parent: Landmarks.LEFT_HIP, child: Landmarks.RIGHT_HIP),
        BoneLink(id: "lThigh", parent: Landmarks.LEFT_HIP, child: Landmarks.LEFT_KNEE),
        BoneLink(id: "lShin", parent: Landmarks.LEFT_KNEE, child: Landmarks.LEFT_ANKLE),
        BoneLink(id: "rThigh", parent: Landmarks.RIGHT_HIP, child: Landmarks.RIGHT_KNEE),
        BoneLink(id: "rShin", parent: Landmarks.RIGHT_KNEE, child: Landmarks.RIGHT_ANKLE),
    ]

    private static func boneLengths(of world: LandmarkSet) -> [String: Double] {
        let root = Geometry.v.mid(world[Landmarks.LEFT_HIP].vec, world[Landmarks.RIGHT_HIP].vec)
        var out: [String: Double] = [:]
        for bone in bones {
            let p = bone.parent < 0 ? root : world[bone.parent].vec
            let c = world[bone.child].vec
            out[bone.id] = Geometry.v.dist(p, c)
        }
        return out
    }

    private static func medianBoneLengths(_ samples: [[String: Double]]) -> [String: Double] {
        var out: [String: Double] = [:]
        for bone in bones {
            let vals = samples.compactMap { $0[bone.id] }.sorted()
            guard !vals.isEmpty else { continue }
            out[bone.id] = vals[vals.count / 2]
        }
        return out
    }

    private func averaged(_ history: [LandmarkSet]) -> LandmarkSet {
        guard let first = history.first else { return [] }
        let n = first.count
        let count = Double(history.count)
        var out = first
        for i in 0..<n {
            var sx = 0.0, sy = 0.0, sz = 0.0
            var anyZ = false
            for set in history where i < set.count {
                sx += set[i].x
                sy += set[i].y
                if let z = set[i].z {
                    sz += z
                    anyZ = true
                }
            }
            out[i] = Landmark(
                x: sx / count,
                y: sy / count,
                z: anyZ ? sz / count : nil,
                visibility: first[i].visibility
            )
        }
        return out
    }

    /*
      The same detection, from a CGImage rather than a sample buffer.

      This is the entry point the upload pipeline uses. AVAssetImageGenerator
      hands back CGImages when the video is stepped to fixed timestamps, so the
      only difference from the live path is which VNImageRequestHandler
      initialiser is used. Everything downstream, the joint map, the world and
      normalised sets, the confidence, is shared through detect(with:) so the two
      paths cannot drift.

      Static and nonisolated on purpose: extracting a whole clip runs off the
      main actor, frame by frame, and this touches no instance state.
    */
    public static func detect(cgImage: CGImage) throws -> [PersonDetection] {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        return try detect(with: handler)
    }

    private static func detect(with handler: VNImageRequestHandler) throws -> [PersonDetection] {
        let request = VNDetectHumanBodyPose3DRequest()
        try handler.perform([request])

        /* An empty array is a normal outcome, not a failure. Nobody was in shot. */
        guard let observation = request.results?.first else { return [] }

        let confidence = Double(observation.confidence)
        var world = emptySet()
        var norm = emptySet()
        var mapped = 0

        for (jointName, slot) in jointMap {
            guard let recognised = try? observation.recognizedPoint(jointName) else { continue }

            /* position is a 4x4 transform relative to the skeleton root at the
               hip centre, in metres. The translation column is the point. That
               matches what the engine calls world space closely enough that no
               conversion is needed beyond reading the column. */
            let translation = recognised.position.columns.3
            guard translation.x.isFinite, translation.y.isFinite, translation.z.isFinite else { continue }

            world[slot] = Landmark(
                x: Double(translation.x),
                y: Double(translation.y),
                z: Double(translation.z),
                /* Left nil on purpose. Vision has no per joint confidence, and
                   the frame's confidence is carried on the frame. */
                visibility: nil
            )
            mapped += 1

            if let projected = imagePoint(observation, jointName) {
                norm[slot] = Landmark(
                    x: projected.x,
                    y: projected.y,
                    z: nil,
                    visibility: nil
                )
            }
        }

        if mapped == 0 { return [] }

        return [PersonDetection(norm: norm, world: world, conf: confidence)]
    }

    /*
      The 2D image position of a joint, in normalised coordinates with the origin
      at the top left and y increasing downward, which is MediaPipe's convention
      and what the overlay and the subject fill check both assume. Vision uses a
      bottom left origin, so y is flipped.

      This is the piece that switches the subject fill gate back on. While the
      normalised set was empty, Validity could not measure how much of the frame
      the golfer filled, which is the check that catches footage of a screen.

      COMPILER NOTE. pointInImage is documented as taking a joint name, but at
      least one code sample passes the recognised point instead. If this line
      does not compile, fetch the point first and pass that:

          let p = try observation.recognizedPoint(jointName)
          let vn = try observation.pointInImage(p)

      Both spellings return a VNPoint, so nothing below changes either way.
    */
    private static func imagePoint(_ observation: VNHumanBodyPose3DObservation, _ jointName: VNHumanBodyPose3DObservation.JointName) -> (x: Double, y: Double)? {
        guard let vnPoint = try? observation.pointInImage(jointName) else { return nil }
        let x = Double(vnPoint.x)
        let y = Double(vnPoint.y)
        guard x.isFinite, y.isFinite else { return nil }
        return (x: x, y: 1 - y)
    }

    public func close() {
        closed = true
        prevWorld = nil
        prevNorm = nil
        worldHistory.removeAll()
        normHistory.removeAll()
        referenceBoneLengths.removeAll()
        boneLengthSamples.removeAll()
        worldFilter.reset()
        normFilter.reset()
        floorWorldY = nil
        floorSamples.removeAll()
    }
}
