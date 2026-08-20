import Foundation

/*
  MediaPipe Pose landmark map.

  MediaPipe returns 33 landmarks in two coordinate systems:
    landmarks       normalised image space, 0 to 1, good for drawing overlays
    worldLandmarks  metric space in metres, origin at the hip centre, good for
                    every angle and speed calculation in this engine

  All biomechanics in Swingline runs on worldLandmarks. All drawing runs on
  the normalised set. Mixing the two is the easiest way to produce a confident
  wrong number, so the two are never passed into the same function.

  A note for the iOS port, carried over from the TypeScript version: this
  exact 33 point index map is a MediaPipe BlazePose detail, not a law of
  nature. Apple's Vision framework exposes a different, smaller joint set
  with no numeric indices and no thumb, index or pinky points at all. See
  VisionPoseProvider.swift for where that boundary actually sits. This file
  is the landmark map for data that already arrived in MediaPipe's shape,
  whichever platform produced it.

  Translated from packages/core/src/landmarks.ts.
*/

public enum Landmarks {

    public static let NOSE = 0
    public static let LEFT_EYE_INNER = 1
    public static let LEFT_EYE = 2
    public static let LEFT_EYE_OUTER = 3
    public static let RIGHT_EYE_INNER = 4
    public static let RIGHT_EYE = 5
    public static let RIGHT_EYE_OUTER = 6
    public static let LEFT_EAR = 7
    public static let RIGHT_EAR = 8
    public static let MOUTH_LEFT = 9
    public static let MOUTH_RIGHT = 10
    public static let LEFT_SHOULDER = 11
    public static let RIGHT_SHOULDER = 12
    public static let LEFT_ELBOW = 13
    public static let RIGHT_ELBOW = 14
    public static let LEFT_WRIST = 15
    public static let RIGHT_WRIST = 16
    public static let LEFT_PINKY = 17
    public static let RIGHT_PINKY = 18
    public static let LEFT_INDEX = 19
    public static let RIGHT_INDEX = 20
    public static let LEFT_THUMB = 21
    public static let RIGHT_THUMB = 22
    public static let LEFT_HIP = 23
    public static let RIGHT_HIP = 24
    public static let LEFT_KNEE = 25
    public static let RIGHT_KNEE = 26
    public static let LEFT_ANKLE = 27
    public static let RIGHT_ANKLE = 28
    public static let LEFT_HEEL = 29
    public static let RIGHT_HEEL = 30
    public static let LEFT_FOOT_INDEX = 31
    public static let RIGHT_FOOT_INDEX = 32

    /* Bone pairs for the skeleton overlay, ordered head down so the joint by
       joint morph reads as a body settling rather than as random noise. */
    public static let BONES: [(Int, Int)] = [
        (LEFT_SHOULDER, RIGHT_SHOULDER),
        (LEFT_SHOULDER, LEFT_ELBOW),
        (LEFT_ELBOW, LEFT_WRIST),
        (RIGHT_SHOULDER, RIGHT_ELBOW),
        (RIGHT_ELBOW, RIGHT_WRIST),
        (LEFT_SHOULDER, LEFT_HIP),
        (RIGHT_SHOULDER, RIGHT_HIP),
        (LEFT_HIP, RIGHT_HIP),
        (LEFT_HIP, LEFT_KNEE),
        (LEFT_KNEE, LEFT_ANKLE),
        (LEFT_ANKLE, LEFT_HEEL),
        (LEFT_HEEL, LEFT_FOOT_INDEX),
        (LEFT_ANKLE, LEFT_FOOT_INDEX),
        (LEFT_WRIST, LEFT_INDEX),
        (RIGHT_HIP, RIGHT_KNEE),
        (RIGHT_KNEE, RIGHT_ANKLE),
        (RIGHT_ANKLE, RIGHT_HEEL),
        (RIGHT_HEEL, RIGHT_FOOT_INDEX),
        (RIGHT_ANKLE, RIGHT_FOOT_INDEX),
        (RIGHT_WRIST, RIGHT_INDEX),
    ]

    /*
      The joints the overlay draws.

      Face mesh points are still dropped, they add visual noise and contribute
      nothing to a swing diagnosis. The hands and heels are now included, because
      the grip and where the heel sits are both things a coach reads directly off a
      swing, and leaving them out made the figure stop at the wrist and the ankle.
    */
    // The ankle, heel and foot index of both feet. They track less confidently
    // than the torso, so the overlay draws them with a lower visibility floor.
    public static let footJoints: Set<Int> = [
        LEFT_ANKLE, RIGHT_ANKLE, LEFT_HEEL, RIGHT_HEEL, LEFT_FOOT_INDEX, RIGHT_FOOT_INDEX,
    ]

    public static let DRAWN_JOINTS: [Int] = [
        NOSE,
        LEFT_SHOULDER, RIGHT_SHOULDER,
        LEFT_ELBOW, RIGHT_ELBOW,
        LEFT_WRIST, RIGHT_WRIST,
        LEFT_INDEX, RIGHT_INDEX,
        LEFT_HIP, RIGHT_HIP,
        LEFT_KNEE, RIGHT_KNEE,
        LEFT_ANKLE, RIGHT_ANKLE,
        LEFT_HEEL, RIGHT_HEEL,
        LEFT_FOOT_INDEX, RIGHT_FOOT_INDEX,
    ]

    /* Handedness resolution. Everything downstream asks for lead and trail
       rather than left and right, so a left handed golfer is a settings change
       and not a second code path. */
    public static func sides(_ dominantHand: DominantHand = .right) -> Sides {
        let right = dominantHand != .left
        return Sides(
            leadShoulder: right ? LEFT_SHOULDER : RIGHT_SHOULDER,
            trailShoulder: right ? RIGHT_SHOULDER : LEFT_SHOULDER,
            leadElbow: right ? LEFT_ELBOW : RIGHT_ELBOW,
            trailElbow: right ? RIGHT_ELBOW : LEFT_ELBOW,
            leadWrist: right ? LEFT_WRIST : RIGHT_WRIST,
            trailWrist: right ? RIGHT_WRIST : LEFT_WRIST,
            leadHip: right ? LEFT_HIP : RIGHT_HIP,
            trailHip: right ? RIGHT_HIP : LEFT_HIP,
            leadKnee: right ? LEFT_KNEE : RIGHT_KNEE,
            trailKnee: right ? RIGHT_KNEE : LEFT_KNEE,
            leadAnkle: right ? LEFT_ANKLE : RIGHT_ANKLE,
            trailAnkle: right ? RIGHT_ANKLE : LEFT_ANKLE,
            /* Sign of the target direction along the world x axis. For a right
               handed golfer filmed face on, the target sits to the golfer's left. */
            targetSign: right ? 1 : -1
        )
    }

    /* Mean visibility across the joints that matter, used to decide whether a
       frame is trustworthy enough to score. */
    public static func frameConfidence(_ landmarks: LandmarkSet?) -> Double {
        guard let landmarks = landmarks, !landmarks.isEmpty else { return 0 }
        var sum = 0.0
        var n = 0
        for i in DRAWN_JOINTS {
            guard i < landmarks.count else { continue }
            let p = landmarks[i]
            sum += p.visibility ?? p.score ?? 1
            n += 1
        }
        return n > 0 ? sum / Double(n) : 0
    }
}

