//
//  PosePrior.swift
//  Swingline
//
//  The analytic pose prior, the dataset logger that feeds the future
//  learned priors, and the GMM prior inference foundation (Task 5). The
//  grip fusion this file used to finish with has been removed; both wrists
//  are carried separately now, and the only survivor of that machinery is
//  the small SwingViewClassifier (face-on versus down-the-line), which
//  other files still read.
//
//  OCCLUSION OVERHAUL (this pass). The midpoint magnet (Task 3 / Fix 5) is
//  REMOVED ENTIRELY, config and all: even in its path-only form its pulls
//  were corrections built on a visibility signal the research says cannot
//  be trusted, and testing agreed. Its replacement lives where each failure
//  actually is:
//
//    The wrist is handled by REJECTION in LandmarkCleanupEngine (wrist
//    occlusion rejection, visibility under 0.6 masks the sample, the
//    standard gap fill bridges 1 to 4 frame holes and holds longer ones),
//    which obeys that engine's ONE RULE instead of inventing pulls here.
//
//    The occluded SHOULDER gets its own stage in this file (shoulder
//    occlusion projection, below): MediaPipe guesses an occluded trail
//    shoulder inward with rotational errors the literature puts at 36 to
//    42 degrees, and the projection re-places it from the visible
//    shoulder, the hips and the clip's own rigid-torso geometry.
//
//    The ANKLE gets a stronger ground stage (extended Fix 4): foot depth
//    is flattened to the clip median because MediaPipe's z is noise at
//    the feet, and the ankle is anchored near its own measured height
//    above the turf so it can neither sink into the ground nor hover.
//
//  The corrector still captures leadHandPathNormX/Y for HandPathBuilder,
//  now as the corrected lead wrist track itself (post cleanup, post
//  shoulder projection, pre fusion), so UploadProcessor's wiring is
//  unchanged and the drawn trace follows the measured, occlusion-hardened
//  wrist rather than a magnet's implication.
//
//  A NOTE ON PROVENANCE, recorded so it cannot be mistaken for an oversight:
//  the original PosePrior.swift was not attached to this round (the same
//  situation Validity.swift was in last round). Its public surface is fully
//  recoverable from the call sites in MediaPipePoseProvider
//  (SwingViewClassifier.detectView), UploadProcessor
//  (PosePriorCorrector.analytic(dominantHand:).run(_:qc:),
//  SwingDatasetLogger.log(frames:qc:source:)) and the TrackingQC field names
//  (priorBoneCorrections, priorRangeCorrections, gripFramesFused), and this
//  file implements exactly that surface. DIFF THIS AGAINST YOUR ORIGINAL
//  before merging: thresholds inside the reconstructed stages (bone blend,
//  fold angle, view-detection ratio) are this file's choices, and if your
//  original tuned them differently, your numbers win.
//
//  WHERE THE LINE SITS
//
//  LandmarkCleanupEngine rejects data and bridges holes from the joint's own
//  measurements: it never invents. This file is the one place mild invention
//  is permitted, and every stage here is bounded so the invention stays mild:
//  bone projection moves a joint along a direction that was measured, toward
//  a length this golfer's own clip established; the fold guard relaxes an
//  impossible angle toward the joint's own trajectory; the shoulder
//  projection re-places an occluded shoulder from anchors that were
//  measured this frame and a torso geometry this golfer's own clip
//  established, at half weight; the GMM step is trust-region capped and
//  only runs when a trained model actually ships. Every correction is
//  counted in TrackingQC, because a pipeline that corrects data quietly is
//  a pipeline that lies.
//
//  ONFORM PARITY ADDITIONS (final accuracy overhaul), as amended by the
//  occlusion overhaul, each recorded at its implementation site:
//
//    Fix 1, torso width and ratio constraints. Shoulder width (11 to 12) and
//    hip width (23 to 24) are body constants; the tracker's are not,
//    especially down the line where depth noise makes the projected widths
//    drift. World widths are projected toward the clip medians, and in BOTH
//    spaces the shoulder to hip RATIO is held near its clip median, which is
//    the criterion that separates a tracking glitch (one width collapses,
//    the other does not, ratio spikes) from honest foreshortening (both
//    widths shrink together, ratio survives).
//
//    Shoulder occlusion projection (occlusion overhaul, Fix S). An occluded
//    shoulder, visibility under 0.6, is re-placed from the visible
//    shoulder, the hip centre and the clip's own rigid-torso geometry, at
//    half weight. Runs BEFORE the torso width stage on purpose: that
//    stage's symmetric scaling would otherwise split an inward-collapsed
//    shoulder's error with the good shoulder, moving a well measured joint
//    to pay for a badly measured one.
//
//    Fix 4, ground plane, extended. Per-side turf levels are estimated from
//    the clip's own heel and toe positions; feet may never sink below them,
//    near-plane heels and toes are gently anchored to them, and a heel
//    clearly above its plane is counted as a heel lift instead of being
//    fought. NEW: foot depth (heel, toe, ankle z) is flattened to the clip
//    median per joint per side, because MediaPipe's z is unreliable at the
//    feet and is what dragged ankles through the turf; and the ankle is
//    anchored near its own clip-measured height above the plane, so it can
//    neither sink nor float while a genuine heel lift still moves it
//    freely.
//
//    Fix 5 is GONE. The midpoint magnet is removed entirely; see the file
//    header for where each of its jobs went.
//
//  SKELETON INTEGRITY PASS (frame audits of the two DTL reference videos).
//  Two additions, each detailed at its implementation site:
//
//    The shoulder projection gains a MEDIAL COLLAPSE GUARD. The audits
//    caught the trail shoulder snapping onto the neck through the top and
//    the finish while MediaPipe kept reporting it CONFIDENT, so the
//    visibility bar alone missed the worst frames. The guard convicts on
//    geometry instead: a one sided spike in the shoulder to hip width
//    ratio plus a one sided disagreement with the rigid torso implication
//    names the collapsed side, and the projection re-places it regardless
//    of its reported visibility. Counted in qc.shoulderCollapseFrames.
//
//    A GRIP CLUSTER ANCHOR (Fix G, below). The audits' floating wrist:
//    cleanup rightly rejects an occluded wrist, the long gap fill HOLDS
//    its last position, and the hold ends up parked on the hip or chest
//    while the other wrist rides the club. When exactly one wrist is
//    confidently measured and the other carries only a hold, and the two
//    sit wider apart than this golfer's own clip says a grip allows, the
//    weak wrist is drawn back to grip distance from the trusted one.
//    Counted in qc.gripClusterFrames.
//
//  ORDER OF OPERATIONS (conflict C3, amended by the skeleton overhaul)
//
//    0. view profile                  clip-level DTL versus face-on
//                                     classification routes per-view
//                                     thresholds through one pipeline
//    1. shoulder projection           FIRST, world-space rigid-body reseat
//                                     (Fix S rebuilt, collapse guard on
//                                     pose-invariant width and radius).
//                                     Before the bones on purpose: the
//                                     bone stage restores length by moving
//                                     the DISTAL joint, so running it
//                                     against a collapsed shoulder used to
//                                     drag the elbow inward and the wrist
//                                     after it, manufacturing the stump
//                                     and the cross-link downstream of one
//                                     bad joint
//    1b. torso width and ratio        world widths, both-space ratios
//                                     (Fix 1), after the reseat so its
//                                     symmetric scaling never splits a
//                                     collapse error with the good side
//    1c. bone-length projection       world space, pose-invariant lengths,
//                                     proximal to distal from corrected
//                                     roots
//    2. impossible-fold relaxation    world space
//    2b. ground plane                 both spaces, feet only (Fix 4,
//                                     extended: the up-sign inversion is
//                                     FIXED, depth flattening now restores
//                                     the rigid foot length, the ankle
//                                     anchor is floored above the turf)
//    2c. grip cluster anchor          both spaces, weak wrist only (Fix G
//                                     rebuilt: wider weak band, weakness
//                                     scaled pull, forearm-axis target,
//                                     edge ramps), before the hand
//                                     collapse guard so the palm is
//                                     restored against a wrist that is
//                                     already back on the club
//    3. hand collapse guard           both spaces, both hands. The Gemini
//                                     audit of Video 1: at impact, with the
//                                     hands past 4 m/s, MediaPipe collapses
//                                     the index and pinky knuckles ONTO the
//                                     wrist (distance 0.000 against a
//                                     healthy 0.022 to 0.028), which no
//                                     anatomy permits at any speed. The
//                                     guard restores the golfer's own
//                                     clip-median separation along the
//                                     measured forearm direction.
//    5. GMM prior (Task 5)            norm space, mirrored to world, optional
//    6. ground backstop               penetration clamps only, idempotent,
//                                     run()'s own last word. UploadProcessor
//                                     SHOULD call enforceGroundBackstop once
//                                     more AFTER AdaptiveSmoothing: a zero
//                                     phase Butterworth can undershoot the
//                                     hard corner a clamp writes, which is
//                                     the residual below-turf ankle on an
//                                     otherwise corrected clip
//
//  Grip fusion (once step 6, "LAST, per conflict C3") is REMOVED. Both
//  wrists are now carried and drawn separately, so the corrector's last act
//  is capturing the lead wrist for the hand path rather than collapsing the
//  two wrists into a grip. The view classifier that fusion used to need
//  survives as SwingViewClassifier, below.
//
//  House rule: no em dashes anywhere.
//

import Foundation

// MARK: - Swing view classifier

/*
  Which way the camera looks, from shoulder depth separation. This used to be
  a member of GripPointFusion, which fused the two wrists into one grip point
  as the pipeline's last step. Grip fusion has been removed: both wrists are
  now carried and drawn separately, on every backend and both paths. The view
  classifier survives the removal because other files still read the
  distinction (the overlay's face-on versus down-the-line handling among
  them), so it keeps its own small home here under an honest name. Any code
  that referred to GripPointFusion.detectView should now name
  SwingViewClassifier.detectView; the provider's detectView method already
  does.
*/
enum SwingViewClassifier {

    /*
      Face on, the shoulders sit at similar depth; down the line they are
      separated in depth by close to their full anatomical width. The 0.6
      ratio splits the two regimes with room for an angled camera on either
      side.
    */
    static func detectView(leftShoulder: Landmark?, rightShoulder: Landmark?) -> SwingView {
        guard let l = leftShoulder, let r = rightShoulder,
              let zl = l.z, let zr = r.z, zl.isFinite, zr.isFinite,
              l.x.isFinite, r.x.isFinite else { return .faceOn }
        let dx = l.x - r.x, dy = l.y - r.y
        let planar = (dx * dx + dy * dy).squareRoot()
        guard planar > 1e-6 else { return .faceOn }
        return abs(zl - zr) > 0.6 * planar ? .downTheLine : .faceOn
    }

    /*
      Clip-level classification, for routing the corrector's DTL and face-on
      profiles. The per-frame rule above votes on every frame where both
      shoulders were confidently seen and carried depth; the majority wins.
      Address and finish dominate a clip's frame count, and those are the
      windows where the camera angle reads cleanest, so a simple majority is
      robust to the rotation sweeping the instantaneous ratio through both
      regimes mid swing. Defaults to face-on when depth never showed up,
      which leaves every threshold at its milder setting, the safe side.
    */
    static func classifyClip(_ timeline: PoseTimeline, minVisibility: Double = 0.6) -> SwingView {
        let ls = Landmarks.LEFT_SHOULDER, rs = Landmarks.RIGHT_SHOULDER
        guard max(ls, rs) < timeline.jointCount else { return .faceOn }
        var dtl = 0, face = 0
        for i in 0..<timeline.frameCount {
            let lx = timeline.norm.x[ls][i], ly = timeline.norm.y[ls][i]
            let rx = timeline.norm.x[rs][i], ry = timeline.norm.y[rs][i]
            let lz = timeline.norm.z[ls][i], rz = timeline.norm.z[rs][i]
            let lv = timeline.norm.visibility[ls][i]
            let rv = timeline.norm.visibility[rs][i]
            guard lx.isFinite, rx.isFinite, lz.isFinite, rz.isFinite,
                  !(lv.isFinite && lv < minVisibility),
                  !(rv.isFinite && rv < minVisibility) else { continue }
            let dx = lx - rx, dy = ly - ry
            let planar = (dx * dx + dy * dy).squareRoot()
            guard planar > 1e-6 else { continue }
            if abs(lz - rz) > 0.6 * planar { dtl += 1 } else { face += 1 }
        }
        return dtl > face ? .downTheLine : .faceOn
    }
}

// MARK: - Shoulder occlusion projection (Fix S, occlusion overhaul)

/*
  The known MediaPipe failure this replaces the magnet's job on the torso
  with: when a shoulder is occluded (the trail shoulder crossing behind the
  chin and lead arm through the downswing, on a right hander the RIGHT
  shoulder), the tracker does not report it missing, it GUESSES, and the
  guess collapses inward toward the body, with shoulder rotation errors the
  sports biomechanics literature measures at 36 to 42 degrees. No amount of
  smoothing fixes a confident wrong guess, so this stage re-derives the
  occluded shoulder from things that were actually measured.

  THE RIGID TORSO MODEL. In each space's image plane, the torso is treated
  as rigid: relative to the hip centre, each shoulder sits at a fixed radius
  and at a fixed angular offset from the OTHER shoulder's direction. Both
  constants are read from this golfer's own clip, as medians over frames
  where both shoulders and both hips were confidently seen. When one
  shoulder drops under the visibility bar while the other shoulder and both
  hips are confidently seen, the visible shoulder's measured direction from
  the hip centre plus the remembered angular offset and radius imply where
  the occluded shoulder has to be, and the occluded shoulder is blended
  halfway toward that implication.

  Why the VISIBLE shoulder carries the rotation rather than the hip line:
  shoulders rotate further than hips through a swing (the X factor is one of
  this app's own metrics), so projecting from hip direction alone would drag
  measured shoulder rotation toward hip rotation and corrupt the very angle
  the fix exists to protect. The visible shoulder IS the measured shoulder
  rotation; the model only transports it across the torso.

  The model is exact for in-plane rotation and approximate under
  foreshortening, which is why the blend is 0.5 and not 1.0: a soft
  correction per the brief, so residual model error is split with whatever
  signal the tracker still has. Runs per space with that space's own
  geometry and medians, so norm and world move in lockstep in rule and
  count. Depth is left untouched: the model is an image-plane statement and
  inventing z would be a lie. On the Vision backend there is no per-joint
  visibility, nothing ever reads as occluded, and the stage is inert, which
  is the honest behaviour.
*/
public struct ShoulderProjectionConfig {
    public var enabled: Bool = true
    /// A shoulder below this visibility is treated as occluded (the
    /// brief's 0.6).
    public var occludedBelow: Double = 0.6
    /// The anchors (the other shoulder and both hips) must all clear this
    /// bar for a projection to fire, and for a frame to feed the clip
    /// medians. An anchor below it could move a joint it cannot vouch for.
    public var anchorMinVisibility: Double = 0.6
    /// Fraction of the way the occluded shoulder moves toward the
    /// rigid-torso implication (the brief's 0.5, a soft correction).
    public var blend: Double = 0.5

    /*
      The medial collapse guard (skeleton integrity pass). The frame audits
      of both DTL reference videos caught the failure the visibility bar
      cannot see: through the top and the finish the trail shoulder snaps
      onto the neck, a hard "V" at the neck and shoulder junction, while
      MediaPipe keeps reporting the guessed position CONFIDENT. A bar on
      visibility never fires on a confident wrong guess.

      The guard convicts on geometry instead, with the same criterion Fix 1
      already trusts: under honest rotation both projected torso widths
      shrink together and the shoulder to hip ratio survives, while a one
      sided collapse crushes the shoulder width alone and the ratio spikes.
      A frame whose ratio falls under the collapse fraction of its own clip
      median is a collapse, and the side that collapsed is the one whose
      position disagrees more with its rigid torso implication. That side
      is then projected exactly as an occluded shoulder would be, at the
      firmer collapse blend, whatever its reported visibility said.
    */
    public var collapseGuardEnabled: Bool = true
    /// A shoulder to hip width ratio below this fraction of the clip
    /// median marks the frame as a one sided collapse. Honest DTL
    /// foreshortening shrinks both widths together and never gets near it.
    ///
    /// RETIRED AS THE PRIMARY DETECTOR by the skeleton overhaul: the
    /// premise is wrong for a golf swing. Shoulders rotate roughly twice
    /// as far as hips (the X factor, this app's own metric), so the
    /// PROJECTED shoulder to hip ratio legitimately sweeps through a wide
    /// range across the swing. Down the line the ratio at the top sits far
    /// ABOVE the clip median (the shoulder line swings broadside to the
    /// camera), which is exactly where the collapse happens, so a genuine
    /// collapse there almost never crossed 0.55 of the median and the
    /// guard sat silent through the worst frames. The field stays so a
    /// tuned config still decodes; the detectors that replaced it are the
    /// two below, both built on pose-invariant quantities.
    public var collapseRatioFraction: Double = 0.55
    /// WORLD-SPACE WIDTH CRUSH, the primary detector. Metric shoulder
    /// width (11 to 12, 3D) is a body constant no rotation can change, so
    /// a frame whose world width falls under this fraction of the clip
    /// median is a collapse by definition, at any phase, from any camera.
    public var collapseWidthFraction: Double = 0.72
    /// NECK PROXIMITY, the image-space emergency detector (the brief's
    /// "within 10 pixels of the neck"): a frame whose PLANAR normalised
    /// shoulder separation falls under this fraction of its own clip
    /// median is the on-screen "V at the neck" directly. In norm space a
    /// real DTL rotation can shrink the planar separation honestly, so
    /// this bar sits low and only catches the near-coincident cases the
    /// world test might miss when world data is degraded.
    public var neckProximityWidthFraction: Double = 0.35
    /// The convicted shoulder's implication error must exceed the other
    /// side's by at least this factor, so a frame where both sides look
    /// wrong (a genuinely bad frame) convicts nobody and the other stages
    /// own it.
    public var collapseErrorDominance: Double = 1.5
    /// ... and must exceed this fraction of that shoulder's own median
    /// radius from the hip centre, so plane noise can never convict.
    public var collapseMinErrorRadiusFraction: Double = 0.15
    /// The pull for a convicted collapse. Firmer than the visibility
    /// path's soft 0.5 because a confidently wrong guess carries no
    /// residual signal worth splitting the correction with.
    public var collapseBlend: Double = 0.85

    public init() {}
}

// MARK: - Grip cluster anchor (Fix G, skeleton integrity pass)

/*
  The failure this repairs, from the frame audits of both DTL reference
  videos: through the downswing and follow-through one wrist (the one
  crossing behind the torso) drops under the occlusion bar, the cleanup
  rightly rejects it, and the long-gap fill HOLDS its last known position.
  The hold is honest as a fill policy, but the body keeps rotating past the
  frozen point, so on screen a wrist ends up parked on the hip or chest
  while the other wrist rides the club, an anatomical impossibility: through
  a full swing both hands stay on the grip, so the two wrists can never sit
  farther apart than a hand's breadth.

  The repair is the same species of bounded invention the bone projection
  performs. When exactly ONE wrist is confidently measured and the OTHER
  carries only a hold or a deeply dimmed sample, and the pair sits wider
  than this golfer's own clip says a grip allows, the weak wrist is pulled
  along the line toward the trusted wrist until their separation matches
  the clip's own confident grip separation. The pull is purely radial: the
  weak track keeps whatever direction it still has, and the only thing
  asserted is a distance, read from measured frames of this very clip. A
  confidently measured wrist is never moved on either end, so a golfer who
  genuinely takes a hand off the club (a drill, a one handed swing) keeps
  both wrists exactly where the tracker measured them: the stage cannot
  fire unless one side is trusted and the other is not.

  Continuity comes free rather than from a ramp: the corrected wrist tracks
  the measured anchor, and at both edges of a corrected run the held
  position and the truth roughly coincide (the run starts the moment the
  hold first drifts past the trigger, and ends when the wrist is measured
  again near the club), so the correction is smallest exactly where it
  borders measured frames. Per space with that space's own medians and
  units, depth untouched, counted once per frame into qc.gripClusterFrames.
*/
public struct GripClusterConfig {
    public var enabled: Bool = true
    /// Frames where BOTH wrists clear this bar feed the clip's confident
    /// grip separation median. Statistics only; the firing bars are the
    /// two below.
    public var trustedMinVisibility: Double = 0.6
    /// The anchor wrist must clear this bar for the stage to fire. Sits
    /// under the trusted bar on purpose (the audits' finding): through
    /// the very windows where one wrist is held, the OTHER often reads
    /// 0.5 to 0.6, still a real measurement, and demanding 0.6 of it
    /// left the whole stage dead exactly when it was needed.
    public var anchorMinVisibility: Double = 0.5
    /// Only a wrist strictly below this visibility can be moved, and the
    /// pull scales with how far below it sits (a deep hold takes the full
    /// blend, a mid-trust bridge a fraction). WIDENED from 0.3 by the
    /// skeleton overhaul: the cleanup's short-gap PCHIP bridges inherit
    /// the weaker neighbour's visibility times 0.95, which lands well
    /// ABOVE 0.3, so bridged wrists drifting off the club were invisible
    /// to the old bound. Everything under the anchor bar is now in reach,
    /// weighted by its own weakness. Confidently measured wrists remain
    /// untouchable, and on the Vision backend (no visibility) nothing
    /// ever reads weak and the stage stays inert, the honest behaviour.
    public var weakMaxVisibility: Double = 0.45
    /// Separation past this multiple of the clip's own confident grip
    /// separation triggers the pull. LOWERED from 1.75 by the skeleton
    /// overhaul: under the old factor a held wrist floated detached by
    /// up to three quarters of a grip width before anything fired, which
    /// is most of the on-screen "hovering in space". The natural stagger
    /// of two hands on the handle sits well inside 1.35, and the DTL
    /// profile tightens this further.
    public var separationTriggerFactor: Double = 1.35
    /// Trigger floor and separation target when the clip never produced a
    /// confident grip median of its own, as a fraction of the clip-median
    /// forearm: two gripped wrists sit well inside half a forearm.
    public var fallbackSeparationForearmFraction: Double = 0.45
    /// Fraction of the way the weak wrist moves toward the implied grip
    /// distance, at full weakness. Firmer than the shoulder projection's
    /// soft 0.5 because a hold is not a measurement and carries no
    /// residual signal worth splitting the correction with.
    public var blend: Double = 0.85
    /// Aim the pull along the anchor side's own forearm axis (elbow to
    /// wrist) when that elbow can vouch for itself: the club hangs off
    /// that axis at the grip, so the second hand sits along it, and the
    /// held wrist's own stale bearing (the old target) could park the
    /// hand at grip DISTANCE but on the wrong side of the handle. The
    /// axis is signed toward the weak wrist's current side so the pull
    /// never crosses the hand over the grip. Falls back to the stale
    /// bearing when the elbow is dim.
    public var forearmDirectionTarget: Bool = true
    /// The pull fades in over this many frames at the start of each
    /// corrected run, so the anchor engaging is a glide rather than the
    /// audits' step. No fade at the run's END on purpose: a run usually
    /// ends because the wrist was re-measured near the club, and the
    /// last held frames should sit as close to that truth as the pull
    /// can put them, which is what makes the re-acquisition seamless.
    public var edgeRampFrames: Int = 3

    public init() {}
}

// MARK: - Hand collapse guard (kinematic distance guard, Video 1 fix)

/*
  The failure this guards against, from the Gemini audit of Video 1: in the
  impact window, with the hands moving faster than about 4 m/s, motion blur
  makes MediaPipe collapse the index (19) and pinky (17) knuckles onto the
  wrist (15). The measured wrist-to-palm distance drops from a healthy 0.022
  to 0.028 normalised to exactly 0.000, and downstream wrist-angle and
  release metrics read garbage at the one instant that matters most.

  A knuckle at zero distance from the wrist is not a pose, it is a failure
  signature, so the correction here is the same species of mild invention
  the bone projection already performs: the palm centre is pushed back out
  along a direction that was MEASURED (elbow to wrist, this very frame) to
  a separation this golfer's own clip established (the clip median), and
  the two knuckles keep their own lateral spread, they translate together.
  Both hands, both spaces, each space in its own units, counted in QC.

  Two deliberate deviations from the brief's bare numbers, recorded here:

    The 0.015 collapse threshold is normalised units and cannot be applied
    raw to a golfer filmed small in a wide frame, whose HEALTHY hand span
    might be under 0.015. The working threshold is the smallest of the
    absolute 0.015 (norm space only), half the clip-median hand span, and
    the anatomical minimum below. A tiny golfer therefore gets a
    proportionally tiny threshold instead of wall-to-wall false positives.

    The speed gate prefers the world channel (metres per second, the
    brief's 4.0) and falls back to normalised units per second when world
    is absent, because a purely image-space gate would misread a camera
    zoom as hand speed. The gate also protects legitimate foreshortening:
    a palm aimed square at the lens collapses the 2D distance honestly,
    but that happens at address and takeaway speeds, not at 4 m/s.
*/
public struct HandCollapseGuardConfig {
    public var enabled: Bool = true
    /// Absolute collapse ceiling in normalised space (the brief's 0.015).
    public var collapseDistanceNorm: Double = 0.015
    /// Relative ceiling: this fraction of the clip-median hand span.
    public var collapseMedianFraction: Double = 0.5
    /// Speed gate when world landmarks carry the wrist, metres per second.
    public var minHandSpeedWorld: Double = 4.0
    /// Fallback speed gate in normalised frame units per second.
    public var minHandSpeedNorm: Double = 1.2
    /// Anatomical minimum separation as a fraction of the clip-median
    /// forearm (wrist to knuckles runs about a third of a forearm).
    public var minSeparationForearmFraction: Double = 0.22
    /// Restoration target as a forearm fraction when the clip never
    /// produced a healthy median of its own.
    public var defaultSeparationForearmFraction: Double = 0.30

    public init() {}
}

// MARK: - Ground plane (Fix 4)

/*
  Feet obey the turf. The tracker's do not: heels float a few pixels above
  the ground at address, sink below it through the downswing, and jitter
  around it in the finish hold, none of which a planted foot can do. The fix
  estimates where the turf actually is from the clip's own feet and applies
  three rules, per side, per space, in that space's own units:

    1. Nothing sinks below the plane. A heel, toe or ankle past the plane is
       clamped back to it, fully, because turf is not negotiable.
    2. A heel or toe hovering within the snap zone is gently pulled onto the
       plane, which kills the float and the near-ground jitter without ever
       fighting a real lift.
    3. A heel clearly above the plane is a HEEL LIFT, a real event the
       constraint must respect: it is counted (lead and trail separately,
       the trail heel lifting through impact is the one the brief named)
       and left strictly alone.

  The plane is estimated per side rather than as one line, so a tilted
  camera or a sloped lie does not break it: each foot's turf level is the
  toward-ground 75th percentile of that foot's own heel and toe positions
  across the clip, which is robust both to lifted-heel frames (they sit on
  the away-from-ground side of the distribution) and to the occasional
  tracking outlier below it. Which y direction means "up" is read from the
  data (the hips sit above the feet) rather than assumed, so the stage
  cannot be broken by a coordinate convention.

  All scales are fractions of the clip-median shin length, the same
  golfer-relative yardstick the hand collapse guard uses, so a golfer
  filmed small is judged by their own geometry.

  OCCLUSION OVERHAUL EXTENSIONS, two, both aimed at the sinking ankle:

  DEPTH FLATTENING. MediaPipe's z is at its least reliable at the feet, and
  a noisy foot depth is what let the 3D ankle wander through the turf while
  its 2D position looked sane. Per the brief, foot depth is not used as a
  measurement at all: each foot joint's z (heel, toe, ankle, per side, per
  space) is replaced with that joint's own clip-median z. ONE RECORDED
  DEVIATION from the brief's literal "z = 0": in world space z is measured
  from the hip centre, so a literal zero would teleport the feet onto the
  hip depth plane, an actual (and wrong) claim. The clip median is the
  faithful form of "use 2D only": a constant, so depth noise can move
  nothing, while the 3D view keeps anatomically placed feet.

  THE ANKLE ANCHOR. The ankle joint sits a fixed height above the sole, so
  its resting level is ABOVE the turf, and snapping it onto the turf (the
  brief's literal ankle.y = groundY) would flatten every planted foot. The
  anchor instead measures the ankle's own toward-ground level from the clip
  (same robust percentile as the turf estimate) and holds the ankle near
  THAT level: below it past tolerance is clamped up, near it is gently
  blended on, clearly above it (a heel lift raises the ankle too) is left
  strictly alone. The turf-level penetration clamp remains as the hard
  backstop underneath.
*/
public struct GroundPlaneConfig {
    public var enabled: Bool = true
    /// Heels and toes within this height above the plane are anchored to
    /// it, as a fraction of the clip-median shin length.
    public var snapZoneShinFraction: Double = 0.06
    /// How strongly a snap-zone point is pulled onto the plane. A blend,
    /// not a teleport, so the anchoring cannot itself become a step.
    public var snapBlend: Double = 0.7
    /// A heel higher above the plane than this fraction of the shin counts
    /// as a lifted heel and is never touched.
    public var liftThresholdShinFraction: Double = 0.12
    /// Magnet/feet task: a point is only clamped as a penetration when it
    /// sits deeper than this fraction of the shin below the plane. The plane
    /// is a median estimate with its own noise, so a toe a hair under it on
    /// a planted foot is within tolerance and left alone; clamping those
    /// tiny excursions was what flattened the foot's angle frame to frame.
    /// Real penetrations, several centimetres of shin below ground, still
    /// clamp.
    public var penetrationToleranceShinFraction: Double = 0.03

    /// Occlusion overhaul: replace each foot joint's z with its own clip
    /// median, per side, per space. See the config note for why the median
    /// and not the brief's literal zero.
    public var flattenFootDepth: Bool = true
    /// Occlusion overhaul: hold the ankle near its own clip-measured level
    /// above the turf. Off restores the previous behaviour (turf clamp
    /// only) for diffing.
    public var ankleAnchorEnabled: Bool = true
    /// The ankle's snap zone around its own level, as a shin fraction. A
    /// touch wider than the heel and toe zone because the ankle's level is
    /// itself an estimate stacked on the turf estimate.
    public var ankleSnapZoneShinFraction: Double = 0.08
    /// How strongly a near-level ankle is pulled onto its level. Softer
    /// than the heel and toe snap: the ankle carries the shin, and an
    /// aggressive pull there would kick visibly up the leg.
    public var ankleSnapBlend: Double = 0.5
    /// The ankle joint's minimum anatomical height above the sole, as a
    /// shin fraction (the malleolus sits roughly a tenth of a shin up).
    /// The ankle's resting level is never taken below turf plus this, so
    /// a clip whose measured ankle level came out underground (noise
    /// stacked on noise) gets a floored anchor instead of no anchor: the
    /// previous nil fallback handed the ankle to the bare turf clamp,
    /// which could legally park the ankle ON the ground, a flattened
    /// foot by construction.
    public var minAnkleHeightShinFraction: Double = 0.10
    /// Occlusion overhaul amendment: after flattening each foot joint's
    /// depth to its clip median, restore the clip-median 3D heel-to-toe
    /// length by spreading the two constant depths about the ankle's.
    /// Per-joint medians of a noisy depth channel can land nearly on top
    /// of each other down the line (where the foot points along the
    /// optical axis and the planar separation is small too), and three
    /// coincident constants is exactly the "three vertical joints" stack
    /// the audits show. The restore keeps depth constant per joint, so
    /// no per-frame depth noise returns; only the constants move apart.
    public var restoreFootLengthAfterFlatten: Bool = true

    public init() {}
}

// MARK: - GMM pose prior (TASK 5, inference side)

/*
  Foundation for the learned pose prior, Vectors C, Q and L. The dataset that
  trains it accumulates via SwingDatasetLogger below; the training script
  (train_pose_gmm.py) exports means, variances and weights as JSON; this type
  loads that JSON and scores each frame's joint configuration.

  Poses are scored in a canonical frame: hip-centre subtracted, divided by
  shoulder width, so a tall golfer near the camera and a short one far away
  produce the same configuration vector. A frame whose log-likelihood falls
  below the trained threshold is pulled a bounded step toward the mean of its
  most responsible component. The step is a trust region twice over: only a
  quarter of the gap per frame, and never more than a fifth of a shoulder
  width per joint, so the prior can rescue a wrist that teleported into the
  golfer's chest but cannot redraw a swing into the training set's average.

  Diagonal covariances only in v1, matching the training script's default: a
  full 66 by 66 covariance per component needs matrix solves this file does
  not want to hand-roll, and the diagonal model already answers "is this a
  human golf pose" well enough to gate corrections.

  Ships disabled by construction: loadFromBundle returns nil until a
  pose_gmm.json actually exists in the bundle, and the corrector simply skips
  the stage. Zero in qc.gmmFramesEvaluated is the honest record of that.
*/
public struct GMMPosePrior {

    struct Normalization: Decodable {
        var centerA: Int
        var centerB: Int
        var scaleA: Int
        var scaleB: Int
        var minScale: Double
    }

    struct Model: Decodable {
        var version: Int
        var jointCount: Int
        var covarianceType: String
        var weights: [Double]
        var means: [[Double]]
        var variances: [[Double]]
        var logLikelihoodThreshold: Double
        var normalization: Normalization
    }

    public struct Config {
        public var pullWeight: Double = 0.25
        /// Per-joint step cap in canonical units (shoulder widths).
        public var maxJointStep: Double = 0.2
        /// A frame missing more canonical dimensions than this is skipped
        /// rather than scored against filled-in guesses.
        public var maxMissingJoints: Int = 4
        public init() {}
    }

    private let model: Model
    private let logWeights: [Double]
    private let logNormalizers: [Double]  // per component: -0.5 * (D ln 2pi + sum ln var)
    private let mixtureMean: [Double]
    private let config: Config

    public static func loadFromBundle(resource: String = "pose_gmm", config: Config = Config()) -> GMMPosePrior? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json") else { return nil }
        return GMMPosePrior(url: url, config: config)
    }

    public init?(url: URL, config: Config = Config()) {
        guard let data = try? Data(contentsOf: url),
              let model = try? JSONDecoder().decode(Model.self, from: data),
              model.covarianceType == "diag",
              !model.weights.isEmpty,
              model.weights.count == model.means.count,
              model.weights.count == model.variances.count,
              model.means.allSatisfy({ $0.count == model.jointCount * 2 }),
              model.variances.allSatisfy({ $0.count == model.jointCount * 2 })
        else {
            print("[PosePrior] pose_gmm.json missing, malformed, or not diagonal; GMM stage disabled")
            return nil
        }
        self.model = model
        self.config = config

        let d = Double(model.jointCount * 2)
        self.logWeights = model.weights.map { Foundation.log(max($0, 1e-12)) }
        self.logNormalizers = model.variances.map { v in
            -0.5 * (d * Foundation.log(2 * Double.pi) + v.reduce(0) { $0 + Foundation.log(max($1, 1e-12)) })
        }
        var mean = [Double](repeating: 0, count: model.jointCount * 2)
        for (k, m) in model.means.enumerated() {
            for j in 0..<mean.count { mean[j] += model.weights[k] * m[j] }
        }
        self.mixtureMean = mean

        print("[PosePrior] GMM prior loaded: \(model.weights.count) components, threshold \(model.logLikelihoodThreshold)")
    }

    /// Score every frame; pull the improbable ones. Norm space is the scored
    /// space (the space the model was trained on); the same canonical delta,
    /// scaled by this frame's world shoulder width, is mirrored into world so
    /// the drawn skeleton and the printed numbers keep moving together.
    func run(_ timeline: inout PoseTimeline, qc: inout TrackingQC) {
        let joints = min(model.jointCount, timeline.jointCount)
        guard joints > 0 else { return }
        let norm = model.normalization
        guard max(norm.centerA, norm.centerB, norm.scaleA, norm.scaleB) < timeline.jointCount else { return }

        for i in 0..<timeline.frameCount {
            // Canonical frame from the normalised image landmarks.
            guard let hipX = finitePair(timeline.norm.x[norm.centerA][i], timeline.norm.x[norm.centerB][i]),
                  let hipY = finitePair(timeline.norm.y[norm.centerA][i], timeline.norm.y[norm.centerB][i]),
                  timeline.norm.x[norm.scaleA][i].isFinite, timeline.norm.x[norm.scaleB][i].isFinite
            else { continue }
            let sdx = timeline.norm.x[norm.scaleA][i] - timeline.norm.x[norm.scaleB][i]
            let sdy = timeline.norm.y[norm.scaleA][i] - timeline.norm.y[norm.scaleB][i]
            let scale = max((sdx * sdx + sdy * sdy).squareRoot(), norm.minScale)

            var c = [Double](repeating: 0, count: model.jointCount * 2)
            var measuredDim = [Bool](repeating: false, count: model.jointCount)
            var missing = 0
            for j in 0..<model.jointCount {
                if j < joints, timeline.norm.x[j][i].isFinite, timeline.norm.y[j][i].isFinite {
                    c[2 * j] = (timeline.norm.x[j][i] - hipX) / scale
                    c[2 * j + 1] = (timeline.norm.y[j][i] - hipY) / scale
                    measuredDim[j] = true
                } else {
                    // A never-measured joint is scored at the mixture mean so
                    // it neither drags the likelihood down nor gets written.
                    c[2 * j] = mixtureMean[2 * j]
                    c[2 * j + 1] = mixtureMean[2 * j + 1]
                    missing += 1
                }
            }
            guard missing <= config.maxMissingJoints else { continue }

            qc.gmmFramesEvaluated += 1
            let (logLik, bestComponent) = score(c)
            guard logLik < model.logLikelihoodThreshold else { continue }

            // Trust-region step toward the most responsible component.
            let target = model.means[bestComponent]
            let worldScale = worldShoulderWidth(timeline, i: i)
            var corrected = false
            for j in 0..<model.jointCount where measuredDim[j] && j < joints {
                var dx = (target[2 * j] - c[2 * j]) * config.pullWeight
                var dy = (target[2 * j + 1] - c[2 * j + 1]) * config.pullWeight
                let mag = (dx * dx + dy * dy).squareRoot()
                if mag > config.maxJointStep {
                    let k = config.maxJointStep / mag
                    dx *= k
                    dy *= k
                }
                guard abs(dx) > 1e-9 || abs(dy) > 1e-9 else { continue }
                // Back out of the canonical frame into image space.
                timeline.norm.x[j][i] += dx * scale
                timeline.norm.y[j][i] += dy * scale
                // Lockstep: the same canonical step, in metres.
                if let ws = worldScale,
                   timeline.world.x[j][i].isFinite, timeline.world.y[j][i].isFinite {
                    timeline.world.x[j][i] += dx * ws
                    timeline.world.y[j][i] += dy * ws
                }
                corrected = true
            }
            if corrected { qc.gmmCorrections += 1 }
        }
    }

    private func finitePair(_ a: Double, _ b: Double) -> Double? {
        guard a.isFinite, b.isFinite else { return nil }
        return (a + b) / 2
    }

    private func worldShoulderWidth(_ timeline: PoseTimeline, i: Int) -> Double? {
        let a = Landmarks.LEFT_SHOULDER, b = Landmarks.RIGHT_SHOULDER
        guard timeline.world.x[a][i].isFinite, timeline.world.x[b][i].isFinite else { return nil }
        let dx = timeline.world.x[a][i] - timeline.world.x[b][i]
        let dy = timeline.world.y[a][i] - timeline.world.y[b][i]
        let dz = (timeline.world.z[a][i].isFinite && timeline.world.z[b][i].isFinite)
            ? timeline.world.z[a][i] - timeline.world.z[b][i] : 0
        let w = (dx * dx + dy * dy + dz * dz).squareRoot()
        return w > 0.05 ? w : nil
    }

    /// Total log-likelihood under the mixture, and the index of the most
    /// responsible component (which for shared data is the component with
    /// the largest weighted density).
    private func score(_ x: [Double]) -> (logLikelihood: Double, bestComponent: Int) {
        var componentLogs = [Double](repeating: 0, count: model.weights.count)
        var best = 0
        for k in 0..<model.weights.count {
            var quad = 0.0
            let mean = model.means[k], varc = model.variances[k]
            for d in 0..<x.count {
                let r = x[d] - mean[d]
                quad += r * r / max(varc[d], 1e-12)
            }
            componentLogs[k] = logWeights[k] + logNormalizers[k] - 0.5 * quad
            if componentLogs[k] > componentLogs[best] { best = k }
        }
        // logsumexp for the total.
        let m = componentLogs[best]
        let total = m + Foundation.log(componentLogs.reduce(0) { $0 + exp($1 - m) })
        return (total, best)
    }
}

// MARK: - The corrector

public final class PosePriorCorrector {

    public struct Config {
        /// Bone-length projection: relative deviation past this triggers a
        /// projection, and the length moves this fraction of the way back to
        /// the clip median. A blend, not a snap, so a genuinely odd frame is
        /// nudged rather than redrawn.
        public var boneTolerance: Double = 0.10
        public var boneBlend: Double = 0.3
        /// Fold guard: an interior elbow or knee angle below this is not a
        /// human arm or leg, whatever the tracker says.
        public var foldMinAngleDeg: Double = 8
        public var foldBlend: Double = 0.3
        /// Fix 1: torso width and ratio constraints. World shoulder and hip
        /// widths past the tolerance are projected toward the clip median;
        /// in both spaces a shoulder to hip ratio past the tolerance is
        /// corrected. The brief's ten percent, the bone stage's blend.
        public var torsoWidthTolerance: Double = 0.10
        public var torsoRatioTolerance: Double = 0.10
        public var torsoBlend: Double = 0.6
        /// Fix 4 (extended): the ground plane stage's knobs.
        public var ground = GroundPlaneConfig()
        /// Fix S: the shoulder occlusion projection's knobs, medial
        /// collapse guard included.
        public var shoulder = ShoulderProjectionConfig()
        /// Fix G: the grip cluster anchor's knobs.
        public var gripCluster = GripClusterConfig()
        /// Kinematic wrist-to-palm distance guard (Video 1 impact fix).
        public var handCollapse = HandCollapseGuardConfig()
        public init() {}
    }

    /// The caller's config, untouched, so profiles always derive from the
    /// same base and never compound across runs.
    private let baseConfig: Config
    /// The config actually read by the stages: the base, tuned by the
    /// detected view's profile at the top of run().
    private var config: Config
    private let sides: Sides
    private let gmm: GMMPosePrior?

    /// The clip-level view the last run() classified, for logging and for
    /// any caller that wants to know which profile was applied. Nil until
    /// run() has executed once. Internal, matching SwingView's own access
    /// level.
    private(set) var detectedView: SwingView?

    /*
      The lead wrist's normalised track, aligned to the timeline grid, NaN
      where the wrist was never measured. Kept on the corrector so
      HandPathBuilder's wiring is unchanged. With both the midpoint magnet
      and grip fusion now gone, this is simply the corrected lead wrist: it
      is the measured wrist through every stage of the corrector, and no
      later step turns it into a fused grip, so what the trace draws and
      what the skeleton draws are the same point.
    */
    public private(set) var leadHandPathNormX: [Double] = []
    public private(set) var leadHandPathNormY: [Double] = []

    public init(config: Config = Config(), dominantHand: DominantHand, gmm: GMMPosePrior?) {
        self.baseConfig = config
        self.config = config
        self.sides = Landmarks.sides(dominantHand)
        self.gmm = gmm
    }

    /// The v1 analytic corrector the upload pipeline constructs. The GMM
    /// stage rides along automatically once a trained pose_gmm.json ships in
    /// the bundle, and costs nothing until then.
    public static func analytic(dominantHand: DominantHand) -> PosePriorCorrector {
        PosePriorCorrector(dominantHand: dominantHand, gmm: GMMPosePrior.loadFromBundle())
    }

    public func run(_ timeline: inout PoseTimeline, qc: inout TrackingQC) {
        guard timeline.frameCount > 2 else { return }

        // Route the view profile first (the research brief's "separate DTL
        // and face-on tracking"): the same stages run in both views, but
        // each view's known failure modes get its own thresholds. The
        // classification is clip-level and internal, so UploadProcessor's
        // wiring is unchanged.
        let view = SwingViewClassifier.classifyClip(timeline)
        detectedView = view
        config = Self.profiled(baseConfig, for: view)

        projectOccludedShoulders(&timeline, qc: &qc)    // Fix S rebuilt. FIRST,
                                                        // before the bones: the
                                                        // bone stage restores
                                                        // length by moving the
                                                        // DISTAL joint, so a
                                                        // collapsed shoulder
                                                        // used to drag the
                                                        // elbow, then the
                                                        // wrist, after it. The
                                                        // arm chain must hang
                                                        // from a correct root.
        enforceBiomechanicalRatios(&timeline, qc: &qc)  // Fix 1, after the reseat
                                                        // so symmetric scaling
                                                        // never splits a
                                                        // collapse error with
                                                        // the good shoulder
        projectBoneLengths(&timeline, qc: &qc)          // proximal to distal,
                                                        // from the corrected
                                                        // shoulders and hips
        relaxImpossibleFolds(&timeline, qc: &qc)
        applyGroundConstraints(&timeline, qc: &qc)      // Fix 4 extended, feet only
        anchorGripCluster(&timeline, qc: &qc)           // Fix G rebuilt, before
                                                        // the palm guard so the
                                                        // palm is restored
                                                        // against a wrist
                                                        // already back on the
                                                        // club
        enforceHandSeparation(&timeline, qc: &qc)       // Video 1 fix
        gmm?.run(&timeline, qc: &qc)                    // TASK 5, when a model ships
        enforceGroundBackstop(&timeline, qc: &qc)       // turf is not negotiable:
                                                        // nothing the later
                                                        // stages did may leave
                                                        // a foot underground

        // The hand path anchor: the corrected lead wrist. With grip fusion
        // removed there is no fusion step after this, so the wrist stays the
        // measured lead wrist all the way to the frames the pipeline emits;
        // this capture simply mirrors it onto the corrector for any caller
        // (the hand path builder) that reads the anchor rather than the
        // frame. Value-type arrays, so these are true copies.
        let leadWrist = sides.leadWrist
        if leadWrist < timeline.jointCount {
            leadHandPathNormX = timeline.norm.x[leadWrist]
            leadHandPathNormY = timeline.norm.y[leadWrist]
        } else {
            leadHandPathNormX = []
            leadHandPathNormY = []
        }
    }

    // MARK: - View profiles (DTL versus face-on)

    /*
      One pipeline, two tunings. Each camera angle has its own dominant
      failure: down the line it is the trail-side occlusions (the crossing
      wrist, the collapsing trail shoulder), so the DTL profile arms the
      wrist anchor and the collapse guard harder; face on the hands occlude
      each other around impact but the shoulders stay honest, so the
      face-on profile keeps the collapse guard conservative and the wrist
      anchor a touch looser, and never fights geometry it can trust. The
      knobs touched here are deliberately few: a profile is a bias, not a
      second pipeline, so a mis-classified clip degrades gracefully.
    */
    private static func profiled(_ base: Config, for view: SwingView) -> Config {
        var c = base
        switch view {
        case .downTheLine:
            // The crossing wrist detaches earlier and further here: fire
            // the anchor sooner and pull firmer.
            c.gripCluster.separationTriggerFactor = Swift.min(c.gripCluster.separationTriggerFactor, 1.2)
            c.gripCluster.blend = Swift.max(c.gripCluster.blend, 0.9)
            // The trail shoulder collapse lives in this view: convict on a
            // smaller world-width crush.
            c.shoulder.collapseWidthFraction = Swift.max(c.shoulder.collapseWidthFraction, 0.78)
            // Foot depth is at its noisiest with the feet pointing along
            // the optical axis; the flattening stays firmly on.
            c.ground.flattenFootDepth = true
        case .faceOn:
            // Shoulders are broadside and honest: demand a harder crush
            // before convicting, so a big honest turn is never touched.
            c.shoulder.collapseWidthFraction = Swift.min(c.shoulder.collapseWidthFraction, 0.68)
            // The hands overlap around impact but re-acquire fast; a
            // slightly looser trigger avoids fighting the natural stagger.
            c.gripCluster.separationTriggerFactor = Swift.max(c.gripCluster.separationTriggerFactor, 1.3)
        }
        return c
    }

    // MARK: - Ground backstop

    /*
      The penetration clamps alone, re-runnable and idempotent.

      Two callers, one reason. run() calls it as its own last step, so no
      stage inside the corrector (a fold relaxation, a GMM pull) can leave
      a foot underground. UploadProcessor SHOULD ALSO call it once more
      AFTER AdaptiveSmoothing: a zero-phase Butterworth is not a convex
      combination, and filtering the hard corner a clamp writes can
      undershoot a few millimetres past it, which is exactly the residual
      below-turf ankle the audits kept finding on an otherwise corrected
      clip. The stage is cheap (one pass over six joints), touches nothing
      above the tolerance, and counts what it clamps into the same QC
      fields as the main stage, so a clip where the backstop worked says
      so.
    */
    public func enforceGroundBackstop(_ timeline: inout PoseTimeline, qc: inout TrackingQC) {
        let c = config.ground
        guard c.enabled, timeline.frameCount > 8 else { return }

        var penetrations = 0
        var ankleAnchors = 0

        for space in [PoseSpace.norm, PoseSpace.world] {
            var bank = timeline.channels(space)
            guard let plane = estimateGroundPlane(bank, frameCount: timeline.frameCount, jointCount: timeline.jointCount) else { continue }
            let penetrationBar = c.penetrationToleranceShinFraction * plane.shin
            let minAnkleHeight = c.minAnkleHeightShinFraction * plane.shin

            let footSides: [(heel: Int, toe: Int, ankle: Int, level: Double, ankleLevel: Double?)] = [
                (Landmarks.LEFT_HEEL, Landmarks.LEFT_FOOT_INDEX, Landmarks.LEFT_ANKLE,
                 plane.leftLevel, plane.leftAnkleLevel),
                (Landmarks.RIGHT_HEEL, Landmarks.RIGHT_FOOT_INDEX, Landmarks.RIGHT_ANKLE,
                 plane.rightLevel, plane.rightAnkleLevel),
            ]

            for side in footSides {
                // The ankle's floor: its own measured level, never below
                // the turf plus the joint's real height above the sole.
                // A y at height h above the turf satisfies
                // (level - y) * up = h, so y = level - up * h.
                let ankleFloor: Double = {
                    let lifted = side.level - plane.up * minAnkleHeight
                    guard let own = side.ankleLevel else { return lifted }
                    let ownHeight = (side.level - own) * plane.up
                    return ownHeight >= minAnkleHeight ? own : lifted
                }()

                for i in 0..<timeline.frameCount {
                    for j in [side.heel, side.toe] {
                        guard bank.y[j][i].isFinite else { continue }
                        let h = (side.level - bank.y[j][i]) * plane.up
                        if h < -penetrationBar {
                            bank.y[j][i] = side.level
                            penetrations += 1
                        }
                    }
                    if bank.y[side.ankle][i].isFinite {
                        let h = (ankleFloor - bank.y[side.ankle][i]) * plane.up
                        if h < -penetrationBar {
                            bank.y[side.ankle][i] = ankleFloor
                            ankleAnchors += 1
                        }
                    }
                }
            }
            timeline.setChannels(space, bank)
        }

        qc.groundPenetrationsClamped += penetrations
        qc.ankleGroundAnchors += ankleAnchors
    }

    // MARK: - Bone-length projection

    /// Limb bones, proximal to distal, so a corrected elbow is already in
    /// place when the elbow-to-wrist bone is checked.
    private static let bones: [(a: Int, b: Int)] = [
        (Landmarks.LEFT_SHOULDER, Landmarks.LEFT_ELBOW),
        (Landmarks.LEFT_ELBOW, Landmarks.LEFT_WRIST),
        (Landmarks.RIGHT_SHOULDER, Landmarks.RIGHT_ELBOW),
        (Landmarks.RIGHT_ELBOW, Landmarks.RIGHT_WRIST),
        (Landmarks.LEFT_HIP, Landmarks.LEFT_KNEE),
        (Landmarks.LEFT_KNEE, Landmarks.LEFT_ANKLE),
        (Landmarks.RIGHT_HIP, Landmarks.RIGHT_KNEE),
        (Landmarks.RIGHT_KNEE, Landmarks.RIGHT_ANKLE),
    ]

    /*
      Bones do not change length mid swing; the tracker's do. Each limb
      bone's clip-median metric length is taken as this golfer's true length,
      and any frame whose bone deviates past tolerance has its DISTAL end
      slid along the measured bone direction toward that length. The
      direction was measured, only the length is corrected, and only
      partially. WORLD SPACE ONLY, on purpose: metric bone length is pose
      invariant, while image-space length legitimately collapses under
      foreshortening, so projecting the normalised set to a median image
      length would break every forearm that points at the camera. The two
      spaces cannot disagree about missingness because nothing here creates
      or removes samples.
    */
    private func projectBoneLengths(_ timeline: inout PoseTimeline, qc: inout TrackingQC) {
        var correctedFrames = Set<Int>()

        for bone in Self.bones {
            guard bone.b < timeline.jointCount else { continue }
            let n = timeline.frameCount

            func length(_ i: Int) -> Double? {
                let ax = timeline.world.x[bone.a][i], ay = timeline.world.y[bone.a][i]
                let bx = timeline.world.x[bone.b][i], by = timeline.world.y[bone.b][i]
                guard ax.isFinite, bx.isFinite else { return nil }
                let az = timeline.world.z[bone.a][i], bz = timeline.world.z[bone.b][i]
                let dz = (az.isFinite && bz.isFinite) ? az - bz : 0
                let dx = ax - bx, dy = ay - by
                let l = (dx * dx + dy * dy + dz * dz).squareRoot()
                return l > 1e-6 ? l : nil
            }

            var lengths: [Double] = []
            for i in 0..<n { if let l = length(i) { lengths.append(l) } }
            guard lengths.count > 8 else { continue }
            lengths.sort()
            let median = lengths[lengths.count / 2]
            guard median > 1e-6 else { continue }

            for i in 0..<n {
                guard let l = length(i), abs(l - median) / median > config.boneTolerance else { continue }
                let target = Geometry.lerp(l, median, config.boneBlend)
                let k = target / l
                let ax = timeline.world.x[bone.a][i], ay = timeline.world.y[bone.a][i]
                let az = timeline.world.z[bone.a][i]
                timeline.world.x[bone.b][i] = ax + (timeline.world.x[bone.b][i] - ax) * k
                timeline.world.y[bone.b][i] = ay + (timeline.world.y[bone.b][i] - ay) * k
                if az.isFinite, timeline.world.z[bone.b][i].isFinite {
                    timeline.world.z[bone.b][i] = az + (timeline.world.z[bone.b][i] - az) * k
                }
                correctedFrames.insert(i)
            }
        }
        qc.priorBoneCorrections += correctedFrames.count
    }

    // MARK: - Shoulder occlusion projection (Fix S, rebuilt)

    /*
      REBUILT by the skeleton overhaul. The previous stage detected and
      corrected in each space's IMAGE PLANE, with a rigid model (radius from
      the hip centre plus a fixed angular offset from the other shoulder)
      that its own comment admitted was "exact for in-plane rotation and
      approximate under foreshortening". A golf swing is out-of-plane
      rotation almost end to end relative to any single camera, so at the
      top and the finish, exactly where the trail shoulder collapses, the
      implied position was systematically wrong, and the ratio gate in
      front of it (see the config note on collapseRatioFraction) rarely
      fired there at all. The result on screen was the audited failure
      surviving every round: the shoulder snapped onto the neck while both
      the bar and the guard looked elsewhere.

      The rebuilt stage works from two quantities no rotation can change:

        WORLD SHOULDER WIDTH. |leftShoulder - rightShoulder| in metric 3D
        is a body constant. Its clip median is this golfer's true width;
        a frame far under it is a collapse at any phase, from any camera.

        WORLD SHOULDER RADIUS. |shoulder - hipCentre| in metric 3D is
        likewise (near) constant through a swing. Whichever side's radius
        has shrunk the most below its own clip median is the side that
        moved inward, which names the collapsed shoulder without reading
        a single visibility value.

      Correction is a rigid-body reseat in world 3D: the convicted (or
      occluded) shoulder is placed on the intersection of the two spheres
      those medians define (radius R about the hip centre, width W about
      the good shoulder), at the point on that circle NEAREST its measured
      position, so every scrap of honest signal in the measurement is
      kept and only the impossible part is corrected. The move is blended
      (soft for a mere occlusion, firm for a conviction), then mirrored
      into the normalised set scaled by this frame's own hip width in
      each space, so the drawn overlay and the 3D figure move together.
      The world z DOES move here, deliberately: both constraints are 3D
      facts, and it was precisely the depth error MediaPipe's inward
      guess carries that the old image-plane rule left standing.

      ORDER: this stage now runs FIRST in the corrector, before the bone
      projection. The bone stage slides each DISTAL joint along the
      measured direction to restore length, so running it against a
      collapsed shoulder used to drag the elbow in after the shoulder and
      the wrist in after the elbow: the "foreshortened stump" and the
      diagonal cross-link were manufactured downstream of the one bad
      joint. Reseating the shoulder first lets the whole arm chain hang
      from a correct root, which is the kinematic-chain-integrity form
      the research brief asks for.
    */
    private func projectOccludedShoulders(_ timeline: inout PoseTimeline, qc: inout TrackingQC) {
        let c = config.shoulder
        guard c.enabled, timeline.frameCount > 8 else { return }

        let ls = Landmarks.LEFT_SHOULDER, rs = Landmarks.RIGHT_SHOULDER
        let lh = Landmarks.LEFT_HIP, rh = Landmarks.RIGHT_HIP
        guard max(ls, rs, lh, rh) < timeline.jointCount else { return }

        let n = timeline.frameCount
        var correctedFrames = Set<Int>()
        var collapseFrames = Set<Int>()

        // Best-available per-sample visibility, norm preferred, the house
        // convention everywhere trust is read. NaN (the Vision backend)
        // reads as trusted, so the stage is inert there, the honest
        // behaviour.
        func vis(_ j: Int, _ i: Int) -> Double {
            let v = timeline.norm.visibility[j][i]
            if v.isFinite { return v }
            let w = timeline.world.visibility[j][i]
            return w.isFinite ? w : 1
        }

        // ---- World-space geometry helpers (3D, z folded in when finite) --

        func w3(_ j: Int, _ i: Int) -> Vec3? {
            let x = timeline.world.x[j][i], y = timeline.world.y[j][i]
            guard x.isFinite, y.isFinite else { return nil }
            let z = timeline.world.z[j][i]
            return Vec3(x: x, y: y, z: z.isFinite ? z : 0)
        }
        func dist3(_ a: Vec3, _ b: Vec3) -> Double {
            let dx = a.x - b.x, dy = a.y - b.y, dz = (a.z ?? 0) - (b.z ?? 0)
            return (dx * dx + dy * dy + dz * dz).squareRoot()
        }
        func hipCentreW(_ i: Int) -> Vec3? {
            guard let l = w3(lh, i), let r = w3(rh, i) else { return nil }
            return Vec3(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2, z: ((l.z ?? 0) + (r.z ?? 0)) / 2)
        }
        func normPlanarDist(_ a: Int, _ b: Int, _ i: Int) -> Double? {
            let ax = timeline.norm.x[a][i], ay = timeline.norm.y[a][i]
            let bx = timeline.norm.x[b][i], by = timeline.norm.y[b][i]
            guard ax.isFinite, bx.isFinite else { return nil }
            let d = ((ax - bx) * (ax - bx) + (ay - by) * (ay - by)).squareRoot()
            return d > 1e-9 ? d : nil
        }

        // ---- 1. Clip statistics from confident frames --------------------
        //
        // A collapsed frame with confident visibility does feed the pools,
        // and that is tolerated on purpose: collapses cluster in the top
        // and finish windows, medians shrug off a minority, and excluding
        // them would need the very statistics being learned.

        var widthsW: [Double] = []
        var radiiL: [Double] = []
        var radiiR: [Double] = []
        var widthsNorm: [Double] = []
        for i in 0..<n {
            let anchored = vis(lh, i) >= c.anchorMinVisibility && vis(rh, i) >= c.anchorMinVisibility
            guard anchored else { continue }
            if vis(ls, i) >= c.anchorMinVisibility, vis(rs, i) >= c.anchorMinVisibility {
                if let a = w3(ls, i), let b = w3(rs, i) {
                    let w = dist3(a, b)
                    if w > 1e-6 { widthsW.append(w) }
                }
                if let d = normPlanarDist(ls, rs, i) { widthsNorm.append(d) }
            }
            if let h = hipCentreW(i) {
                if vis(ls, i) >= c.anchorMinVisibility, let a = w3(ls, i) {
                    let r = dist3(a, h)
                    if r > 1e-6 { radiiL.append(r) }
                }
                if vis(rs, i) >= c.anchorMinVisibility, let b = w3(rs, i) {
                    let r = dist3(b, h)
                    if r > 1e-6 { radiiR.append(r) }
                }
            }
        }

        func median(_ values: inout [Double]) -> Double? {
            guard values.count > 8 else { return nil }
            values.sort()
            return values[values.count / 2]
        }
        guard let widthMedian = median(&widthsW),
              let radiusLeft = median(&radiiL),
              let radiusRight = median(&radiiR) else { return }
        let normWidthMedian = median(&widthsNorm)
        func radius(_ shoulder: Int) -> Double { shoulder == ls ? radiusLeft : radiusRight }

        // ---- 1b. Conviction: pose-invariant collapse detection -----------

        var convicted = [Int?](repeating: nil, count: n)
        if c.collapseGuardEnabled {
            for i in 0..<n {
                guard vis(lh, i) >= c.anchorMinVisibility,
                      vis(rh, i) >= c.anchorMinVisibility,
                      let h = hipCentreW(i),
                      let l = w3(ls, i), let r = w3(rs, i) else { continue }

                // The world width crush, the primary test, and the norm
                // neck-proximity emergency test. Either convicts the frame.
                let worldWidth = dist3(l, r)
                var frameCollapsed = worldWidth > 1e-9 && worldWidth < c.collapseWidthFraction * widthMedian
                if !frameCollapsed, let nm = normWidthMedian,
                   let planar = normPlanarDist(ls, rs, i),
                   planar < c.neckProximityWidthFraction * nm {
                    frameCollapsed = true
                }
                guard frameCollapsed else { continue }

                // Blame: the side whose 3D radius from the hip centre has
                // shrunk the most below its own clip median. The collapsed
                // shoulder moved inward, so its radius deficit names it
                // without reading any visibility, which is the point: the
                // tracker reports these frames CONFIDENT.
                let deficitL = (radiusLeft - dist3(l, h)) / radiusLeft
                let deficitR = (radiusRight - dist3(r, h)) / radiusRight
                let floorBar = c.collapseMinErrorRadiusFraction
                if deficitL > floorBar, deficitL >= c.collapseErrorDominance * Swift.max(deficitR, 0) {
                    convicted[i] = ls
                } else if deficitR > floorBar, deficitR >= c.collapseErrorDominance * Swift.max(deficitL, 0) {
                    convicted[i] = rs
                }
                // Neither side dominant: a genuinely bad frame convicts
                // nobody; the torso ratio stage and the smoothing own it.
            }
        }

        // ---- 2. The rigid-body reseat ------------------------------------
        //
        // Place the target on the intersection of the sphere of radius R
        // about the hip centre and the sphere of radius W about the good
        // shoulder, at the point nearest the measured position. When the
        // spheres cannot meet (degraded data), alternate projections onto
        // the two constraints, which lands on the nearest feasible
        // compromise. Everything in world units, mirrored into norm below.

        func reseatTarget(bad: Vec3, good: Vec3, hip: Vec3, r: Double, w: Double) -> Vec3 {
            let nx = good.x - hip.x, ny = good.y - hip.y, nz = (good.z ?? 0) - (hip.z ?? 0)
            let d = (nx * nx + ny * ny + nz * nz).squareRoot()

            if d > 1e-6, d < r + w, d > Swift.abs(r - w) {
                // Exact sphere-sphere circle.
                let ux = nx / d, uy = ny / d, uz = nz / d
                let a = (d * d + r * r - w * w) / (2 * d)
                let rc = Swift.max(r * r - a * a, 0).squareRoot()
                let cx = hip.x + ux * a, cy = hip.y + uy * a, cz = (hip.z ?? 0) + uz * a
                var px = bad.x - cx, py = bad.y - cy, pz = (bad.z ?? 0) - cz
                let along = px * ux + py * uy + pz * uz
                px -= along * ux; py -= along * uy; pz -= along * uz
                var pl = (px * px + py * py + pz * pz).squareRoot()
                if pl < 1e-9 {
                    // Measured point sits on the axis: pick a stable
                    // perpendicular (cross with world up, then fallback).
                    px = uy * 0 - uz * 1; py = uz * 0 - ux * 0; pz = ux * 1 - uy * 0
                    pl = (px * px + py * py + pz * pz).squareRoot()
                    if pl < 1e-9 { px = 0; py = 0; pz = 1; pl = 1 }
                }
                return Vec3(x: cx + px / pl * rc, y: cy + py / pl * rc, z: cz + pz / pl * rc)
            }

            // Alternating projections fallback: width first (the collapse
            // signature), radius second, width again. From a shoulder
            // collapsed onto the neck, the measured direction good -> bad
            // points across the neck toward the true side, so extending it
            // to the true width already lands close.
            var t = bad
            for pass in 0..<3 {
                let anchor = pass == 1 ? hip : good
                let target = pass == 1 ? r : w
                var dx = t.x - anchor.x, dy = t.y - anchor.y, dz = (t.z ?? 0) - (anchor.z ?? 0)
                var l = (dx * dx + dy * dy + dz * dz).squareRoot()
                if l < 1e-9 { dx = 0; dy = 0; dz = 1; l = 1 }
                t = Vec3(
                    x: anchor.x + dx / l * target,
                    y: anchor.y + dy / l * target,
                    z: (anchor.z ?? 0) + dz / l * target
                )
            }
            return t
        }

        for (occl, anchor) in [(ls, rs), (rs, ls)] {
            for i in 0..<n {
                let convictedHere = convicted[i] == occl
                guard vis(occl, i) < c.occludedBelow || convictedHere,
                      // A convicted anchor cannot vouch for the other side
                      // this frame, whatever its visibility says.
                      convicted[i] != anchor,
                      vis(anchor, i) >= c.anchorMinVisibility,
                      vis(lh, i) >= c.anchorMinVisibility,
                      vis(rh, i) >= c.anchorMinVisibility,
                      let bad = w3(occl, i), let good = w3(anchor, i),
                      let hip = hipCentreW(i) else { continue }

                let target = reseatTarget(
                    bad: bad, good: good, hip: hip,
                    r: radius(occl), w: widthMedian
                )
                let blend = convictedHere ? Swift.max(c.blend, c.collapseBlend) : c.blend
                let dx = blend * (target.x - bad.x)
                let dy = blend * (target.y - bad.y)
                let dz = blend * ((target.z ?? 0) - (bad.z ?? 0))

                timeline.world.x[occl][i] += dx
                timeline.world.y[occl][i] += dy
                if timeline.world.z[occl][i].isFinite {
                    timeline.world.z[occl][i] += dz
                }

                // Mirror the planar part of the move into the normalised
                // set, scaled by this frame's own hip width in each space,
                // the same per-frame scale bridge the GMM stage uses, so
                // the overlay and the 3D figure keep moving together. The
                // norm z is left alone: it is a camera-relative estimate
                // the reseat has no business inventing.
                if timeline.norm.x[occl][i].isFinite,
                   let hwWorld = { () -> Double? in
                       guard let a = w3(lh, i), let b = w3(rh, i) else { return nil }
                       let d = dist3(a, b)
                       return d > 1e-6 ? d : nil
                   }(),
                   let hwNorm = normPlanarDist(lh, rh, i) {
                    let s = hwNorm / hwWorld
                    timeline.norm.x[occl][i] += dx * s
                    timeline.norm.y[occl][i] += dy * s
                }

                correctedFrames.insert(i)
                if convictedHere { collapseFrames.insert(i) }
            }
        }

        qc.shoulderProjectionFrames += correctedFrames.count
        qc.shoulderCollapseFrames += collapseFrames.count
    }

    // MARK: - Torso width and ratio constraints (Fix 1)

    /*
      Shoulder width (11 to 12) and hip width (23 to 24) are body constants
      the raw tracker does not honour, and down the line the depth channel's
      noise makes them drift visibly through the rotation. Two rules:

      WORLD WIDTHS toward the median. Metric widths are pose invariant, the
      same argument the limb bone projection makes, so any frame whose world
      shoulder or hip width deviates past tolerance is scaled back toward the
      clip median. The scaling is SYMMETRIC about the segment midpoint, which
      is the difference from the limb projection: a limb bone has a proximal
      anchor and a distal end to move, but shoulders and hips have neither,
      and moving one side only would shove the whole torso sideways. The
      midpoint (the body centre line) stays exactly where it was measured.

      THE RATIO in both spaces. Image-space widths legitimately collapse
      under foreshortening, so an absolute norm-space width constraint would
      fight every real rotation, the same trap the bone projection's header
      warns about. But when the torso rotates, BOTH projected widths shrink
      together and their ratio survives; when the tracker glitches, one
      width collapses and the other does not, and the ratio spikes. So the
      ratio is the criterion that sees the glitch and ignores the rotation.
      A frame past tolerance is corrected toward the median ratio while
      PRESERVING the product of the two widths, so the frame's overall
      foreshortening level is kept and only the disagreement between the
      two widths is repaired:

          s' = sqrt(s * h * R_median)      h' = sqrt(s * h / R_median)

      then blended partially, the house style: nudged, not redrawn.
    */
    private func enforceBiomechanicalRatios(_ timeline: inout PoseTimeline, qc: inout TrackingQC) {
        let ls = Landmarks.LEFT_SHOULDER, rs = Landmarks.RIGHT_SHOULDER
        let lh = Landmarks.LEFT_HIP, rh = Landmarks.RIGHT_HIP
        guard max(ls, rs, lh, rh) < timeline.jointCount else { return }
        let n = timeline.frameCount

        func width(_ bank: PoseTimeline.Channels, _ a: Int, _ b: Int, _ i: Int, threeD: Bool) -> Double? {
            guard bank.x[a][i].isFinite, bank.y[a][i].isFinite,
                  bank.x[b][i].isFinite, bank.y[b][i].isFinite else { return nil }
            let dx = bank.x[a][i] - bank.x[b][i]
            let dy = bank.y[a][i] - bank.y[b][i]
            var d2 = dx * dx + dy * dy
            if threeD, bank.z[a][i].isFinite, bank.z[b][i].isFinite {
                let dz = bank.z[a][i] - bank.z[b][i]
                d2 += dz * dz
            }
            let w = d2.squareRoot()
            return w > 1e-6 ? w : nil
        }

        /// Scale the segment (a, b) about its midpoint by k, in this bank.
        /// Depth participates only when both ends carry it, so a 2D space
        /// stays 2D, the hand collapse guard's rule.
        func scaleAboutMidpoint(
            _ bank: inout PoseTimeline.Channels, _ a: Int, _ b: Int, _ i: Int, k: Double, threeD: Bool
        ) {
            let mx = (bank.x[a][i] + bank.x[b][i]) / 2
            let my = (bank.y[a][i] + bank.y[b][i]) / 2
            for j in [a, b] {
                bank.x[j][i] = mx + (bank.x[j][i] - mx) * k
                bank.y[j][i] = my + (bank.y[j][i] - my) * k
            }
            if threeD, bank.z[a][i].isFinite, bank.z[b][i].isFinite {
                let mz = (bank.z[a][i] + bank.z[b][i]) / 2
                for j in [a, b] {
                    bank.z[j][i] = mz + (bank.z[j][i] - mz) * k
                }
            }
        }

        func median(_ values: [Double]) -> Double? {
            guard values.count > 8 else { return nil }
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }

        // Rule 1: world widths toward their own clip medians.
        var widthFrames = Set<Int>()
        var worldBank = timeline.channels(.world)
        for pair in [(ls, rs), (lh, rh)] {
            var widths: [Double] = []
            for i in 0..<n { if let w = width(worldBank, pair.0, pair.1, i, threeD: true) { widths.append(w) } }
            guard let med = median(widths), med > 1e-6 else { continue }
            for i in 0..<n {
                guard let w = width(worldBank, pair.0, pair.1, i, threeD: true),
                      abs(w - med) / med > config.torsoWidthTolerance else { continue }
                let target = Geometry.lerp(w, med, config.torsoBlend)
                scaleAboutMidpoint(&worldBank, pair.0, pair.1, i, k: target / w, threeD: true)
                widthFrames.insert(i)
            }
        }
        timeline.setChannels(.world, worldBank)
        qc.torsoWidthCorrections += widthFrames.count

        // Rule 2: the ratio, each space with its own geometry and median.
        // World is 3D here and norm is 2D, matching how each space defines
        // a width everywhere else in this file.
        var ratioFrames = Set<Int>()
        for space in [PoseSpace.norm, PoseSpace.world] {
            let threeD = space == .world
            var bank = timeline.channels(space)

            var ratios: [Double] = []
            for i in 0..<n {
                guard let s = width(bank, ls, rs, i, threeD: threeD),
                      let h = width(bank, lh, rh, i, threeD: threeD) else { continue }
                ratios.append(s / h)
            }
            guard let medRatio = median(ratios), medRatio > 1e-6 else { continue }

            for i in 0..<n {
                guard let s = width(bank, ls, rs, i, threeD: threeD),
                      let h = width(bank, lh, rh, i, threeD: threeD) else { continue }
                let ratio = s / h
                guard abs(ratio - medRatio) / medRatio > config.torsoRatioTolerance else { continue }

                // Product-preserving targets, then the partial blend.
                let product = s * h
                let idealS = (product * medRatio).squareRoot()
                let idealH = (product / medRatio).squareRoot()
                let targetS = Geometry.lerp(s, idealS, config.torsoBlend)
                let targetH = Geometry.lerp(h, idealH, config.torsoBlend)
                scaleAboutMidpoint(&bank, ls, rs, i, k: targetS / s, threeD: threeD)
                scaleAboutMidpoint(&bank, lh, rh, i, k: targetH / h, threeD: threeD)
                ratioFrames.insert(i)
            }
            timeline.setChannels(space, bank)
        }
        qc.torsoRatioCorrections += ratioFrames.count
    }

    // MARK: - Ground plane (Fix 4)

    /// The turf, one estimate per side per space. Levels are y values in
    /// that space; up is +1 when height above ground grows with y and -1
    /// when it grows against y (image space, where up is smaller y).
    struct GroundPlaneEstimate {
        var leftLevel: Double
        var rightLevel: Double
        /// Multiply (level - y) by this to get height above the plane.
        var up: Double
        /// The clip-median shin length in this space's units, the yardstick
        /// every threshold scales from.
        var shin: Double
        /// The ankle's own resting level per side (occlusion overhaul): the
        /// toward-ground percentile of that ankle's y across the clip, the
        /// same robust estimate the turf uses. Nil when the ankle never
        /// produced enough samples, in which case the anchor does not run
        /// on that side and the turf clamp alone protects it.
        var leftAnkleLevel: Double?
        var rightAnkleLevel: Double?
    }

    /*
      Estimate the plane for one space from the clip's own feet. Returns nil
      when the clip never produced enough foot samples to trust, in which
      case the constraint stage simply does not run, the honest fallback.
    */
    func estimateGroundPlane(_ bank: PoseTimeline.Channels, frameCount: Int, jointCount: Int) -> GroundPlaneEstimate? {
        let feet: [(heel: Int, toe: Int, ankle: Int, knee: Int, hip: Int)] = [
            (Landmarks.LEFT_HEEL, Landmarks.LEFT_FOOT_INDEX, Landmarks.LEFT_ANKLE, Landmarks.LEFT_KNEE, Landmarks.LEFT_HIP),
            (Landmarks.RIGHT_HEEL, Landmarks.RIGHT_FOOT_INDEX, Landmarks.RIGHT_ANKLE, Landmarks.RIGHT_KNEE, Landmarks.RIGHT_HIP),
        ]
        guard feet.allSatisfy({ max($0.heel, $0.toe, $0.ankle, $0.knee, $0.hip) < jointCount }) else { return nil }

        func finite(_ j: Int, _ i: Int) -> Bool { bank.x[j][i].isFinite && bank.y[j][i].isFinite }

        // The shin yardstick and the hip reference, pooled over both sides.
        var shins: [Double] = []
        var hipYs: [Double] = []
        var footYsPooled: [Double] = []
        for side in feet {
            for i in 0..<frameCount {
                if finite(side.knee, i), finite(side.ankle, i) {
                    let dx = bank.x[side.knee][i] - bank.x[side.ankle][i]
                    let dy = bank.y[side.knee][i] - bank.y[side.ankle][i]
                    let l = (dx * dx + dy * dy).squareRoot()
                    if l > 1e-6 { shins.append(l) }
                }
                if finite(side.hip, i) { hipYs.append(bank.y[side.hip][i]) }
                if finite(side.heel, i) { footYsPooled.append(bank.y[side.heel][i]) }
            }
        }
        guard shins.count > 8, hipYs.count > 8, footYsPooled.count > 8 else { return nil }
        shins.sort(); hipYs.sort(); footYsPooled.sort()
        let shin = shins[shins.count / 2]
        let hipMedianY = hipYs[hipYs.count / 2]
        let footMedianY = footYsPooled[footYsPooled.count / 2]
        guard shin > 1e-6, abs(hipMedianY - footMedianY) > 1e-6 else { return nil }

        // Which way is up: the hips sit above the feet, whatever the axis
        // convention. up is defined so that (level - y) * up is the height
        // of y ABOVE the plane, positive above, negative sunk below.
        //
        // THE SIGN BUG THIS LINE USED TO CARRY, recorded so it can never
        // come back: the previous form returned -1 in image space (hips at
        // smaller y) and +1 in a y-up world, which made heightAbove come
        // out NEGATIVE for points above the plane in BOTH spaces under
        // BOTH conventions. Every rule downstream then ran inverted: the
        // penetration clamp fired on lifted heels and pressed them onto
        // the turf, genuine penetrations were never clamped at all, the
        // ankle anchor pinned the ankle from above while ignoring the
        // sink, and the heel lift counter counted penetrations. The QC
        // numbers looked plausible throughout, which is how the inversion
        // survived four rounds of features being stacked on top of it.
        //
        // Derivation check, both conventions: image space has hips at
        // SMALLER y and ground at larger y, so height above ground grows
        // with (level - y) and up must be +1 there; a y-up world has hips
        // at LARGER y and ground at smaller y, so height above ground
        // grows with (y - level) and up must be -1.
        let up: Double = hipMedianY < footMedianY ? 1 : -1

        // Per side turf level: the toward-ground 75th percentile of that
        // foot's pooled heel and toe y. Lifted-heel frames sit on the
        // away-from-ground side of the distribution and cannot raise it;
        // the last quartile absorbs the occasional below-turf outlier.
        func level(_ side: (heel: Int, toe: Int, ankle: Int, knee: Int, hip: Int)) -> Double? {
            var ys: [Double] = []
            for i in 0..<frameCount {
                if finite(side.heel, i) { ys.append(bank.y[side.heel][i]) }
                if finite(side.toe, i) { ys.append(bank.y[side.toe][i]) }
            }
            guard ys.count > 8 else { return nil }
            // Sort so that the ground end comes last, then take the 75th
            // percentile toward it.
            // Toward-ground end last, under the corrected up sign: with
            // up = +1 (image-like, ground at large y) ascending puts the
            // ground end last; with up = -1 (y-up world) descending does.
            ys.sort { up > 0 ? $0 < $1 : $0 > $1 }
            return ys[min(ys.count - 1, (ys.count * 3) / 4)]
        }
        guard let left = level(feet[0]), let right = level(feet[1]) else { return nil }

        // The ankle's own resting level, same robust construction as the
        // turf: toward-ground 75th percentile of that ankle's y. Planted
        // frames dominate the toward-ground end; lifted frames sit on the
        // far side and cannot pull the level up; the last quartile absorbs
        // the occasional sunk outlier this whole extension exists to stop.
        func ankleLevel(_ side: (heel: Int, toe: Int, ankle: Int, knee: Int, hip: Int)) -> Double? {
            var ys: [Double] = []
            for i in 0..<frameCount where finite(side.ankle, i) {
                ys.append(bank.y[side.ankle][i])
            }
            guard ys.count > 8 else { return nil }
            // Toward-ground end last, under the corrected up sign: with
            // up = +1 (image-like, ground at large y) ascending puts the
            // ground end last; with up = -1 (y-up world) descending does.
            ys.sort { up > 0 ? $0 < $1 : $0 > $1 }
            return ys[min(ys.count - 1, (ys.count * 3) / 4)]
        }

        return GroundPlaneEstimate(
            leftLevel: left, rightLevel: right, up: up, shin: shin,
            leftAnkleLevel: ankleLevel(feet[0]), rightAnkleLevel: ankleLevel(feet[1])
        )
    }

    /*
      Apply the three rules from the GroundPlaneConfig note, per space with
      that space's own estimate and units, feet only, everything counted.
      Runs after the fold relaxation and before the hand stages because feet
      share no geometry with hands and the folds should see measured ankles.
    */
    private func applyGroundConstraints(_ timeline: inout PoseTimeline, qc: inout TrackingQC) {
        let c = config.ground
        guard c.enabled, timeline.frameCount > 8 else { return }

        let leadIsLeft = sides.leadWrist == Landmarks.LEFT_WRIST
        var snaps = 0
        var penetrations = 0
        var ankleAnchors = 0
        var liftLead = Set<Int>()
        var liftTrail = Set<Int>()
        var flattenedDepth = false

        for space in [PoseSpace.norm, PoseSpace.world] {
            var bank = timeline.channels(space)

            // Occlusion overhaul, depth flattening FIRST: MediaPipe's foot
            // depth is not a measurement worth keeping, so every foot
            // joint's z becomes its own clip median before any rule runs.
            // Never-measured samples stay NaN; a constant is written only
            // where a (noisy) value was, so the two spaces cannot disagree
            // about missingness. See the config note for why the median
            // and not the brief's literal zero.
            if c.flattenFootDepth {
                let sidesJoints: [(heel: Int, toe: Int, ankle: Int)] = [
                    (Landmarks.LEFT_HEEL, Landmarks.LEFT_FOOT_INDEX, Landmarks.LEFT_ANKLE),
                    (Landmarks.RIGHT_HEEL, Landmarks.RIGHT_FOOT_INDEX, Landmarks.RIGHT_ANKLE),
                ]
                for sj in sidesJoints where max(sj.heel, sj.toe, sj.ankle) < timeline.jointCount {

                    func medianOf(_ values: [Double]) -> Double? {
                        guard values.count > 8 else { return nil }
                        let s = values.sorted()
                        return s[s.count / 2]
                    }

                    // Pre-flatten shape statistics for the restore below:
                    // the clip-median 3D heel to toe length, and the
                    // median depth offsets of heel and toe from the ankle
                    // (signs included, they carry which way the foot
                    // points in this space).
                    var lengths3: [Double] = []
                    var heelOffsets: [Double] = []
                    var toeOffsets: [Double] = []
                    for i in 0..<timeline.frameCount {
                        let hx = bank.x[sj.heel][i], hy = bank.y[sj.heel][i], hz = bank.z[sj.heel][i]
                        let tx = bank.x[sj.toe][i], ty = bank.y[sj.toe][i], tz = bank.z[sj.toe][i]
                        let az = bank.z[sj.ankle][i]
                        if hx.isFinite, tx.isFinite, hz.isFinite, tz.isFinite {
                            let dx = hx - tx, dy = hy - ty, dz = hz - tz
                            let l = (dx * dx + dy * dy + dz * dz).squareRoot()
                            if l > 1e-9 { lengths3.append(l) }
                        }
                        if hz.isFinite, az.isFinite { heelOffsets.append(hz - az) }
                        if tz.isFinite, az.isFinite { toeOffsets.append(tz - az) }
                    }

                    // The flattening itself, unchanged: each joint's depth
                    // becomes its own clip median, written only where a
                    // (noisy) value was, so missingness cannot drift.
                    var flattenedZ: [Int: Double] = [:]
                    for j in [sj.heel, sj.toe, sj.ankle] {
                        var zs: [Double] = []
                        for i in 0..<timeline.frameCount where bank.z[j][i].isFinite {
                            zs.append(bank.z[j][i])
                        }
                        guard let medianZ = medianOf(zs) else { continue }
                        for i in 0..<timeline.frameCount where bank.z[j][i].isFinite {
                            bank.z[j][i] = medianZ
                        }
                        flattenedZ[j] = medianZ
                        flattenedDepth = true
                    }

                    // The rigid restore (world space, where the 3D figure
                    // reads its depth). Independent per-joint medians of a
                    // noisy channel can land nearly on top of each other,
                    // and down the line the planar heel to toe separation
                    // is small too, so the flattened foot can degenerate
                    // into three near-coincident columns: the audits'
                    // "three vertical joints". When the flattened foot's
                    // median 3D length has collapsed well under the length
                    // the clip actually measured, the two constant depths
                    // are spread back apart about the ankle's, keeping
                    // their measured signs and proportion. Depth stays a
                    // constant per joint, so none of the noise the
                    // flattening removed can return.
                    if space == .world, c.restoreFootLengthAfterFlatten,
                       let zh = flattenedZ[sj.heel], let zt = flattenedZ[sj.toe], let za = flattenedZ[sj.ankle],
                       let trueLength = medianOf(lengths3),
                       let oh = medianOf(heelOffsets), let ot = medianOf(toeOffsets) {
                        var planars: [Double] = []
                        for i in 0..<timeline.frameCount {
                            let hx = bank.x[sj.heel][i], hy = bank.y[sj.heel][i]
                            let tx = bank.x[sj.toe][i], ty = bank.y[sj.toe][i]
                            guard hx.isFinite, tx.isFinite else { continue }
                            planars.append(((hx - tx) * (hx - tx) + (hy - ty) * (hy - ty)).squareRoot())
                        }
                        if let planarMedian = medianOf(planars) {
                            let currentDepth = zh - zt
                            let current3 = (planarMedian * planarMedian + currentDepth * currentDepth).squareRoot()
                            let separation = oh - ot
                            if current3 < 0.6 * trueLength, abs(separation) > 1e-6 {
                                let neededDepth = Swift.max(trueLength * trueLength - planarMedian * planarMedian, 0).squareRoot()
                                let k = neededDepth / abs(separation)
                                let newZh = za + oh * k
                                let newZt = za + ot * k
                                for i in 0..<timeline.frameCount {
                                    if bank.z[sj.heel][i].isFinite { bank.z[sj.heel][i] = newZh }
                                    if bank.z[sj.toe][i].isFinite { bank.z[sj.toe][i] = newZt }
                                }
                            }
                        }
                    }
                }
            }

            guard let plane = estimateGroundPlane(bank, frameCount: timeline.frameCount, jointCount: timeline.jointCount) else {
                timeline.setChannels(space, bank)
                continue
            }

            let snapZone = c.snapZoneShinFraction * plane.shin
            let ankleZone = c.ankleSnapZoneShinFraction * plane.shin
            let liftBar = c.liftThresholdShinFraction * plane.shin
            let penetrationBar = c.penetrationToleranceShinFraction * plane.shin

            let footSides: [(heel: Int, toe: Int, ankle: Int, level: Double, ankleLevel: Double?, isLeft: Bool)] = [
                (Landmarks.LEFT_HEEL, Landmarks.LEFT_FOOT_INDEX, Landmarks.LEFT_ANKLE,
                 plane.leftLevel, plane.leftAnkleLevel, true),
                (Landmarks.RIGHT_HEEL, Landmarks.RIGHT_FOOT_INDEX, Landmarks.RIGHT_ANKLE,
                 plane.rightLevel, plane.rightAnkleLevel, false),
            ]

            for side in footSides {
                let anchoredAnkle: Double? = {
                    guard c.ankleAnchorEnabled else { return nil }
                    // The floored form of the degenerate guard. An ankle
                    // level that landed at or below turf plus the joint's
                    // minimum anatomical height is noise stacked on noise,
                    // but the OLD answer (return nil, hand the ankle to
                    // the bare turf clamp) let the clamp legally park the
                    // ankle ON the ground, a flattened foot by
                    // construction. The anchor now always runs, at the
                    // measured level when that level is anatomically
                    // possible and at turf plus the minimum height when
                    // it is not. y at height h above turf: level - up * h.
                    let minHeight = c.minAnkleHeightShinFraction * plane.shin
                    let lifted = side.level - plane.up * minHeight
                    guard let level = side.ankleLevel else { return lifted }
                    let heightAboveTurf = (side.level - level) * plane.up
                    return heightAboveTurf >= minHeight ? level : lifted
                }()

                for i in 0..<timeline.frameCount {
                    func heightAbove(_ j: Int, level: Double) -> Double? {
                        guard bank.y[j][i].isFinite else { return nil }
                        return (level - bank.y[j][i]) * plane.up
                    }

                    // Rule 1: nothing sinks below the turf. Heel and toe
                    // always; the ankle too when its own anchor is not
                    // running (rule 1b then owns it, with a stricter
                    // level). Only a penetration past the tolerance is
                    // clamped, so plane noise does not flatten a foot that
                    // is really planted.
                    var rule1Joints = [side.heel, side.toe]
                    if anchoredAnkle == nil { rule1Joints.append(side.ankle) }
                    for j in rule1Joints {
                        guard let h = heightAbove(j, level: side.level), h < -penetrationBar else { continue }
                        bank.y[j][i] = side.level
                        penetrations += 1
                    }

                    // Rule 1b (occlusion overhaul): the ankle anchor. The
                    // ankle is held near ITS OWN resting level, which sits
                    // above the turf by the joint's real height. Below the
                    // level past tolerance clamps up (this is the sinking
                    // ankle, caught before it reaches the turf); within
                    // the zone either side blends on (kills the hover and
                    // the jitter); clearly above is a lift and untouched.
                    if let level = anchoredAnkle,
                       let h = heightAbove(side.ankle, level: level) {
                        if h < -penetrationBar {
                            bank.y[side.ankle][i] = level
                            ankleAnchors += 1
                        } else if abs(h) <= ankleZone {
                            bank.y[side.ankle][i] = Geometry.lerp(bank.y[side.ankle][i], level, c.ankleSnapBlend)
                            ankleAnchors += 1
                        }
                    }

                    // Rule 2: anchor near-plane heels and toes. Ankles are
                    // exempt here: their anchor is rule 1b, at their own
                    // level, never the turf.
                    for j in [side.heel, side.toe] {
                        guard let h = heightAbove(j, level: side.level), h > 0, h <= snapZone else { continue }
                        bank.y[j][i] = Geometry.lerp(bank.y[j][i], side.level, c.snapBlend)
                        snaps += 1
                    }

                    // Rule 3: a clearly lifted heel is a real event. Count
                    // it, per lead and trail, and touch nothing. Counted
                    // once per frame across spaces via the sets.
                    if let h = heightAbove(side.heel, level: side.level), h > liftBar {
                        if side.isLeft == leadIsLeft { liftLead.insert(i) } else { liftTrail.insert(i) }
                    }
                }
            }
            timeline.setChannels(space, bank)
        }

        qc.groundPlaneSnaps += snaps
        qc.groundPenetrationsClamped += penetrations
        qc.ankleGroundAnchors += ankleAnchors
        qc.heelLiftFramesLead += liftLead.count
        qc.heelLiftFramesTrail += liftTrail.count
        if flattenedDepth { qc.footDepthFlattened = true }
    }

    // MARK: - Impossible folds

    private static let hingeJoints: [(a: Int, mid: Int, b: Int)] = [
        (Landmarks.LEFT_SHOULDER, Landmarks.LEFT_ELBOW, Landmarks.LEFT_WRIST),
        (Landmarks.RIGHT_SHOULDER, Landmarks.RIGHT_ELBOW, Landmarks.RIGHT_WRIST),
        (Landmarks.LEFT_HIP, Landmarks.LEFT_KNEE, Landmarks.LEFT_ANKLE),
        (Landmarks.RIGHT_HIP, Landmarks.RIGHT_KNEE, Landmarks.RIGHT_ANKLE),
    ]

    /*
      No elbow or knee closes past a few degrees. A frame where the tracker
      says one did is a distal joint sitting on the wrong side of its hinge,
      and the honest fix is to relax that joint toward its own trajectory,
      the mean of its temporal neighbours, rather than toward any template.
    */
    private func relaxImpossibleFolds(_ timeline: inout PoseTimeline, qc: inout TrackingQC) {
        var correctedFrames = Set<Int>()
        let n = timeline.frameCount

        for hinge in Self.hingeJoints {
            guard hinge.b < timeline.jointCount else { continue }

            func vec(_ j: Int, _ i: Int) -> Vec3? {
                guard timeline.world.x[j][i].isFinite, timeline.world.y[j][i].isFinite else { return nil }
                let z = timeline.world.z[j][i]
                return Vec3(x: timeline.world.x[j][i], y: timeline.world.y[j][i], z: z.isFinite ? z : nil)
            }

            for i in 1..<(n - 1) {
                guard let a = vec(hinge.a, i), let m = vec(hinge.mid, i), let b = vec(hinge.b, i) else { continue }
                let angle = Geometry.jointAngle(a, m, b)
                guard angle < config.foldMinAngleDeg else { continue }
                guard let prev = vec(hinge.b, i - 1), let next = vec(hinge.b, i + 1) else { continue }
                let target = Geometry.v.mid(prev, next)
                timeline.world.x[hinge.b][i] = Geometry.lerp(b.x, target.x, config.foldBlend)
                timeline.world.y[hinge.b][i] = Geometry.lerp(b.y, target.y, config.foldBlend)
                if let bz = b.z, let tz = target.z, timeline.world.z[hinge.b][i].isFinite {
                    timeline.world.z[hinge.b][i] = Geometry.lerp(bz, tz, config.foldBlend)
                }
                correctedFrames.insert(i)
            }
        }
        qc.priorRangeCorrections += correctedFrames.count
    }

    // MARK: - Grip cluster anchor (Fix G, rebuilt)

    /*
      See GripClusterConfig for the failure and the reasoning. Rebuilt by
      the skeleton overhaul around the three ways the audits showed the old
      stage going quiet or pulling wrong:

        THE WEAK BAND was 0.3 and below, which covered the long-gap holds
        (0.12) but not the short-gap PCHIP bridges, whose visibility is
        the weaker neighbour times 0.95 and lands well above 0.3. A
        bridged wrist drifting off the club was untouchable. The band now
        reaches everything under the anchor bar, and the pull scales with
        weakness, so a hold takes the full blend and a mid-trust bridge a
        fraction.

        THE ANCHOR BAR was 0.6, and through the very windows where one
        wrist is held the other often reads 0.5 to 0.6: still a real
        measurement, but under the bar, so the stage went dead exactly
        when it was needed. The anchor bar is now its own knob at 0.5.

        THE TARGET kept the weak wrist's own bearing from the anchor, a
        bearing inherited from wherever the hold froze, so the pull could
        park the hand at grip DISTANCE but on the wrong side of the
        handle. The target now runs along the anchor side's own measured
        forearm axis (the club hangs off that axis at the grip), signed
        toward the weak wrist's current side, with the old radial pull as
        the fallback when the elbow is dim.

      The trigger also came down (see the config), and the pull now fades
      in over a few frames at the start of each corrected run, so the
      anchor engaging reads as a glide rather than a step. Distance and
      bearing are image-plane statements per space, depth stays untouched,
      each space runs with its own medians and units, and frames are
      counted once into qc.gripClusterFrames however many spaces fired.
    */
    private func anchorGripCluster(_ timeline: inout PoseTimeline, qc: inout TrackingQC) {
        let c = config.gripCluster
        guard c.enabled, timeline.frameCount > 8 else { return }

        let lw = Landmarks.LEFT_WRIST, rw = Landmarks.RIGHT_WRIST
        let le = Landmarks.LEFT_ELBOW, re = Landmarks.RIGHT_ELBOW
        guard max(lw, rw, le, re) < timeline.jointCount else { return }
        let n = timeline.frameCount

        // Best-available visibility, norm preferred, the same convention
        // the cleanup engine reads by, so the trust decisions here agree
        // with the rejections that produced the holds in the first place.
        // NaN (the Vision backend) reads as trusted: nothing can ever be
        // marked weak there, and the stage is inert, the honest behaviour.
        func vis(_ j: Int, _ i: Int) -> Double {
            let v = timeline.norm.visibility[j][i]
            if v.isFinite { return v }
            let w = timeline.world.visibility[j][i]
            return w.isFinite ? w : 1
        }

        var correctedFrames = Set<Int>()

        for space in [PoseSpace.norm, PoseSpace.world] {
            var bank = timeline.channels(space)

            func finite2(_ j: Int, _ i: Int) -> Bool {
                bank.x[j][i].isFinite && bank.y[j][i].isFinite
            }
            func separation(_ i: Int) -> Double? {
                guard finite2(lw, i), finite2(rw, i) else { return nil }
                let dx = bank.x[lw][i] - bank.x[rw][i]
                let dy = bank.y[lw][i] - bank.y[rw][i]
                return (dx * dx + dy * dy).squareRoot()
            }

            // The clip's own confident grip separation: the median wrist
            // to wrist distance over frames where BOTH wrists cleared the
            // trusted bar. Those are the frames where the tracker actually
            // saw the grip, so the median is what a grip looks like on
            // this golfer, at this framing, in this space's units.
            var confidentSeps: [Double] = []
            for i in 0..<n {
                guard vis(lw, i) >= c.trustedMinVisibility,
                      vis(rw, i) >= c.trustedMinVisibility,
                      let s = separation(i) else { continue }
                confidentSeps.append(s)
            }

            // The forearm yardstick for the fallback, pooled over both
            // arms, the hand collapse guard's own golfer-relative scale.
            var forearms: [Double] = []
            for pair in [(le, lw), (re, rw)] {
                for i in 0..<n where finite2(pair.0, i) && finite2(pair.1, i) {
                    let dx = bank.x[pair.0][i] - bank.x[pair.1][i]
                    let dy = bank.y[pair.0][i] - bank.y[pair.1][i]
                    let l = (dx * dx + dy * dy).squareRoot()
                    if l > 1e-6 { forearms.append(l) }
                }
            }
            guard forearms.count > 8 else { continue }
            forearms.sort()
            let medianForearm = forearms[forearms.count / 2]
            guard medianForearm > 1e-6 else { continue }

            let gripSep: Double
            if confidentSeps.count > 8 {
                confidentSeps.sort()
                gripSep = confidentSeps[confidentSeps.count / 2]
            } else {
                gripSep = c.fallbackSeparationForearmFraction * medianForearm
            }
            guard gripSep > 1e-9 else { continue }

            // The trigger: past the factor over the grip median, and never
            // tighter than the forearm-fraction floor, so a clip whose
            // confident median came out tiny (wrists overlapping in a DTL
            // impact cluster) cannot make the stage fight normal stagger.
            let trigger = Swift.max(
                gripSep * c.separationTriggerFactor,
                c.fallbackSeparationForearmFraction * medianForearm
            )

            // Pass 1: decide the correction for every firing frame, but
            // write nothing yet, so the edge ramp below can see whole
            // corrected runs before any sample moves.
            var corrections: [Int: (joint: Int, dx: Double, dy: Double)] = [:]

            for i in 0..<n {
                guard let s = separation(i), s > trigger else { continue }
                let leftVis = vis(lw, i), rightVis = vis(rw, i)

                // Exactly one side anchored, the other weak, or nothing
                // moves: two trusted wrists far apart are a measurement
                // (a hand off the club), two weak wrists have no anchor.
                // The bars are disjoint (0.5 over 0.45), so at most one
                // side can qualify for each role.
                let weak: Int
                if rightVis >= c.anchorMinVisibility, leftVis < c.weakMaxVisibility {
                    weak = lw
                } else if leftVis >= c.anchorMinVisibility, rightVis < c.weakMaxVisibility {
                    weak = rw
                } else {
                    continue
                }
                let anchor = weak == lw ? rw : lw
                let anchorElbow = anchor == lw ? le : re
                let weakVis = weak == lw ? leftVis : rightVis

                // Weakness-scaled blend: a hold at the cleanup's 0.12
                // takes the full pull, a bridge just under the band edge
                // roughly a third of it.
                let span = Swift.max(c.weakMaxVisibility - 0.12, 1e-6)
                let weakness = Geometry.clamp((c.weakMaxVisibility - weakVis) / span, 0, 1)
                let blend = c.blend * (0.35 + 0.65 * weakness)

                // The bearing: the anchor side's own forearm axis when
                // its elbow can vouch for it, signed toward the weak
                // wrist's current side; the weak wrist's stale bearing
                // otherwise.
                var ux = (bank.x[weak][i] - bank.x[anchor][i]) / s
                var uy = (bank.y[weak][i] - bank.y[anchor][i]) / s
                if c.forearmDirectionTarget, finite2(anchorElbow, i),
                   vis(anchorElbow, i) >= c.weakMaxVisibility {
                    let fx = bank.x[anchor][i] - bank.x[anchorElbow][i]
                    let fy = bank.y[anchor][i] - bank.y[anchorElbow][i]
                    let fl = (fx * fx + fy * fy).squareRoot()
                    if fl > 1e-9 {
                        let sign: Double = (fx * ux + fy * uy) >= 0 ? 1 : -1
                        ux = fx / fl * sign
                        uy = fy / fl * sign
                    }
                }

                let targetX = bank.x[anchor][i] + ux * gripSep
                let targetY = bank.y[anchor][i] + uy * gripSep
                corrections[i] = (
                    joint: weak,
                    dx: blend * (targetX - bank.x[weak][i]),
                    dy: blend * (targetY - bank.y[weak][i])
                )
            }

            // Pass 2: apply, fading in over the first edgeRampFrames of
            // each corrected run. No fade at the run's end: a run usually
            // ends at re-acquisition, and the last held frames should sit
            // as close to the returning truth as the pull can put them.
            let firing = corrections.keys.sorted()
            var runs: [[Int]] = []
            for f in firing {
                if let last = runs.last?.last, f == last + 1 {
                    runs[runs.count - 1].append(f)
                } else {
                    runs.append([f])
                }
            }
            let ramp = Swift.max(c.edgeRampFrames, 0)
            for run in runs {
                for (k, i) in run.enumerated() {
                    guard let corr = corrections[i] else { continue }
                    let scale = ramp > 0
                        ? Swift.min(1, Double(k + 1) / Double(ramp + 1))
                        : 1
                    bank.x[corr.joint][i] += corr.dx * scale
                    bank.y[corr.joint][i] += corr.dy * scale
                    correctedFrames.insert(i)
                }
            }

            timeline.setChannels(space, bank)
        }

        qc.gripClusterFrames += correctedFrames.count
    }

    // MARK: - Hand collapse guard (Video 1 impact fix)

    /// Both hands. The trail hand releases through impact, but a knuckle at
    /// zero distance from its own wrist is impossible on either side, and
    /// the guard's fire condition (collapsed AND fast) cannot trigger on a
    /// legitimate release, where the span stays healthy.
    private static let guardedArms: [(elbow: Int, wrist: Int, index: Int, pinky: Int)] = [
        (Landmarks.LEFT_ELBOW, Landmarks.LEFT_WRIST, Landmarks.LEFT_INDEX, Landmarks.LEFT_PINKY),
        (Landmarks.RIGHT_ELBOW, Landmarks.RIGHT_WRIST, Landmarks.RIGHT_INDEX, Landmarks.RIGHT_PINKY),
    ]

    /*
      See HandCollapseGuardConfig for the failure signature and the recorded
      deviations from the brief. One physical speed gate per arm (world
      preferred, norm fallback), then each space is corrected with its own
      medians, directions and units, so norm and world never trade
      geometry. Corrections count once per frame into
      qc.handCollapseCorrections however many arms or spaces fired,
      matching how the bone projection counts.

      NOTE FOR TrackingQC: this stage introduces the counter
      handCollapseCorrections. Add `public var handCollapseCorrections: Int
      = 0` to TrackingQC alongside the other prior counters.
    */
    private func enforceHandSeparation(_ timeline: inout PoseTimeline, qc: inout TrackingQC) {
        let c = config.handCollapse
        guard c.enabled, timeline.frameCount > 8 else { return }

        var correctedFrames = Set<Int>()

        for arm in Self.guardedArms {
            guard max(arm.elbow, arm.wrist, arm.index, arm.pinky) < timeline.jointCount else { continue }
            let fast = fastHandFrames(timeline, wrist: arm.wrist, config: c)

            for space in [PoseSpace.norm, PoseSpace.world] {
                var bank = timeline.channels(space)
                separateCollapsedHand(
                    &bank,
                    arm: arm,
                    isNormSpace: space == .norm,
                    fast: fast,
                    config: c,
                    correctedFrames: &correctedFrames
                )
                timeline.setChannels(space, bank)
            }
        }

        qc.handCollapseCorrections += correctedFrames.count
    }

    /*
      One answer per frame to "was this hand moving fast enough for the blur
      failure": world speed against the metric gate when the wrist carries
      world data around that frame, image-space speed against the norm gate
      otherwise. The larger of the backward and forward step speeds is used
      because impact peaks BETWEEN samples at 60 fps and a one-sided
      difference can halve it.
    */
    private func fastHandFrames(
        _ timeline: PoseTimeline, wrist: Int, config c: HandCollapseGuardConfig
    ) -> [Bool] {
        let n = timeline.frameCount
        var fast = [Bool](repeating: false, count: n)

        func stepSpeed(_ bank: PoseTimeline.Channels, _ i: Int, _ k: Int, threeD: Bool) -> Double? {
            guard bank.x[wrist][i].isFinite, bank.y[wrist][i].isFinite,
                  bank.x[wrist][k].isFinite, bank.y[wrist][k].isFinite
            else { return nil }
            let dt = abs(timeline.times[i] - timeline.times[k]) / 1000
            guard dt > 1e-4 else { return nil }
            let dx = bank.x[wrist][i] - bank.x[wrist][k]
            let dy = bank.y[wrist][i] - bank.y[wrist][k]
            var d2 = dx * dx + dy * dy
            if threeD, bank.z[wrist][i].isFinite, bank.z[wrist][k].isFinite {
                let dz = bank.z[wrist][i] - bank.z[wrist][k]
                d2 += dz * dz
            }
            return d2.squareRoot() / dt
        }

        for i in 0..<n {
            var worldSpeed: Double? = nil
            if i > 0, let s = stepSpeed(timeline.world, i, i - 1, threeD: true) { worldSpeed = s }
            if i + 1 < n, let s = stepSpeed(timeline.world, i, i + 1, threeD: true) {
                worldSpeed = Swift.max(worldSpeed ?? 0, s)
            }
            if let ws = worldSpeed {
                fast[i] = ws > c.minHandSpeedWorld
                continue
            }
            var normSpeed: Double? = nil
            if i > 0, let s = stepSpeed(timeline.norm, i, i - 1, threeD: false) { normSpeed = s }
            if i + 1 < n, let s = stepSpeed(timeline.norm, i, i + 1, threeD: false) {
                normSpeed = Swift.max(normSpeed ?? 0, s)
            }
            if let ns = normSpeed { fast[i] = ns > c.minHandSpeedNorm }
        }
        return fast
    }

    private func separateCollapsedHand(
        _ bank: inout PoseTimeline.Channels,
        arm: (elbow: Int, wrist: Int, index: Int, pinky: Int),
        isNormSpace: Bool,
        fast: [Bool],
        config c: HandCollapseGuardConfig,
        correctedFrames: inout Set<Int>
    ) {
        let n = fast.count

        func finite2(_ j: Int, _ i: Int) -> Bool {
            bank.x[j][i].isFinite && bank.y[j][i].isFinite
        }
        func palm(_ i: Int) -> (x: Double, y: Double, z: Double)? {
            guard finite2(arm.index, i), finite2(arm.pinky, i) else { return nil }
            let zi = bank.z[arm.index][i], zp = bank.z[arm.pinky][i]
            let z = (zi.isFinite && zp.isFinite) ? (zi + zp) / 2 : Double.nan
            return (
                x: (bank.x[arm.index][i] + bank.x[arm.pinky][i]) / 2,
                y: (bank.y[arm.index][i] + bank.y[arm.pinky][i]) / 2,
                z: z
            )
        }
        func dist(_ ax: Double, _ ay: Double, _ az: Double,
                  _ bx: Double, _ by: Double, _ bz: Double) -> Double {
            let dx = ax - bx, dy = ay - by
            let dz = (az.isFinite && bz.isFinite) ? az - bz : 0
            return (dx * dx + dy * dy + dz * dz).squareRoot()
        }

        // Clip medians in this space's own units: the hand span (wrist to
        // palm centre) and the forearm. Collapsed frames are a handful out
        // of hundreds, so the median shrugs them off.
        var handSpans: [Double] = []
        var forearms: [Double] = []
        for i in 0..<n {
            if finite2(arm.wrist, i), let p = palm(i) {
                handSpans.append(dist(
                    bank.x[arm.wrist][i], bank.y[arm.wrist][i], bank.z[arm.wrist][i],
                    p.x, p.y, p.z
                ))
            }
            if finite2(arm.elbow, i), finite2(arm.wrist, i) {
                let f = dist(
                    bank.x[arm.elbow][i], bank.y[arm.elbow][i], bank.z[arm.elbow][i],
                    bank.x[arm.wrist][i], bank.y[arm.wrist][i], bank.z[arm.wrist][i]
                )
                if f > 1e-6 { forearms.append(f) }
            }
        }
        guard handSpans.count > 8, forearms.count > 8 else { return }
        handSpans.sort()
        forearms.sort()
        let medianHand = handSpans[handSpans.count / 2]
        let medianForearm = forearms[forearms.count / 2]
        guard medianForearm > 1e-6 else { return }

        // The anatomical minimum the brief asked for, defined against the
        // clip-median forearm, then the working collapse threshold: never
        // wider than the minimum, the absolute 0.015 (norm space only), or
        // half this golfer's own healthy span.
        let minSeparation = c.minSeparationForearmFraction * medianForearm
        var threshold = minSeparation
        if isNormSpace { threshold = Swift.min(threshold, c.collapseDistanceNorm) }
        if medianHand > 1e-9 {
            threshold = Swift.min(threshold, c.collapseMedianFraction * medianHand)
        }
        guard threshold > 0 else { return }

        // What "restored" means: the golfer's own healthy median span when
        // the clip produced one, the anatomical fraction of the forearm
        // when it did not, never below the minimum either way.
        var target = medianHand > threshold
            ? medianHand
            : c.defaultSeparationForearmFraction * medianForearm
        target = Swift.max(target, minSeparation)

        for i in 0..<n where fast[i] {
            guard finite2(arm.wrist, i), finite2(arm.elbow, i), let p = palm(i) else { continue }
            let wx = bank.x[arm.wrist][i], wy = bank.y[arm.wrist][i], wz = bank.z[arm.wrist][i]
            let d = dist(wx, wy, wz, p.x, p.y, p.z)
            guard d < threshold else { continue }

            // Forearm direction, measured this frame. Depth participates
            // only when both ends carry it, so a 2D space stays 2D.
            let ex = bank.x[arm.elbow][i], ey = bank.y[arm.elbow][i], ez = bank.z[arm.elbow][i]
            var dx = wx - ex, dy = wy - ey
            let useZ = wz.isFinite && ez.isFinite && p.z.isFinite
            var dz = useZ ? wz - ez : 0
            let len = (dx * dx + dy * dy + dz * dz).squareRoot()
            guard len > 1e-6 else { continue }
            dx /= len; dy /= len; dz /= len

            // Translate the two knuckles together so their measured spread
            // survives; only the palm CENTRE is repositioned.
            let moveX = (wx + dx * target) - p.x
            let moveY = (wy + dy * target) - p.y
            for j in [arm.index, arm.pinky] where finite2(j, i) {
                bank.x[j][i] += moveX
                bank.y[j][i] += moveY
            }
            if useZ {
                let moveZ = (wz + dz * target) - p.z
                for j in [arm.index, arm.pinky] where bank.z[j][i].isFinite {
                    bank.z[j][i] += moveZ
                }
            }
            correctedFrames.insert(i)
        }
    }
}

// MARK: - Dataset logger (TASK 5, the data side)

/*
  Every learned prior in the deferred column (C, Q, F, L, N and the ML half
  of M) is blocked on one thing: a dataset of cleaned, tracked swings that
  does not exist yet. This logger makes it exist, one shipped upload at a
  time. It writes the refined normalised timeline plus its QC record to
  Application Support, fire and forget, capped so it can never eat the disk.

  Schema, version 2, one JSON file per swing:

    {
      "version": 2,
      "source": "upload",
      "createdAt": "2026-08-18T12:00:00Z",
      "gridHz": 60,
      "qc": { ...TrackingQC, Codable... },
      "frames": [ { "t": 0, "xy": [66 doubles], "vis": [33 doubles] }, ... ]
    }

  xy is the 33-joint normalised (x, y) pairs in landmark order; vis is
  visibility with -1 standing in for "backend reported none", because JSON
  cannot carry NaN. The QC record travelling alongside is what lets the
  training script keep only honestly tracked frames, so the future GMM never
  learns from gap fill.
*/
public enum SwingDatasetLogger {

    /// Oldest logs beyond this count are pruned on each write.
    public static var maxStoredSwings = 200

    private static let queue = DispatchQueue(label: "swingline.dataset-logger", qos: .utility)

    private struct FrameEntry: Encodable {
        var t: Double
        var xy: [Double]
        var vis: [Double]
    }

    private struct Entry: Encodable {
        var version = 2
        var source: String
        var createdAt: String
        var gridHz: Double
        var qc: TrackingQC
        var frames: [FrameEntry]
    }

    public static func log(frames: [Frame], qc: TrackingQC, source: String) {
        guard !frames.isEmpty else { return }
        queue.async {
            write(frames: frames, qc: qc, source: source)
        }
    }

    /// Where the dataset lives, for the export path that hands it to the
    /// training script. Created on demand.
    public static func directory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = base.appendingPathComponent("SwingDataset", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func write(frames: [Frame], qc: TrackingQC, source: String) {
        func round4(_ x: Double) -> Double { (x * 10000).rounded() / 10000 }

        var entries: [FrameEntry] = []
        entries.reserveCapacity(frames.count)
        for f in frames {
            var xy = [Double](repeating: 0, count: 66)
            var vis = [Double](repeating: -1, count: 33)
            for j in 0..<min(33, f.norm.count) {
                let l = f.norm[j]
                xy[2 * j] = l.x.isFinite ? round4(l.x) : 0
                xy[2 * j + 1] = l.y.isFinite ? round4(l.y) : 0
                if let v = l.visibility ?? l.score, v.isFinite {
                    vis[j] = (v * 1000).rounded() / 1000
                }
            }
            entries.append(FrameEntry(t: f.t, xy: xy, vis: vis))
        }

        let formatter = ISO8601DateFormatter()
        let entry = Entry(
            source: source,
            createdAt: formatter.string(from: Date()),
            gridHz: qc.gridHz,
            qc: qc,
            frames: entries
        )

        do {
            let dir = try directory()
            let name = "swing-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).json"
            let data = try JSONEncoder().encode(entry)
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
            prune(dir)
        } catch {
            // A failed log must never surface to the golfer; the swing
            // itself is untouched. Note it and move on.
            print("[SwingDatasetLogger] write failed: \(error)")
        }
    }

    private static func prune(_ dir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }
        let logs = files.filter { $0.pathExtension == "json" }
        guard logs.count > maxStoredSwings else { return }
        let dated = logs.compactMap { url -> (URL, Date)? in
            let d = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            return d.map { (url, $0) }
        }.sorted { $0.1 < $1.1 }
        for (url, _) in dated.prefix(dated.count - maxStoredSwings) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
