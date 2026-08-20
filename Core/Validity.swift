import Foundation

/*
  Validity, iOS build.

  This file exists because the app scored a video of somebody's hand and printed
  a confident diagnosis underneath it. That is the worst thing a coaching tool
  can do. A golfer who catches the app inventing one analysis has no way to know
  which of the other forty were real, and the honest answer is that they cannot
  tell, so they should not trust any of them.

  So before a swing is scored at all, it has to pass a set of checks about
  whether the footage plausibly contains a whole human being swinging a club.
  Anything that fails is still recorded and still kept, it simply does not get a
  score, and the reason is stated plainly.

  WHAT CHANGED FOR iOS, and why.

  The crash was an out of bounds read: the provider was handing over a short
  array and this file indexed slot 23 for the hip. Every joint lookup below now
  goes through point(), which returns nil rather than trapping, so no landmark
  array of any length can crash this file again.

  That fixes the crash. It does not on its own make the numbers right, and the
  difference matters. Bounds safety stops a trap. It cannot tell whether slot 11
  actually holds a left shoulder. Every consumer of this data, Biomechanics,
  Phases and Sequencing included, reads the MediaPipe thirty three slot map
  documented in Landmarks.swift, so the provider still has to hand over that
  layout for any of it to mean anything. See the note at the bottom of this file.

  CORE_JOINTS below is the thirteen joints Apple Vision and MediaPipe both
  report reliably. Nothing in this file reads anything outside that set, so it
  works on either backend without a second code path.

  House rule: no em dashes anywhere.
*/

public enum Validity {

    // MARK: - Tunables

    /*
      How many of the thirteen core joints have to be tracked before a frame
      counts as containing a body at all.

      Six is deliberately low. It is a presence check, not a quality check: it
      answers "is something shaped like a person in this frame", and the checks
      that follow answer whether that something is a whole golfer at a size worth
      measuring. Raising this number does not make the app safer, it mostly makes
      it reject people standing slightly out of frame.
    */
    public static let MIN_TRACKED_JOINTS = 6
    public static let JOINT_CONFIDENCE_FLOOR = 0.5

    /* Below this many frames with a body in them there is no swing to read. */
    public static let MIN_FRAMES = 14

    /*
      How much of the frame height the golfer has to fill.

      Two thresholds rather than one. Below BLOCK there are not enough pixels on
      the body for any measurement to mean anything, so nothing is scored.
      Between BLOCK and WARN the swing is scored but the clip is marked degraded,
      because the error on every joint is a fixed number of pixels and a smaller
      subject turns that into a larger fraction of the body.
    */
    public static let SUBJECT_FILL_BLOCK = 0.25
    public static let SUBJECT_FILL_WARN = 0.45

    /*
      What to do when subject fill cannot be measured at all.

      Fill is measured from the normalised image landmarks. VisionPoseProvider
      currently returns an empty normalised set, so on this build fill is
      unknown, the size gate is switched off, and the exact hole the laptop
      screen footage went through is open again.

      Marking those clips degraded is the honest reading: the app could not check
      the one thing that catches that case, so it should not present the numbers
      with full confidence. Set this to false once the provider fills the
      normalised set in and the gate is doing its job properly.
    */
    public static let TREAT_UNKNOWN_FILL_AS_DEGRADED = true

    /* Anthropometric ranges, generous at both ends so that tall, short, adult and
       junior golfers all pass, while a hand at arm's length does not. Metres. */
    private static let SHOULDER_WIDTH_RANGE: ClosedRange<Double> = 0.22...0.60
    private static let HIP_WIDTH_RANGE: ClosedRange<Double> = 0.14...0.48
    private static let TORSO_LENGTH_RANGE: ClosedRange<Double> = 0.30...0.75
    private static let LEG_LENGTH_RANGE: ClosedRange<Double> = 0.45...1.25
    /* Torso to leg ratio. Human bodies cluster tightly here regardless of
       height, which makes it a good check that survives distance from camera. */
    private static let TORSO_TO_LEG_RANGE: ClosedRange<Double> = 0.35...1.15

    /*
      Hand travel needed before the clip counts as containing a swing, measured
      in the golfer's own body heights.

      This used to be measured in shoulder widths, which was wrong for a reason
      that only shows up on down the line footage: filmed from behind, the two
      shoulders sit almost on top of each other along the camera's x axis, the
      width collapses toward zero, and dividing by it rejected legitimate
      golfers. Body height does not collapse from any angle.

      Three shoulder widths at a typical 0.4m shoulder is about 1.2m of hand
      travel. Against a 1.7m golfer that is roughly 0.7 body heights, which is
      where this number comes from.
    */
    private static let MIN_TRAVEL_IN_BODY_HEIGHTS = 0.7

    // MARK: - Joints

    /*
      The thirteen joints both backends report.

      Apple's 3D body pose request returns seventeen joints and MediaPipe returns
      thirty three. This is the intersection, and it is everything the checks
      below need. Nothing here reads a heel, a foot index, a thumb or any face
      point, because Vision does not have them.
    */
    public static let CORE_JOINTS: [Int] = [
        Landmarks.NOSE,
        Landmarks.LEFT_SHOULDER, Landmarks.RIGHT_SHOULDER,
        Landmarks.LEFT_ELBOW, Landmarks.RIGHT_ELBOW,
        Landmarks.LEFT_WRIST, Landmarks.RIGHT_WRIST,
        Landmarks.LEFT_HIP, Landmarks.RIGHT_HIP,
        Landmarks.LEFT_KNEE, Landmarks.RIGHT_KNEE,
        Landmarks.LEFT_ANKLE, Landmarks.RIGHT_ANKLE,
    ]

    /* Split deliberately. Whether a torso is present and whether the legs are in
       shot are different questions with different fixes, and collapsing them into
       one visibility count reports "no golfer found" at somebody who is standing
       right there with their feet just out of frame. */
    private static let TORSO_JOINTS = [
        Landmarks.LEFT_SHOULDER, Landmarks.RIGHT_SHOULDER,
        Landmarks.LEFT_HIP, Landmarks.RIGHT_HIP,
    ]

    private static let LEG_JOINTS = [
        Landmarks.LEFT_KNEE, Landmarks.RIGHT_KNEE,
        Landmarks.LEFT_ANKLE, Landmarks.RIGHT_ANKLE,
    ]

    // MARK: - Reasons

    public static let REASON_TOO_SHORT = ValidityReason.tooShort
    public static let REASON_NO_BODY = ValidityReason.noBody
    public static let REASON_PARTIAL_BODY = ValidityReason.partialBody
    public static let REASON_NOT_HUMAN_SCALE = ValidityReason.notHumanScale
    public static let REASON_NO_MOTION = ValidityReason.noMotion
    public static let REASON_LOW_CONFIDENCE = ValidityReason.lowConfidence
    public static let REASON_TOO_SMALL = ValidityReason.tooSmall

    public static let REASON_COPY: [ValidityReason: (title: String, body: String)] = [
        REASON_TOO_SHORT: (
            title: "Too few tracked frames",
            body: "There were not enough frames with a body in them to read a swing. On a phone this usually means tracking was running slowly, or the golfer was only in shot for part of the clip."
        ),
        REASON_NO_BODY: (
            title: "No golfer found",
            body: "Nothing in this clip looks like a person swinging. The recording is saved, but there is nothing here to score."
        ),
        REASON_PARTIAL_BODY: (
            title: "Only part of the body was visible",
            body: "Feet, hips and shoulders all need to be in frame. Balance and weight transfer are measured from where the feet actually are, so a clip that cuts them off cannot be scored honestly."
        ),
        REASON_NOT_HUMAN_SCALE: (
            title: "That does not look like a full golfer",
            body: "The shape being tracked is not the proportions of a whole body, so any score would be invented. This happens with close ups, footage of a screen, or when something else in frame is being mistaken for a person."
        ),
        REASON_NO_MOTION: (
            title: "No swing in this clip",
            body: "The body barely moved, so there is no swing to analyse. The recording is saved."
        ),
        REASON_LOW_CONFIDENCE: (
            title: "Tracking was too unreliable",
            body: "The body was found but not held confidently enough to trust the numbers. More light, a plainer background, or standing a little closer usually fixes it."
        ),
        REASON_TOO_SMALL: (
            title: "The golfer is too small in frame",
            body: "Every joint is found to within a few pixels, so the smaller the body is on screen, the larger that error becomes as a share of the swing. At this size the numbers would look precise and mean nothing. Fill more of the frame, or move the camera closer, and this clip becomes readable. Filming a screen usually lands here too."
        ),
    ]

    // MARK: - Safe access

    /*
      Every landmark read in this file goes through here.

      Returns nil for a slot past the end of the array, which is what was
      crashing, and also for a slot holding a non finite coordinate, which is
      what a failed projection looks like.
    */
    private static func point(_ set: LandmarkSet, _ index: Int) -> Landmark? {
        guard index >= 0, index < set.count else { return nil }
        let p = set[index]
        guard p.x.isFinite, p.y.isFinite else { return nil }
        return p
    }

    /*
      How much a single joint should be trusted.

      MediaPipe fills in visibility. Apple's 3D body pose request does not report
      anything per joint at all, only a confidence for the observation as a
      whole, so a joint Vision returned carries the frame's confidence rather
      than a per joint number nobody measured. A joint the provider could not map
      is written in with visibility zero and scores zero here, which is how a
      missing joint stays distinguishable from an uncertain one.
    */
    private static func trust(_ p: Landmark?, frameConfidence: Double) -> Double {
        guard let p = p else { return 0 }
        if let visibility = p.visibility { return visibility }
        if let score = p.score { return score }
        return frameConfidence
    }

    private static func tracked(_ set: LandmarkSet, _ joints: [Int], frameConfidence: Double, floor: Double) -> Int {
        joints.reduce(0) { count, index in
            trust(point(set, index), frameConfidence: frameConfidence) > floor ? count + 1 : count
        }
    }

    private static func midpoint(_ set: LandmarkSet, _ a: Int, _ b: Int) -> Vec3? {
        guard let pa = point(set, a), let pb = point(set, b) else { return nil }
        return Geometry.v.mid(pa.vec, pb.vec)
    }

    private static func distance(_ set: LandmarkSet, _ a: Int, _ b: Int) -> Double? {
        guard let pa = point(set, a), let pb = point(set, b) else { return nil }
        let d = Geometry.v.dist(pa.vec, pb.vec)
        return d.isFinite ? d : nil
    }

    // MARK: - Per frame measurements

    private struct FrameRead {
        var torsoSeen = false
        var legsSeen = false
        var coreCount = 0
        var shoulderWidth: Double?
        var hipWidth: Double?
        var torsoLength: Double?
        var legLength: Double?
        var bodyHeight: Double?
        var fill: Double?
        /* nil means the proportion test could not be run on this frame, which is
           a different answer from "this is not a person" and is counted
           separately below. */
        var human: Bool?
    }

    private static func read(_ frame: Frame) -> FrameRead {
        var out = FrameRead()
        let world = frame.world
        let norm = frame.norm
        if world.isEmpty { return out }

        out.coreCount = tracked(world, CORE_JOINTS, frameConfidence: frame.conf, floor: JOINT_CONFIDENCE_FLOOR)
        out.torsoSeen = tracked(world, TORSO_JOINTS, frameConfidence: frame.conf, floor: 0.5) >= 3
        out.legsSeen = tracked(world, LEG_JOINTS, frameConfidence: frame.conf, floor: 0.45) >= 3

        /*
          How tall the golfer is on screen, as a fraction of frame height.

          Deliberately measured from the normalised landmarks and not from the
          world ones. World coordinates are metric and roughly scale invariant,
          which is exactly why the proportion tests passed on a recording of a
          laptop screen: the shape was a perfectly plausible human, just a tiny
          one. Pixels are what the measurement error is denominated in, so pixels
          are what has to be checked.
        */
        if !norm.isEmpty {
            let ys = CORE_JOINTS.compactMap { index -> Double? in
                guard let p = point(norm, index) else { return nil }
                return trust(p, frameConfidence: frame.conf) > JOINT_CONFIDENCE_FLOOR ? p.y : nil
            }
            if ys.count >= 4, let lo = ys.min(), let hi = ys.max() {
                out.fill = hi - lo
            }
        }

        out.shoulderWidth = distance(world, Landmarks.LEFT_SHOULDER, Landmarks.RIGHT_SHOULDER)
        out.hipWidth = distance(world, Landmarks.LEFT_HIP, Landmarks.RIGHT_HIP)

        if let midShoulder = midpoint(world, Landmarks.LEFT_SHOULDER, Landmarks.RIGHT_SHOULDER),
           let midHip = midpoint(world, Landmarks.LEFT_HIP, Landmarks.RIGHT_HIP) {
            let torso = Geometry.v.dist(midShoulder, midHip)
            if torso.isFinite { out.torsoLength = torso }
        }

        let legs = [
            distance(world, Landmarks.LEFT_HIP, Landmarks.LEFT_ANKLE),
            distance(world, Landmarks.RIGHT_HIP, Landmarks.RIGHT_ANKLE),
        ].compactMap { $0 }
        if !legs.isEmpty { out.legLength = legs.reduce(0, +) / Double(legs.count) }

        /* Height proxy, used to normalise hand travel. Falls back to a multiple
           of torso length when the legs are out of shot, because a golfer framed
           from the waist up is still a golfer. */
        if let torso = out.torsoLength {
            out.bodyHeight = out.legLength.map { torso + $0 } ?? torso * 2.6
        }

        /*
          Proportions.

          Runs only on the measurements actually present. A check that could not
          be run reports nil rather than false, because failing a golfer for a
          measurement the camera never took is the same lie as passing footage of
          a hand, pointed the other way.
        */
        guard let shoulderWidth = out.shoulderWidth,
              let hipWidth = out.hipWidth,
              let torsoLength = out.torsoLength
        else { return out }

        var human =
            within(shoulderWidth, SHOULDER_WIDTH_RANGE) &&
            within(hipWidth, HIP_WIDTH_RANGE) &&
            within(torsoLength, TORSO_LENGTH_RANGE)

        /* Legs only count toward the proportion test when they are actually
           visible, otherwise a correctly framed torso with the feet cut off fails
           the human scale test and gets told it is not a person. */
        if human, out.legsSeen, let legLength = out.legLength, legLength > 0.01 {
            let ratio = torsoLength / legLength
            human = within(legLength, LEG_LENGTH_RANGE) && within(ratio, TORSO_TO_LEG_RANGE)
        }

        out.human = human
        return out
    }

    // MARK: - Clip assessment

    /*
      Assess whether a set of frames can honestly be scored.

      Returns the reasons it cannot rather than a single pass or fail, because
      "your feet were out of frame" is actionable and "analysis failed" is not.
    */
    public static func assessClip(_ frames: [Frame], _ S: Sides) -> ValidityResult {
        if frames.count < MIN_FRAMES {
            return ValidityResult(
                ok: false,
                reasons: [REASON_TOO_SHORT],
                confidence: 0,
                degraded: false,
                fill: nil,
                detail: nil
            )
        }

        var reads: [FrameRead] = []
        reads.reserveCapacity(frames.count)
        var confidenceSum = 0.0
        for frame in frames {
            confidenceSum += frame.conf
            reads.append(read(frame))
        }

        let total = Double(frames.count)
        let meanConfidence = confidenceSum / total

        /* The presence gate, on the thirteen joints both backends report. A
           frame with fewer than this many tracked joints is not a frame with a
           person in it. */
        let bodyFrames = reads.filter { $0.coreCount >= MIN_TRACKED_JOINTS }.count
        let visibleFrames = reads.filter { $0.torsoSeen }.count
        let feetFrames = reads.filter { $0.legsSeen }.count

        let bodyFraction = Double(bodyFrames) / total
        let visibleFraction = Double(visibleFrames) / total
        let feetFraction = Double(feetFrames) / total

        /* Frames where the proportion test could run at all, and of those, how
           many looked like a whole person. Scoring the second against the first
           rather than against every frame stops a clip being called "not human"
           when the truth is that the check never ran. */
        let testable = reads.compactMap { $0.human }
        let humanFraction = testable.isEmpty ? 1.0 : Double(testable.filter { $0 }.count) / Double(testable.count)

        let fill = median(reads.compactMap { $0.fill })
        let shoulderWidths = reads.compactMap { $0.shoulderWidth }
        let scale = median(reads.compactMap { $0.bodyHeight }) ?? 1.7

        /* Did anything actually swing. Hand travel across the clip, relative to
           the golfer's own height so it holds at any distance from the camera
           and from any angle. */
        var travel = 0.0
        if frames.count > 1 {
            for i in 1..<frames.count {
                guard let a = point(frames[i].world, S.leadWrist),
                      let b = point(frames[i - 1].world, S.leadWrist)
                else { continue }
                let step = Geometry.v.dist(a.vec, b.vec)
                if step.isFinite { travel += step }
            }
        }
        let travelInHeights = scale > 0.01 ? travel / scale : 0

        /*
          Ordered so the reported reason is the most actionable one available. No
          body at all means there is no golfer. A body at the wrong scale means it
          is not a whole person. Size is checked before framing, because a golfer
          who is far too small to measure and whose feet are also out of frame
          should be told about the size: moving the camera closer is the thing
          that fixes it and recomposing alone would not.
        */
        var reasons: [ValidityReason] = []

        if bodyFraction < 0.4 || visibleFraction < 0.4 {
            reasons.append(REASON_NO_BODY)
        } else if humanFraction < 0.45 {
            reasons.append(REASON_NOT_HUMAN_SCALE)
        } else if let fill = fill, fill > 0, fill < SUBJECT_FILL_BLOCK {
            reasons.append(REASON_TOO_SMALL)
        } else if feetFraction < 0.35 {
            reasons.append(REASON_PARTIAL_BODY)
        }

        if reasons.isEmpty && travelInHeights < MIN_TRAVEL_IN_BODY_HEIGHTS {
            reasons.append(REASON_NO_MOTION)
        }
        if reasons.isEmpty && meanConfidence < 0.45 {
            reasons.append(REASON_LOW_CONFIDENCE)
        }

        /*
          Passed the gate, but with a caveat worth carrying to the screen.

          Either the golfer is small enough that precision is meaningfully worse,
          or subject fill could not be measured at all, which means the size gate
          never ran. Both are reasons to present the numbers with less certainty
          than a well framed clip gets.
        */
        var degraded = false
        if reasons.isEmpty {
            if let fill = fill, fill > 0 {
                degraded = fill < SUBJECT_FILL_WARN
            } else {
                degraded = TREAT_UNKNOWN_FILL_AS_DEGRADED
            }
        }

        return ValidityResult(
            ok: reasons.isEmpty,
            reasons: reasons,
            confidence: round(meanConfidence),
            degraded: degraded,
            fill: fill.map(round),
            detail: ValidityDetail(
                visibleFraction: round(visibleFraction),
                humanFraction: round(humanFraction),
                feetFraction: round(feetFraction),
                /* Named travelInWidths in the shared type, carrying body heights
                   here. Renaming the field means touching the web build too, so
                   it is flagged in BUILD-NOTES rather than changed on one side. */
                travelInWidths: round(travelInHeights),
                shoulderWidth: round(median(shoulderWidths) ?? 0),
                subjectFill: round(fill ?? 0)
            )
        )
    }

    // MARK: - Helpers

    private static func within(_ x: Double, _ range: ClosedRange<Double>) -> Bool {
        x.isFinite && x >= range.lowerBound && x <= range.upperBound
    }

    private static func round(_ x: Double) -> Double {
        guard x.isFinite else { return 0 }
        return Foundation.round(x * 1000) / 1000
    }

    private static func median(_ arr: [Double]) -> Double? {
        let usable = arr.filter { $0.isFinite }
        if usable.isEmpty { return nil }
        let sorted = usable.sorted()
        return sorted[sorted.count / 2]
    }
}

/*
  WHY THIS FILE ALONE DOES NOT FIX THE CRASH.

  This file is now safe against any array length. It is not the only file that
  reads landmarks by index.

  Biomechanics_2.centreOfMass indexes LEFT_HIP, RIGHT_HIP, LEFT_KNEE,
  RIGHT_KNEE, LEFT_ANKLE and RIGHT_ANKLE directly, with no bounds check.
  pressureIndex indexes the lead and trail ankles. Phases.mostHorizontalArm
  indexes shoulders and wrists. All of them run after this one, on the same
  frames.

  So making Validity safe moves the trap from Validity into Biomechanics rather
  than removing it. The change that actually removes it is in
  VisionPoseProvider: return the full thirty three slot MediaPipe layout, with
  the joints Vision does not have written in as placeholders at visibility zero.
  Landmarks.swift already documents that contract, and this file, along with
  every other consumer, already reads against it.

  The alternative, giving iOS its own thirteen slot index space, means rewriting
  Biomechanics, Phases, Sequencing and Scoring against a second map and
  maintaining two of everything from then on, for the same result.
*/
