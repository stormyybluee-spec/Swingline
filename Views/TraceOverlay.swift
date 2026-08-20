//
//  TraceOverlay.swift
//  Swingline
//
//  The hand path and the estimated club head path, drawn over the video as a
//  pure function of frame index. Ported from the web TraceOverlay.jsx, with the
//  path builders from analyze.js (handPath, estimatedClubPath) and the frame
//  index machinery from trackingLayers.js, none of which had a Swift equivalent
//  yet.
//
//  The architecture is the whole point. Each path is precomputed once when the
//  swing loads, then every frame the overlay asks one question: which points
//  have happened by this frame index. That is a lookup, not an animation. So the
//  trace grows as the swing plays and shrinks exactly in step when it is
//  scrubbed back, and stepping, pausing and slow motion need no code of their
//  own. The web app rewrote this module specifically because an earlier version
//  ran its own clock and left a line on screen that had not happened yet when
//  the playbar was dragged backwards.
//
//  Colours follow the coaching convention every screen drawing already uses:
//  blue going back, red coming down, split at the top of the backswing.
//
//  WHAT THIS PASS CHANGED, AND WHY
//
//  1. BOTH TRACES STOP AT P10, THE FINISH.
//
//     The swing is over at P10. Everything after it is the golfer lowering the
//     club, stepping out of frame or walking to pick the ball up, and tracing
//     that produced a tangle of line over the finish position, which is exactly
//     the frame a golfer wants to look at. The cap is endFrame, and it is
//     applied twice on purpose: the frame index the series is asked about is
//     clamped to it, and any point that still comes back past it is filtered
//     out. Belt and braces, because the two protect against different failures.
//     Clamping alone breaks if the caller built the series past P10, and
//     filtering alone leaves the leading marker sitting on the wrong point.
//
//     Past P10 the trace does not vanish, it freezes. The full swing path stays
//     on the finish frame, which is what a coach draws on a still. Vanishing at
//     the exact moment the swing completes would take the drawing away at the
//     moment it is most useful.
//
//     endFrame nil means no cap, so any caller that does not know its P10 gets
//     the old behaviour rather than an empty overlay.
//
//  2. THE CLUB HEAD PATH IS SOLID, NOT DASHED.
//
//     It used to be dashed to say "this is an estimate, projected from the lead
//     forearm through the hands, not a detection". That honesty still matters,
//     so it did not just get deleted: it moved to the layer label, where the row
//     that switches the line on now says the line is estimated. A dash pattern
//     is a poor carrier for that claim anyway, since most golfers read a dashed
//     line as a style choice rather than as a confidence statement, and it read
//     as broken tracking rather than as an estimate.
//
//     The club path now takes the same weight and the same two colours as the
//     hand path, so the two read as one drawing of one swing.
//
//  House rule: no em dashes anywhere.
//

import SwiftUI
import Foundation

// MARK: - Overlay

struct TraceOverlay: View {
    let handSeries: FrameSeries?
    let clubSeries: FrameSeries?
    let frameIndex: Int
    var topFrame: Int? = nil
    /*
      P10, the finish, and the last frame any trace here is allowed to reach.

      Nil means draw to the end of the clip, which is what every caller did
      before this parameter existed, so an old call site is unchanged rather
      than blank.
    */
    var endFrame: Int? = nil
    var mirrored: Bool = false
    /*
      Extra joints to trace, by landmark index, honouring the per joint "Track
      joint" toggle from the skeleton sheet. Their paths are built here from the
      stored frames up to the current frame, so they stay a pure function of the
      one frame index like everything else. Empty by default, so the fullscreen
      viewer and any other caller are unaffected.
    */
    var frames: [Frame] = []
    var trackedLandmarks: [Int] = []
    var traceWidth: CGFloat = 3
    /*
      A fitted ball flight, normalised image points, drawn after the hand and
      club traces. Nil unless a ball was actually tracked and fitted, so this is
      a dormant hook until detection exists, and it never draws an invented
      flight.
    */
    var ballTrajectory: [CGPoint]? = nil

    // From COLOURS in TraceOverlay.jsx.
    private let backswing = Color(red: 77 / 255, green: 166 / 255, blue: 255 / 255)  // #4da6ff
    private let downswing = Color(red: 1, green: 59 / 255, blue: 48 / 255)           // #ff3b30

    // Side colours for per-joint traces, fixed by landmark index and nothing
    // else. Left blue, right red, the same two values the skeleton uses. A
    // joint's colour must not depend on occlusion, confidence or swing phase,
    // so these are looked up straight from the index, never from the
    // backswing/downswing pair, which those two carry a different meaning
    // (time, not side) and reusing them for joints was the colour drift the
    // report saw through Phase 5.
    private let leftJoint = Color(red: 77 / 255, green: 166 / 255, blue: 255 / 255)   // #4da6ff
    private let rightJoint = Color(red: 1, green: 59 / 255, blue: 48 / 255)           // #ff3b30

    /// MediaPipe body landmarks are odd on the left (11, 13, 15, ...) and
    /// even on the right (12, 14, 16, ...) from index 11 up. Below 11 are
    /// face points, which these traces never draw, so the parity rule is
    /// safe here.
    private func isLeftJoint(_ index: Int) -> Bool { index % 2 == 1 }
    private func sideColour(_ index: Int) -> Color { isLeftJoint(index) ? leftJoint : rightJoint }

    /*
      One weight for both swing paths.

      The club path used to be drawn a point heavier than the hand path, which
      on top of the dash pattern made it look like a different kind of thing.
      Same weight, same colours, same joins: one drawing.
    */
    private let pathWidth: CGFloat = 3

    /*
      The frame every trace here is actually drawn at.

      This is the single place the finish cap is applied to the clock, so no
      drawing routine below has to remember it.
    */
    private var drawIndex: Int {
        guard let endFrame else { return frameIndex }
        return min(frameIndex, endFrame)
    }

    var body: some View {
        Canvas { context, size in
            draw(handSeries, in: context, size: size, width: pathWidth)
            draw(clubSeries, in: context, size: size, width: pathWidth)
            for landmark in trackedLandmarks {
                drawJoint(landmark, in: context, size: size)
            }
            drawBallTrajectory(in: context, size: size)
        }
        .allowsHitTesting(false)
    }

    /*
      The fitted ball flight, a bright line over a dark underlay so it reads on
      sky or grass. Post impact only, since that is all a flight can be, and it
      draws nothing when there is no trajectory.

      Not capped at P10, because a ball flight is by definition the thing that
      happens after the strike and the trajectory is a fitted curve rather than
      a frame indexed path.
    */
    private func drawBallTrajectory(in context: GraphicsContext, size: CGSize) {
        guard let traj = ballTrajectory, traj.count >= 2 else { return }
        var path = Path()
        for (i, p) in traj.enumerated() {
            let q = CGPoint(x: (mirrored ? 1 - p.x : p.x) * size.width, y: p.y * size.height)
            if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
        }
        context.stroke(
            path,
            with: .color(.black.opacity(0.5)),
            style: StrokeStyle(lineWidth: traceWidth + 2, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            path,
            with: .color(Color(red: 1, green: 0.84, blue: 0.1)),
            style: StrokeStyle(lineWidth: traceWidth, lineCap: .round, lineJoin: .round)
        )
    }

    /*
      One tracked joint's path.

      Walks the stored frames from the start to the current frame, taking that
      landmark's normalised position where it is visible, and strokes the run.
      Coloured by side, left blue and right red, to match the skeleton. The
      leading end gets the same white marker the hand and club traces use.

      Capped at the finish for the same reason the two swing paths are. These
      lines are drawn in the same picture, so leaving them running to the end of
      the clip would put back exactly the tangle the cap was added to remove.
      Take the cap off here by using frameIndex in place of drawIndex, if a
      tracked joint should ever outlive the swing.
    */
    private func drawJoint(_ landmark: Int, in context: GraphicsContext, size: CGSize) {
        let last = min(drawIndex, frames.count - 1)
        guard last >= 0 else { return }
        var pts: [CGPoint] = []
        for i in 0...last where frames.indices.contains(i) {
            let norm = frames[i].norm
            guard norm.indices.contains(landmark) else { continue }
            let l = norm[landmark]
            let vis = l.visibility ?? l.score ?? 1
            // Lowered from 0.35 alongside the skeleton's retuned floors:
            // MediaPipe reports honest visibility and an occluded joint sits
            // in the 0.2 to 0.35 band for long stretches mid swing. Traces
            // keep a hard gate (no dimmed band) because a trace point drawn
            // from a guess stays on screen for the rest of the swing.
            guard vis >= 0.2 else { continue }
            pts.append(CGPoint(x: (mirrored ? 1 - l.x : l.x) * size.width, y: l.y * size.height))
        }
        guard pts.count >= 2 else { return }

        // Fixed by side, left blue and right red, from the index alone. Was
        // "landmark % 2 == 1 ? backswing : downswing", which reused the time
        // colours for a side decision and drifted whenever those changed.
        let colour = sideColour(landmark)
        var path = Path()
        for (i, q) in pts.enumerated() {
            if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
        }
        context.stroke(
            path,
            with: .color(.black.opacity(0.45)),
            style: StrokeStyle(lineWidth: traceWidth + 2.5, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            path,
            with: .color(colour),
            style: StrokeStyle(lineWidth: traceWidth, lineCap: .round, lineJoin: .round)
        )
        if let head = pts.last {
            let r = traceWidth + 1.5
            let dot = Path(ellipseIn: CGRect(x: head.x - r, y: head.y - r, width: r * 2, height: r * 2))
            context.fill(dot, with: .color(.white))
            context.stroke(dot, with: .color(.black.opacity(0.5)), lineWidth: 1.5)
        }
    }

    private func px(_ p: TracePoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: (mirrored ? 1 - p.x : p.x) * size.width, y: p.y * size.height)
    }

    /*
      One swing path, split at the top and stopped at the finish.

      Both the hand path and the club path come through here, which is what
      makes them identical drawings of two different point sets rather than two
      drawings that have to be kept in step by hand.
    */
    private func draw(_ series: FrameSeries?, in context: GraphicsContext, size: CGSize, width: CGFloat) {
        guard let series else { return }

        // The clock is already clamped by drawIndex. The filter is the second
        // half of the cap, for a series whose points run past the finish.
        var visible = Array(series.visible(drawIndex))
        if let endFrame {
            visible = visible.filter { $0.i <= endFrame }
        }
        guard visible.count >= 2 else { return }

        let back: [TracePoint]
        let fwd: [TracePoint]
        if let topFrame {
            back = visible.filter { $0.i <= topFrame }
            let forward = visible.filter { $0.i > topFrame }
            // The downswing run starts from the last backswing point so the two
            // colours meet at the top rather than leaving a gap.
            fwd = back.isEmpty ? forward : ([back[back.count - 1]] + forward)
        } else {
            back = visible
            fwd = []
        }

        strokeRun(back, colour: backswing, in: context, size: size, width: width)
        strokeRun(fwd, colour: downswing, in: context, size: size, width: width)

        // A marker at the leading end, so the golfer sees where the traced thing
        // is on this frame, not only where it has been. After the finish it sits
        // on the P10 point and stays there, which is the honest reading: this is
        // where the traced thing was when the swing ended.
        if let head = visible.last {
            let q = px(head, size)
            let r = width + 1.5
            let dot = Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r, width: r * 2, height: r * 2))
            context.fill(dot, with: .color(.white))
            context.stroke(dot, with: .color(.black.opacity(0.5)), lineWidth: 1.5)
        }
    }

    private func strokeRun(_ points: [TracePoint], colour: Color, in context: GraphicsContext, size: CGSize, width: CGFloat) {
        guard points.count >= 2 else { return }
        var path = Path()
        for (i, p) in points.enumerated() {
            let q = px(p, size)
            if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
        }

        // A dark underlay so a bright trace stays readable over grass and sky.
        context.stroke(
            path,
            with: .color(.black.opacity(0.45)),
            style: StrokeStyle(lineWidth: width + 2.5, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            path,
            with: .color(colour),
            style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        )
    }
}

// MARK: - A path point

public struct TracePoint {
    public var i: Int   // frame index, the clock everything maps back onto
    public var t: Double
    public var x: Double
    public var y: Double
}

// MARK: - Frame indexed series (ported from trackingLayers.js toFrameSeries)

/*
  A path normalised onto the frame clock. For every frame, upto[f] is the index
  of the last path point at or before it, so visible(f) is exactly the portion
  of the path that has happened by frame f. A point that has not happened yet is
  never drawn, which is what makes the trace grow and shrink with the playhead.
*/
public struct FrameSeries {
    public let points: [TracePoint]
    public let upto: [Int]  // length equals the frame count

    public func visible(_ frameIndex: Int) -> ArraySlice<TracePoint> {
        guard !points.isEmpty, !upto.isEmpty else { return points[0..<0] }
        let f = min(max(frameIndex, 0), upto.count - 1)
        let k = upto[f]
        return k >= 0 ? points[0...k] : points[0..<0]
    }

    /*
      The last frame this series carries a point for.

      Used as a fallback finish when the phase detector did not name a P10, so
      a swing with no detected finish still stops somewhere sensible instead of
      trailing to the end of the clip.
    */
    public var lastFrame: Int? {
        points.last?.i
    }
}

// MARK: - Building the layers (ported from analyze.js handPath / estimatedClubPath)

public enum TrackingLayers {

    // A driver sits a little over a shoulder width and a half beyond the hands.
    private static let clubInShoulders = 1.6

    public static func build(frames: [Frame], from: Int, to: Int, dominantHand: DominantHand) -> (hand: FrameSeries?, club: FrameSeries?) {
        let count = frames.count
        let hand = frameSeries(handPath(frames, from: from, to: to), frameCount: count)
        let club = frameSeries(estimatedClubPath(frames, from: from, to: to, dominantHand: dominantHand), frameCount: count)
        return (hand, club)
    }

    /*
      Hand path: the midpoint of the two wrists, which is where the hands
      actually are as a single point, and steadier than either wrist alone
      because independent tracking error on the two partly cancels when averaged.
    */
    public static func handPath(_ frames: [Frame], from: Int, to: Int) -> [TracePoint] {
        guard !frames.isEmpty else { return [] }
        let lo = max(0, from)
        let hi = min(frames.count - 1, to)
        guard hi - lo >= 4 else { return [] }

        var raw: [TracePoint] = []
        for k in lo...hi {
            let n = frames[k].norm
            guard n.count > 16 else { continue }
            let lw = n[15]
            let rw = n[16]
            // 0.4 was tuned against Vision's generous confidences. MediaPipe's
            // honest visibility dips well below that through occlusion at the
            // top and through impact blur, which cut holes in the trace. 0.2
            // matches the skeleton's retuned body floor.
            let lok = (lw.visibility ?? lw.score ?? 1) >= 0.2
            let rok = (rw.visibility ?? rw.score ?? 1) >= 0.2
            if !lok && !rok { continue }
            let x = (lok && rok) ? (lw.x + rw.x) / 2 : (lok ? lw.x : rw.x)
            let y = (lok && rok) ? (lw.y + rw.y) / 2 : (lok ? lw.y : rw.y)
            raw.append(TracePoint(i: k, t: frames[k].t, x: x, y: y))
        }
        return smooth(raw)
    }

    /*
      Estimated club head path. The club is roughly an extension of the lead
      forearm through the hands, so the direction from elbow to wrist continued
      past the hands by an estimated club length lands near the head. This is
      geometry, not detection.

      The overlay no longer says so with a dash pattern. It says so in the layer
      label instead, which is the change this pass made. The estimate itself is
      untouched: same projection, same club length model, same smoothing. If the
      line does not sit on the club head in a given clip, that is this function
      and not the drawing, and the two places it goes wrong are a mistracked
      lead elbow and a club that is not an extension of the forearm, which is
      most of the backswing on a wristy player.
    */
    public static func estimatedClubPath(_ frames: [Frame], from: Int, to: Int, dominantHand: DominantHand) -> [TracePoint] {
        guard !frames.isEmpty else { return [] }
        let leadWrist = dominantHand == .left ? 16 : 15
        let leadElbow = dominantHand == .left ? 14 : 13
        let lo = max(0, from)
        let hi = min(frames.count - 1, to)
        guard hi - lo >= 4 else { return [] }

        var raw: [TracePoint] = []
        for k in lo...hi {
            let n = frames[k].norm
            guard n.count > 16 else { continue }
            let w = n[leadWrist]
            let e = n[leadElbow]
            let ls = n[11]
            let rs = n[12]
            // Same retuned floor as the hand path above.
            if (w.visibility ?? w.score ?? 1) < 0.2 || (e.visibility ?? e.score ?? 1) < 0.2 { continue }

            let shoulderWidth = max(0.001, hypot(ls.x - rs.x, ls.y - rs.y))
            var dx = w.x - e.x
            var dy = w.y - e.y
            let len = hypot(dx, dy)
            if len < 1e-4 { continue }
            dx /= len
            dy /= len

            let reach = shoulderWidth * clubInShoulders
            raw.append(TracePoint(i: k, t: frames[k].t, x: w.x + dx * reach, y: w.y + dy * reach))
        }
        return smooth(raw)
    }

    // Smooth in the time domain, so the same real duration is covered whatever
    // rate the clip was tracked at, matching the web path builders.
    private static func smooth(_ raw: [TracePoint]) -> [TracePoint] {
        guard raw.count >= 5 else { return raw }
        let times = raw.map(\.t)
        let sx = Geometry.savitzkyGolayMs(raw.map(\.x), times, 120)
        let sy = Geometry.savitzkyGolayMs(raw.map(\.y), times, 120)
        return raw.enumerated().map { k, p in TracePoint(i: p.i, t: p.t, x: sx[k], y: sy[k]) }
    }

    private static func frameSeries(_ points: [TracePoint], frameCount: Int) -> FrameSeries? {
        guard !points.isEmpty, frameCount > 0 else { return nil }
        var upto = [Int](repeating: -1, count: frameCount)
        var k = 0
        for f in 0..<frameCount {
            while k < points.count && points[k].i <= f { k += 1 }
            upto[f] = k - 1
        }
        return FrameSeries(points: points, upto: upto)
    }
}
