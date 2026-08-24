//
//  SkeletonOverlay.swift
//  Swingline
//
//  The skeleton, drawn over the video as a pure function of frame index. Ported
//  from the web SkeletonOverlay.jsx, with one deliberate difference explained
//  below.
//
//  The web overlay runs thirty three damped springs so the live capture
//  skeleton settles into each new pose with a little elastic overshoot. That is
//  the right choice for a live viewfinder, where the springs hide pose jitter
//  and make the figure look alive. It is the wrong choice for scrubbing
//  playback, where the whole point is that what you see is exactly frame N, not
//  a spring still catching up to it. Dragging the playbar back a frame has to
//  show that frame, not an animation relaxing toward it. So in playback the
//  skeleton is a straight lookup: frames[frameIndex].norm, drawn as is. This is
//  the same discipline trackingLayers.js insists on, applied to the skeleton.
//
//  Colours are carried across from the web STYLES.clean: a cool cyan bone
//  against a warm yellow joint, which separates at a glance and holds up against
//  grass, turf and sky. The wrists are held back to half size and opacity,
//  because the model returns four points per hand inside a few centimetres and
//  at full weight they merge into one blob exactly where the club meets the
//  hands. The spine is drawn separately and brighter, since it is the line a
//  coach actually reads.
//
//  WHAT THIS PASS CHANGED, AND WHY
//
//  1. ONE SIDE RULE, LEFT BLUE AND RIGHT RED, FIXED BY INDEX.
//
//     The side a bone or joint belongs to is decided by one helper,
//     isLeftJoint, from the landmark index alone, and never from visibility,
//     confidence or swing phase.
//
//     The joint dots are the fixed reference: they are ALWAYS drawn in their
//     side colour, blue on the left and red on the right, in every colour mode
//     and in both the analysis view and the fullscreen viewer. Nothing in
//     settings recolours a dot. That is what closes the "pink and blue not
//     consistent through Phase 5" gap: a dot keeps its colour through an
//     occluded stretch because nothing about its colour depends on how well it
//     is seen or on what the golfer picked in settings.
//
//     The bones are the customisable layer: boneColour still honours single,
//     dual and custom lead/trail colours from settings, and falls back to the
//     built in blue and red. So a golfer can restyle the lines, but the dots
//     underneath them stay the fixed blue/red anatomical key.
//
//  2. THE FEET DRAW AS ONE FILLED SHAPE WITH A ROLL ANGLE.
//
//     Ankle to heel to toe and back, in the foot's side colour, now with a
//     translucent fill so the three points read as one foot rather than as
//     extra leg joints (the frame audits' "three vertical joints dotted to
//     the ground" confusion). The sole line's tilt from level is printed
//     beside the toe: a planted foot reads near zero and sits flat; as the
//     heel lifts through the follow through the triangle tilts and the
//     number climbs. The heel and toe dots shrink to markers and dim,
//     since the filled shape now carries the foot's form; the ankle keeps
//     a full joint dot because it is a real leg joint. Drawn only when all
//     three foot points are confidently tracked.
//
//  3. WRIST DOTS KEEP A DARK RIM.
//
//     With grip fusion removed the two wrists draw separately, and at a
//     DTL impact they legitimately overlap into one cluster on the handle.
//     A thin dark rim on each wrist dot keeps the blue and red dots
//     readable as two points when they stack, instead of bleeding into one
//     muddy blob.
//
//  Glow is dropped in favour of a dark joint rim. A per element shadow at sixty
//  frames on a mid range phone is not worth the cost, and the rim keeps a bright
//  joint legible against a bright background just as well.
//
//  House rule: no em dashes anywhere.
//

import SwiftUI

struct SkeletonOverlay: View {
    let frames: [Frame]
    let frameIndex: Int
    var mirrored: Bool = false
    var showSpine: Bool = true
    /*
      When present, thickness, joint size and colour mode come from here and the
      joints render as the reference ring. When nil, the overlay draws exactly as
      before, which is what the fullscreen viewer relies on, so nothing there
      changes.
    */
    var settings: SkeletonSettings? = nil

    // From STYLES.clean in SkeletonOverlay.jsx.
    private let bone = Color(red: 94 / 255, green: 226 / 255, blue: 255 / 255, opacity: 0.85)
    private let boneWidth: CGFloat = 2.4
    private let joint = Color(red: 1, green: 225 / 255, blue: 77 / 255)
    private let jointEdge = Color(red: 24 / 255, green: 34 / 255, blue: 30 / 255, opacity: 0.75)
    private let jointRadius: CGFloat = 6.5
    private let spine = Color(red: 1, green: 225 / 255, blue: 77 / 255, opacity: 0.55)

    /*
      Visibility floors, retuned for the MediaPipe upload path.

      The old 0.35 body floor was set against Vision, which reports confidence
      generously. MediaPipe reports honest visibility, and an occluded trail
      leg or arm in a down the line clip sits in the 0.15 to 0.35 band for
      hundreds of milliseconds through the downswing. At 0.35 those limbs
      vanished while the feet (on their lower 0.25 floor) kept drawing, which
      is exactly the floating feet with no shins seen in testing.

      Three bands now instead of two:
        at or above the full floor   drawn at full opacity, as before
        between skip and full        drawn dimmed, so an occluded limb reads
                                     as "tracked, less certain" not "gone"
        below the skip floor         not drawn at all; that is a joint the
                                     tracker genuinely lost, and drawing it
                                     would be a guessed position
    */
    private let bodyFullFloor: Double = 0.2
    private let footFullFloor: Double = 0.15
    private let skipFloor: Double = 0.05
    private let dimmedOpacity: Double = 0.45

    // Side colours for the dual colour mode. Left blue, right red, matching the
    // "Blue and red" card and the fullscreen figure.
    private let leftColour = Color(red: 77 / 255, green: 166 / 255, blue: 255 / 255)
    private let rightColour = Color(red: 1, green: 59 / 255, blue: 48 / 255)

    // A body landmark is on the left when its index is odd, right when even,
    // for indices 11 and up (below 11 are face points, never drawn here). This
    // is the ONE side rule the whole overlay uses, so left and right never
    // disagree between bones, joints and the foot triangle.
    private func isLeftJoint(_ index: Int) -> Bool { index % 2 == 1 }

    // The strict side colour: left blue, right red, from the index and nothing
    // else. It does not read visibility, confidence or phase, so a joint keeps
    // its colour through an occluded stretch instead of drifting, which is the
    // Phase 5 colour inconsistency the report flagged. Custom lead and trail
    // colours still apply in dual mode below; this is the fixed fallback and
    // the colour the joints and the foot triangle use.
    private func sideColour(_ index: Int) -> Color {
        isLeftJoint(index) ? leftColour : rightColour
    }

    // Effective draw parameters, from settings when present.
    private var effectiveBoneWidth: CGFloat { settings.map { CGFloat($0.thickness) } ?? boneWidth }
    private var effectiveJointRadius: CGFloat { settings.map { 3.5 + CGFloat($0.jointSize) * 4.5 } ?? jointRadius }

    /*
      Whether the connecting lines are drawn: the bones, the spine and the foot
      triangles. Off leaves the joint dots and angle readouts untouched. Only the
      analysis view carries settings, so the fullscreen viewer (settings nil)
      always draws the lines, exactly as before.
    */
    private var drawConnectingLines: Bool { settings?.showConnectingLines ?? true }

    // A body landmark is on the left when its index is odd, right when even, for
    // indices 11 and up. Used to colour bones by side.
    // The golfer's chosen colours, falling back to the built in blue and red.
    private var leadCustom: Color { settings.map { Color(hex: $0.leadColorHex) } ?? leftColour }
    private var trailCustom: Color { settings.map { Color(hex: $0.trailColorHex) } ?? rightColour }
    private var singleCustom: Color { settings.map { Color(hex: $0.singleColorHex) } ?? Tok.citrusDeep }

    private func boneColour(_ a: Int, _ b: Int) -> Color {
        guard let mode = settings?.colorMode else { return bone }
        if mode == .single { return singleCustom }
        let aLeft = isLeftJoint(a), bLeft = isLeftJoint(b)
        if aLeft && bLeft { return leadCustom }
        if !aLeft && !bLeft { return trailCustom }
        return bone  // a midline bone, kept neutral
    }

    // Joint dots do not have a colour helper any more: they are always the
    // fixed sideColour above, never a settings or colour-mode colour. The bone
    // colouring (boneColour) is the only customisable path; the dots are the
    // fixed reference and are filled straight from sideColour in the body.

    var body: some View {
        Canvas { context, size in
            guard frames.indices.contains(frameIndex) else { return }
            let landmarks = frames[frameIndex].norm

            func visibility(_ i: Int) -> Double {
                guard landmarks.indices.contains(i) else { return 0 }
                let l = landmarks[i]
                return l.visibility ?? l.score ?? 1
            }

            func point(_ i: Int) -> CGPoint? {
                guard landmarks.indices.contains(i) else { return nil }
                let p = landmarks[i]
                let x = (mirrored ? 1 - p.x : p.x) * size.width
                let y = p.y * size.height
                return CGPoint(x: x, y: y)
            }

            func mid(_ a: Int, _ b: Int) -> CGPoint? {
                guard let pa = point(a), let pb = point(b) else { return nil }
                return CGPoint(x: (pa.x + pb.x) / 2, y: (pa.y + pb.y) / 2)
            }

            // Bones. A joint pair below the skip floor is dropped rather than
            // drawn to a guessed position; a pair in the dim band is drawn at
            // reduced opacity, so an occluded limb stays on screen through
            // P5 to P7 instead of flickering out. See the floors note above.
            // Skipped entirely when the golfer has turned connecting lines off,
            // which leaves the joint dots and angle readouts below in place.
            if drawConnectingLines {
            for (a, b) in Landmarks.BONES {
                // Per joint line switch: a bone whose either end sits on a joint
                // the golfer turned off is skipped, so the legs can be stripped
                // back while the arms stay drawn. See SkeletonSettings.drawsLine.
                if let settings, !settings.drawsLine(from: a, to: b) { continue }
                // Foot bones use the same lower floor as the foot joints, so the
                // ankle to heel to foot index triangle draws when those points
                // are tracked a little less confidently.
                let footPair = Landmarks.footJoints.contains(a) && Landmarks.footJoints.contains(b)
                let fullFloor = footPair ? footFullFloor : bodyFullFloor
                let pairVis = min(visibility(a), visibility(b))
                guard pairVis >= skipFloor,
                      let A = point(a), let B = point(b) else { continue }
                let alpha = pairVis >= fullFloor ? 1.0 : dimmedOpacity
                var path = Path()
                path.move(to: A)
                path.addLine(to: B)
                context.stroke(
                    path,
                    with: .color(boneColour(a, b).opacity(alpha)),
                    style: StrokeStyle(lineWidth: effectiveBoneWidth, lineCap: .round, lineJoin: .round)
                )
            }

            /*
              The spine, drawn separately and brighter, dashed like the web. It
              spans the shoulder and hip midpoints, so it follows those four
              joints' line switches: turning both shoulders or both hips off takes
              the spine with them, which is what a golfer stripping the torso back
              expects.
            */
            let spineOn = settings.map { s in
                (s.setting(for: .leftShoulder).showLine || s.setting(for: .rightShoulder).showLine)
                    && (s.setting(for: .leftHip).showLine || s.setting(for: .rightHip).showLine)
            } ?? true
            if showSpine, spineOn, let top = mid(11, 12), let hip = mid(23, 24) {
                var path = Path()
                path.move(to: top)
                path.addLine(to: hip)
                context.stroke(
                    path,
                    with: .color(spine),
                    style: StrokeStyle(lineWidth: effectiveBoneWidth * 0.9, lineCap: .round, dash: [6, 6])
                )
            }
            } // drawConnectingLines: bones and spine

            // Joints.
            for i in Landmarks.DRAWN_JOINTS {
                // Feet track less confidently than the torso, so they get a
                // lower visibility floor. The ankle keeps a full joint dot,
                // it is a real leg joint; the heel and toe shrink to small,
                // dimmer markers because the filled foot shape below now
                // carries the foot's form, and three full dots per foot is
                // exactly what read as extra vertical leg joints in the
                // frame audits.
                let isFootTip = (i == Landmarks.LEFT_HEEL || i == Landmarks.RIGHT_HEEL
                    || i == Landmarks.LEFT_FOOT_INDEX || i == Landmarks.RIGHT_FOOT_INDEX)
                let isAnkle = (i == Landmarks.LEFT_ANKLE || i == Landmarks.RIGHT_ANKLE)
                let isFoot = isFootTip || isAnkle
                let fullFloor = isFoot ? footFullFloor : bodyFullFloor
                let vis = visibility(i)
                guard vis >= skipFloor, let P = point(i) else { continue }
                let alpha = vis >= fullFloor ? 1.0 : dimmedOpacity
                let isWrist = (i == 15 || i == 16)
                let radius: CGFloat = {
                    if isWrist { return effectiveJointRadius * 0.5 }
                    if isFootTip { return effectiveJointRadius * 0.55 }
                    return effectiveJointRadius
                }()
                let rect = CGRect(x: P.x - radius, y: P.y - radius, width: radius * 2, height: radius * 2)
                let circle = Path(ellipseIn: rect)

                // The joint dots are FIXED to their side colour, blue on the
                // left and red on the right, from the landmark index alone.
                // This is deliberately independent of settings and colour mode:
                // the bones stay customisable through boneColour, but the dots
                // are the fixed anatomical reference and must not be recoloured,
                // dimmed to yellow, or flipped by any setting. Both the analysis
                // view (settings present) and the fullscreen viewer (settings
                // nil) therefore draw the same blue/red dots.
                // Heel and toe markers sit a step dimmer than real joints,
                // in both views, so the leg visually ends at the ankle and
                // the foot reads as the filled shape below.
                let tipFade: Double = isFootTip ? 0.75 : 1

                if settings != nil {
                    // Solid disc in the fixed side colour, no inner dot, matching
                    // the web app.
                    context.fill(circle, with: .color(sideColour(i).opacity((isWrist ? 0.55 : 1) * tipFade * alpha)))
                    if isWrist {
                        // The rim that keeps two stacked grip dots readable
                        // as two points; see header note 3.
                        context.stroke(circle, with: .color(jointEdge.opacity(0.9 * alpha)), lineWidth: 1)
                    }
                } else {
                    // Fullscreen viewer: same fixed side colour, with the dark
                    // rim kept for legibility against a bright background.
                    context.fill(circle, with: .color(sideColour(i).opacity((isWrist ? 0.45 : 1) * tipFade * alpha)))
                    context.stroke(circle, with: .color(jointEdge.opacity((isWrist ? 0.9 : 1) * alpha)), lineWidth: isWrist ? 1 : 1.2)
                }
            }

            /*
              The foot triangles and their roll angle.

              Each foot is drawn as ankle to heel to toe and back, in that
              foot's side colour, so the three dots read as one rotating shape
              instead of three loose points. As the heel lifts through the
              follow through the triangle tilts with it and the toe stays down,
              which is the roll the report wanted visible.

              The number is the sole's tilt away from level in the image: the
              angle of the heel to toe line from horizontal, which is zero for
              a flat foot and climbs as the heel rises above the toe. It is
              read straight off the two drawn points, so the label always
              agrees with the shape on screen. Drawn only when all three foot
              points clear the foot floor, so a lost foot shows nothing rather
              than a wrong angle. Independent of settings, so the fullscreen
              viewer gets it too.

              The foot triangle is a connecting shape, so it follows the same
              lines switch as the bones and spine: off drops it and leaves the
              ankle, heel and toe dots.
            */
            if drawConnectingLines {
            for foot in Self.feet {
                // The foot triangle hangs off the ankle, so it follows that
                // ankle's line switch.
                if let settings, let key = JointKey.owning(landmark: foot.ankle),
                   !settings.setting(for: key).showLine { continue }
                let floor = footFullFloor
                guard visibility(foot.ankle) >= floor,
                      visibility(foot.heel) >= floor,
                      visibility(foot.toe) >= floor,
                      let ankle = point(foot.ankle),
                      let heel = point(foot.heel),
                      let toe = point(foot.toe) else { continue }

                // The triangle, ankle to heel to toe to ankle, in side
                // colour: a translucent fill first so the foot reads as
                // one solid shape (the frame audits' fix for the "three
                // vertical joints" confusion), then the stroke on top so
                // the sole line the roll angle is read from stays crisp.
                var tri = Path()
                tri.move(to: ankle)
                tri.addLine(to: heel)
                tri.addLine(to: toe)
                tri.closeSubpath()
                context.fill(tri, with: .color(sideColour(foot.ankle).opacity(0.18)))
                context.stroke(
                    tri,
                    with: .color(sideColour(foot.ankle).opacity(0.9)),
                    style: StrokeStyle(lineWidth: effectiveBoneWidth, lineCap: .round, lineJoin: .round)
                )

                // Roll angle: the heel to toe line's tilt from horizontal, in
                // image space where up is negative y. atan2 of the rise over
                // the run gives a signed tilt; its magnitude is how far the
                // foot has rolled, and it reads zero flat and grows on the toe.
                let run = Double(toe.x - heel.x)
                let rise = Double(heel.y - toe.y)  // screen y is down, so this
                                                   // is negative when the heel
                                                   // rides above the toe; only
                                                   // the magnitude is used below
                let len = (run * run + rise * rise).squareRoot()
                guard len > 1e-6 else { continue }
                let rollDeg = abs(atan2(rise, run)) * 180 / .pi
                // Fold angles past vertical back down: a foot line is the same
                // tilt whether it points left or right, so 170 degrees of run
                // is really 10 degrees of tilt.
                let shown = rollDeg > 90 ? 180 - rollDeg : rollDeg

                // Label sits just beyond the toe, along the sole direction, so
                // it tracks the foot instead of colliding with the shin.
                let ux = run / len, uy = -rise / len  // back to screen y-down
                let labelPoint = CGPoint(x: toe.x + CGFloat(ux) * 22, y: toe.y + CGFloat(uy) * 22)
                /*
                  Drawn with the same outline the joint angle readouts use, so
                  every number over the video is styled one way. A one sided drop
                  shadow left this one losing its top edge against sky, which is
                  exactly where a lifting heel puts it.
                */
                let text = "\(Int(shown.rounded()))\u{00b0}"
                drawOutlined(
                    text,
                    at: labelPoint,
                    fontSize: 13,
                    colour: sideColour(foot.ankle),
                    in: context
                )
            }
            } // drawConnectingLines: foot triangles

            /*
              Joint angle labels.

              Only where a joint has two clear adjacent segments does an angle read
              as anything, and every joint the sheet exposes has two: the shoulder,
              elbow, wrist, hip, knee and ankle on both sides, listed with their
              segment pairs in `angleJoints` below.

              Inner and outer are independent toggles and both can be on at once,
              so each is drawn in its own `if` rather than chosen between. The
              inner angle is the interior bend. The outer angle is its supplement
              (180 minus the interior), obtained by extending the first limb
              through the joint and sweeping to the second, which lands the arc and
              its label on the far side of the bend. Drawn only when the joint's
              three landmarks are visible, so a lost joint shows no number rather
              than a wrong one.
            */
            if let settings {
                for (joint, ends) in Self.angleJoints {
                    let s = settings.setting(for: joint)
                    guard s.innerAngle || s.outerAngle else { continue }
                    let v = joint.landmark
                    // Angle labels take the full floor with no dim band on
                    // purpose: a dimmed line says "less certain", but a number
                    // computed from an uncertain joint is simply a wrong
                    // number, and this app does not print those.
                    guard visibility(ends.0) >= bodyFullFloor, visibility(v) >= bodyFullFloor, visibility(ends.1) >= bodyFullFloor,
                          let a = point(ends.0), let b = point(v), let c = point(ends.1) else { continue }

                    let style = settings.angle
                    let interior = Self.interiorAngle(a, b, c)

                    // Unit directions from the joint out along each limb.
                    let ux = Double(a.x - b.x), uy = Double(a.y - b.y)
                    let wx = Double(c.x - b.x), wy = Double(c.y - b.y)
                    let lu = max(1e-6, (ux * ux + uy * uy).squareRoot())
                    let lw = max(1e-6, (wx * wx + wy * wy).squareRoot())
                    let u = (ux / lu, uy / lu)
                    let w = (wx / lw, wy / lw)

                    /*
                      How much room this joint actually has for an arc.

                      The style carries a radius in points, which is a fixed size
                      on screen and takes no account of how big the golfer is in
                      frame or how short the limb is. A 26 point arc at an ankle
                      whose shin is 30 points long swallows the whole shin and
                      spills past the knee, which is the uneven, overlapping
                      readout the frame audits flagged. Handing the shorter of the
                      two adjacent limbs to the readout lets it cap itself, so the
                      arc always sits inside the bend it measures, at every zoom
                      level and on every joint.
                    */
                    let limbSpan = min(lu, lw)

                    // Inner angle: sweep the short way from one limb to the other,
                    // so the arc and its label sit inside the bend.
                    if s.innerAngle {
                        let sweep = atan2(u.0 * w.1 - u.1 * w.0, u.0 * w.0 + u.1 * w.1)
                        drawAngleReadout(
                            shown: interior,
                            vertex: b,
                            startDir: u,
                            sweep: sweep,
                            limbSpan: limbSpan,
                            showArc: style.showArc,
                            arcRadius: CGFloat(style.arcRadius),
                            arcThickness: CGFloat(style.arcThickness),
                            arcColorHex: style.arcColorHex,
                            showDegrees: style.showDegrees,
                            fontSize: CGFloat(style.fontSize),
                            fontColorHex: style.fontColorHex,
                            in: context
                        )
                    }

                    /*
                      Outer angle: the reflex angle at the joint, swept the long
                      way round from one limb to the other.

                      This used to start from the first limb reflected through the
                      joint and sweep to the second, which measures the supplement,
                      180 minus the interior. Two things were wrong with that. The
                      arc began on the reflection rather than on a limb, so it hung
                      in space with a visible gap at its start, which is the gap in
                      the reported frames. And the supplement is not the angle on
                      the outside of a bend: the outside of a 42 degree bend is 318
                      degrees, not 138.

                      Sweeping the same start direction the other way round fixes
                      both at once. Subtracting a full turn from the inner sweep
                      keeps the end direction identical, so the arc still finishes
                      exactly on the second limb, but it now travels the long way
                      and starts exactly on the first. Both ends land on real
                      limbs, the gap is gone, and the number is 360 minus the
                      interior, which is what the reference readouts show.
                    */
                    if s.outerAngle {
                        let inner = atan2(u.0 * w.1 - u.1 * w.0, u.0 * w.0 + u.1 * w.1)
                        let reflex = inner - (inner >= 0 ? 2 * Double.pi : -2 * Double.pi)
                        drawAngleReadout(
                            shown: 360 - interior,
                            vertex: b,
                            startDir: u,
                            sweep: reflex,
                            limbSpan: limbSpan,
                            reflex: true,
                            showArc: style.showArc,
                            arcRadius: CGFloat(style.arcRadius),
                            arcThickness: CGFloat(style.arcThickness),
                            arcColorHex: style.arcColorHex,
                            showDegrees: style.showDegrees,
                            fontSize: CGFloat(style.fontSize),
                            fontColorHex: style.fontColorHex,
                            in: context
                        )
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /*
      One angle readout: an arc of the swept angle at a fixed radius from the
      joint, plus the degree label along the arc's bisector just beyond it.

      The arc is sampled as a short polyline rotating the start direction toward
      the end, so both its sweep direction and its measure are exact and do not
      depend on Path.addArc's clockwise convention (which flips under SwiftUI's
      y down coordinate space and is easy to get wrong). Rotating a unit vector
      by the signed angle atan2(cross, dot) lands it exactly on the other limb,
      so stepping the rotation from zero to that signed angle traces the correct
      short arc; the same trick gives the bisector at half the sweep.
    */
    private func drawAngleReadout(
        shown: Double,
        vertex: CGPoint,
        startDir: (Double, Double),
        sweep: Double,
        limbSpan: Double,
        reflex: Bool = false,
        showArc: Bool,
        arcRadius: CGFloat,
        arcThickness: CGFloat,
        arcColorHex: String,
        showDegrees: Bool,
        fontSize: CGFloat,
        fontColorHex: String,
        in context: GraphicsContext
    ) {
        /*
          The radius actually used, capped to the joint it belongs to.

          The style's radius is a request, not a command. Half the shorter
          adjacent limb is the ceiling: at that size the arc reaches halfway to
          the next joint and stops, so it always reads as belonging to this bend
          and never crosses the neighbouring one. A floor keeps it from
          collapsing to nothing on a foreshortened limb, and the whole thing is
          clamped rather than scaled so a golfer who asks for a small arc still
          gets a small arc on a long limb.
        */
        let ceiling = CGFloat(limbSpan) * 0.5
        /*
          A reflex arc wraps the joint rather than sitting inside the bend, so it
          is pushed out a little further. That is what keeps both readouts legible
          when a golfer has inner and outer on at the same joint: two arcs at one
          radius would trace the same circle and read as a single muddled ring.
          The nudge is a fraction, not a fixed gap, so it holds at every zoom.
        */
        let radius = max(9, min(arcRadius, ceiling)) * (reflex ? 1.32 : 1)
        let colour = Color(hex: arcColorHex)

        if showArc {
            let steps = 32
            var arc = Path()
            for k in 0...steps {
                let t = sweep * Double(k) / Double(steps)
                let ct = cos(t), st = sin(t)
                let dx = startDir.0 * ct - startDir.1 * st
                let dy = startDir.0 * st + startDir.1 * ct
                let pt = CGPoint(x: vertex.x + CGFloat(dx) * radius,
                                 y: vertex.y + CGFloat(dy) * radius)
                if k == 0 { arc.move(to: pt) } else { arc.addLine(to: pt) }
            }
            /*
              A dark backing stroke under the bright one. A single thin lime arc
              over sunlit grass is nearly invisible in exactly the frames a golfer
              wants to read; laying the same path down first in translucent black,
              two points wider, gives it an edge on any background without
              thickening the arc itself.
            */
            context.stroke(
                arc,
                with: .color(.black.opacity(0.45)),
                style: StrokeStyle(lineWidth: arcThickness + 2, lineCap: .round, lineJoin: .round)
            )
            context.stroke(
                arc,
                with: .color(colour),
                style: StrokeStyle(lineWidth: arcThickness, lineCap: .round, lineJoin: .round)
            )

            /*
              Two short ticks closing the arc onto the limbs it measures, so the
              sweep reads as a measurement between two segments rather than as a
              stray curve floating near a joint.
            */
            for t in [0, sweep] {
                let ct = cos(t), st = sin(t)
                let dx = startDir.0 * ct - startDir.1 * st
                let dy = startDir.0 * st + startDir.1 * ct
                var tick = Path()
                tick.move(to: CGPoint(x: vertex.x + CGFloat(dx) * (radius - arcThickness),
                                      y: vertex.y + CGFloat(dy) * (radius - arcThickness)))
                tick.addLine(to: CGPoint(x: vertex.x + CGFloat(dx) * (radius + arcThickness * 1.6),
                                         y: vertex.y + CGFloat(dy) * (radius + arcThickness * 1.6)))
                context.stroke(
                    tick,
                    with: .color(colour.opacity(0.9)),
                    style: StrokeStyle(lineWidth: arcThickness * 0.8, lineCap: .round)
                )
            }
        }

        guard showDegrees else { return }

        /*
          The label sits on the bisector of the swept angle, just past the arc.

          Rotating the start direction by half the sweep lands exactly between the
          two limbs, which is the one direction that cannot collide with either of
          them. The gap past the arc scales with the text, so a large font clears
          the arc by the same visual margin a small one does instead of sitting on
          top of it.
        */
        let half = sweep / 2
        let ch = cos(half), sh = sin(half)
        let bx = startDir.0 * ch - startDir.1 * sh
        let by = startDir.0 * sh + startDir.1 * ch
        let labelRadius: CGFloat = (showArc ? radius : 0) + fontSize * 0.75 + 6
        let labelPoint = CGPoint(x: vertex.x + CGFloat(bx) * labelRadius,
                                 y: vertex.y + CGFloat(by) * labelRadius)

        drawOutlined(
            "\(Int(shown.rounded()))\u{00b0}",
            at: labelPoint,
            fontSize: fontSize,
            colour: Color(hex: fontColorHex),
            in: context
        )
    }

    /*
      A number over the video, outlined rather than shadowed.

      A drop shadow only darkens one side, so a bright figure over a bright sky
      still loses its top edge. Drawing the same glyphs in near black at eight
      offsets around the point and the coloured ones on top gives a true outline,
      which is what keeps these readable over grass, sky and a white shirt alike.
      Shared by the joint angle readouts and the foot roll labels so every number
      the overlay prints is styled the same way.
    */
    private func drawOutlined(
        _ text: String,
        at point: CGPoint,
        fontSize: CGFloat,
        colour: Color,
        in context: GraphicsContext
    ) {
        let font = Font.system(size: fontSize, weight: .bold, design: .rounded)
        let outline = context.resolve(
            Text(text).font(font).foregroundStyle(Color.black.opacity(0.85))
        )
        let ring: CGFloat = max(1, fontSize * 0.11)
        for angle in stride(from: 0.0, to: 2 * Double.pi, by: Double.pi / 4) {
            context.draw(
                outline,
                at: CGPoint(x: point.x + CGFloat(cos(angle)) * ring,
                            y: point.y + CGFloat(sin(angle)) * ring),
                anchor: .center
            )
        }
        context.draw(
            context.resolve(Text(text).font(font).foregroundStyle(colour)),
            at: point,
            anchor: .center
        )
    }

    /*
      Joints whose angle is meaningful, with the two landmarks that form the
      segments meeting there. All six joint types both sides now, so every row
      the settings sheet exposes a toggle for actually draws a number when it is
      turned on. Before, only the elbows and knees were listed, so the shoulder,
      wrist, hip and ankle toggles did nothing.

      Each vertex sits between the two named landmarks:
        shoulder   elbow to shoulder to hip   (the arm off the torso)
        elbow      shoulder to elbow to wrist
        wrist      elbow to wrist to index    (the hand off the forearm)
        hip        shoulder to hip to knee    (the thigh off the torso)
        knee       hip to knee to ankle
        ankle      knee to ankle to foot index

      The angle itself is measured in the same projected 2D space the arc is
      drawn in, by `interiorAngle` below, so the printed number always agrees with
      the sweep on screen. (The brief named a Geometry.interiorAngleDegrees
      helper; there is no such function in the codebase, and a 3D world angle
      would not match the 2D arc, so the projected measure is used instead.)
    */
    private static let angleJoints: [(JointKey, (Int, Int))] = [
        (.leftShoulder, (Landmarks.LEFT_ELBOW, Landmarks.LEFT_HIP)),
        (.rightShoulder, (Landmarks.RIGHT_ELBOW, Landmarks.RIGHT_HIP)),
        (.leftElbow, (Landmarks.LEFT_SHOULDER, Landmarks.LEFT_WRIST)),
        (.rightElbow, (Landmarks.RIGHT_SHOULDER, Landmarks.RIGHT_WRIST)),
        (.leftWrist, (Landmarks.LEFT_ELBOW, Landmarks.LEFT_INDEX)),
        (.rightWrist, (Landmarks.RIGHT_ELBOW, Landmarks.RIGHT_INDEX)),
        (.leftHip, (Landmarks.LEFT_SHOULDER, Landmarks.LEFT_KNEE)),
        (.rightHip, (Landmarks.RIGHT_SHOULDER, Landmarks.RIGHT_KNEE)),
        (.leftKnee, (Landmarks.LEFT_HIP, Landmarks.LEFT_ANKLE)),
        (.rightKnee, (Landmarks.RIGHT_HIP, Landmarks.RIGHT_ANKLE)),
        (.leftAnkle, (Landmarks.LEFT_KNEE, Landmarks.LEFT_FOOT_INDEX)),
        (.rightAnkle, (Landmarks.RIGHT_KNEE, Landmarks.RIGHT_FOOT_INDEX)),
    ]

    // Each foot's three landmarks, for the triangle and the roll angle. Ankle
    // is the apex the triangle hinges on, heel and toe are the sole line whose
    // tilt is the roll.
    private static let feet: [(ankle: Int, heel: Int, toe: Int)] = [
        (Landmarks.LEFT_ANKLE, Landmarks.LEFT_HEEL, Landmarks.LEFT_FOOT_INDEX),
        (Landmarks.RIGHT_ANKLE, Landmarks.RIGHT_HEEL, Landmarks.RIGHT_FOOT_INDEX),
    ]

    // Interior angle at b, in degrees, from the projected 2D points.
    private static func interiorAngle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Double {
        let v1 = CGPoint(x: a.x - b.x, y: a.y - b.y)
        let v2 = CGPoint(x: c.x - b.x, y: c.y - b.y)
        let dot = Double(v1.x * v2.x + v1.y * v2.y)
        let cross = Double(v1.x * v2.y - v1.y * v2.x)
        return atan2(abs(cross), dot) * 180 / .pi
    }
}

