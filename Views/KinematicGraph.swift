//
//  KinematicGraph.swift
//  Swingline
//
//  The kinematic sequence, drawn with Swift Charts. Four segment speeds, the
//  phase lines that bracket the downswing, and a playhead locked to the video.
//
//  What it plots, and a correction to the brief. The four speed curves are not
//  in SwingRecord.sequence, which stores only the peak order, whether it was
//  correct, and the gaps between peaks. The curves come from the SwingSeries
//  rebuilt from the stored frames: pelvisSpeed, torsoSpeed, armSpeed and
//  handSpeed, which the engine maps to pelvis, torso, arm and club (the hands
//  stand in for the club head). SwingRecord.phases supplies P3, P4, P5 and P7,
//  and SwingRecord.sequence still supplies the order summary shown beneath.
//
//  Each segment is normalised to its own peak, which is the kinematic sequence
//  convention: the shape and the order of the peaks is the coaching point, not
//  the absolute speeds, which are on very different scales. In a good swing the
//  peaks step left to right, hips then chest then arm then club, and the picture
//  looks like a staircase.
//
//  The playhead is the same frameIndex everything else reads, so it stays locked
//  to the video and the overlays. Dragging it scrubs, because the x axis is the
//  frame index directly, so a position on the graph maps straight to a frame.
//
//  House rule: no em dashes anywhere.
//

import SwiftUI
import Charts

// MARK: - Plot data

struct GraphPoint: Identifiable {
    let x: Int
    let y: Double
    var id: Int { x }
}

struct GraphLine: Identifiable {
    let id: String
    let name: String
    let colour: Color
    let points: [GraphPoint]
}

struct PhaseMark: Identifiable {
    let label: String
    let index: Int
    var id: String { label }
}

// MARK: - Graph

struct KinematicGraph: View {
    let lines: [GraphLine]
    let phaseMarks: [PhaseMark]
    let frameCount: Int
    let playback: PlaybackState
    /*
      The frames actually plotted, absolute indices into the clip.

      The kinematic sequence is a downswing event. Plotting the whole clip put
      the entire staircase into the last fifth of the axis, squashed flat, which
      is what made the order unreadable and the spacing look wrong. Windowing to
      top through impact gives the peaks the full width, which is the only way
      the order reads at a glance.

      Nil falls back to the whole clip, so a swing with no phase data still draws
      rather than disappearing.
    */
    var window: ClosedRange<Int>? = nil

    // Segment colours, per the brief: pelvis blue, torso magenta, arm orange,
    // club green.
    static let pelvis = Color(red: 77 / 255, green: 166 / 255, blue: 255 / 255)
    static let torso = Color(red: 201 / 255, green: 140 / 255, blue: 217 / 255)
    static let arm = Color(red: 242 / 255, green: 160 / 255, blue: 77 / 255)
    static let club = Color(red: 63 / 255, green: 217 / 255, blue: 140 / 255)

    private var maxX: Int { max(1, frameCount - 1) }

    // The plotted span. Absolute frame indices throughout, so the playhead and
    // the phase rules keep landing on the right place without conversion.
    private var xDomain: ClosedRange<Int> {
        guard let window, window.lowerBound < window.upperBound else { return 0...maxX }
        return window
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.s2) {
            chart
                .frame(height: 190)
            legend
        }
        .padding(Tok.s3)
        .background(RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous).fill(Tok.ink))
        .overlay {
            RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                .strokeBorder(Tok.line, lineWidth: 1)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(lines) { line in
                ForEach(line.points) { point in
                    LineMark(
                        x: .value("Frame", point.x),
                        y: .value("Speed", point.y)
                    )
                    .foregroundStyle(by: .value("Segment", line.name))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }

            // Phase boundaries, dashed, labelled above the plot.
            ForEach(phaseMarks) { mark in
                RuleMark(x: .value("Frame", mark.index))
                    .foregroundStyle(Tok.lineStrong)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .center, spacing: 0) {
                        Text(mark.label)
                            .font(.data(TypeScale.nano))
                            .foregroundStyle(Tok.bone3)
                    }
            }

            // The playhead, locked to the same frame index as the video.
            RuleMark(x: .value("Frame", playback.frameIndex))
                .foregroundStyle(Tok.bone)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartForegroundStyleScale([
            "Pelvis": Self.pelvis,
            "Torso": Self.torso,
            "Arm": Self.arm,
            "Club": Self.club,
        ])
        .chartLegend(.hidden)
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...1.08)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine().foregroundStyle(Tok.line)
                AxisTick().foregroundStyle(Tok.line)
                AxisValueLabel()
                    .font(.data(TypeScale.nano))
                    .foregroundStyle(Tok.bone3)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0.0, 0.5, 1.0]) { _ in
                AxisGridLine().foregroundStyle(Tok.line)
                AxisValueLabel()
                    .font(.data(TypeScale.nano))
                    .foregroundStyle(Tok.bone3)
            }
        }
        .chartPlotStyle { plotArea in
            plotArea.background(Tok.ink)
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                // plotFrame replaces plotAreaFrame, deprecated in
                                // iOS 17. It is optional where the old one was not,
                                // so it is unwrapped; a nil plot frame means the
                                // chart has not laid out yet and the drag is
                                // ignored for that event.
                                guard let plotAnchor = proxy.plotFrame else { return }
                                let plot = geo[plotAnchor]
                                let xInPlot = value.location.x - plot.origin.x
                                if let frame = proxy.value(atX: xInPlot, as: Int.self) {
                                    // Scrubbing the graph pauses and moves the one
                                    // clock everything else follows.
                                    playback.pause()
                                    playback.seek(toFrame: frame)
                                }
                            }
                    )
            }
        }
    }

    private var legend: some View {
        HStack(spacing: Tok.s4) {
            ForEach(lines) { line in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(line.colour)
                        .frame(width: 12, height: 3)
                    Text(line.name)
                        .font(.data(TypeScale.nano))
                        .foregroundStyle(Tok.bone2)
                }
            }
        }
    }
}

// MARK: - Building the lines

extension KinematicGraph {

    /*
      Build the four curves over a frame window.

      Two things changed here, and both were causing the graph to misreport the
      sequence.

      The window. The curves are now plotted from the top of the backswing to
      just past impact, rather than across the whole clip. The sequence is a
      downswing event lasting roughly a quarter of a second, so on a full clip
      axis it was compressed into a narrow band on the right where no order was
      visible.

      The normaliser. Each curve is scaled to its own peak WITHIN the window, not
      across the whole clip. Scaling to a whole clip peak let a backswing peak
      set the scale, which pushed the downswing peak down the axis and made a
      correctly ordered sequence look wrong. Peak height is not the coaching
      point, the order and spacing of the peaks is, so each curve is normalised
      to the move being examined.

      from and to are absolute frame indices and are clamped, so a missing or
      malformed phase index degrades to the whole clip instead of crashing.
    */
    static func build(series: SwingSeries, from: Int? = nil, to: Int? = nil) -> [GraphLine] {
        let n = series.n
        guard n > 1 else { return [] }
        let lo = min(max(from ?? 0, 0), n - 1)
        let hi = min(max(to ?? (n - 1), lo + 1), n - 1)
        guard hi > lo else { return [] }
        let range = lo...hi
        return [
            normalised(id: "pelvis", name: "Pelvis", colour: pelvis, values: series.pelvisSpeed, range: range),
            normalised(id: "torso", name: "Torso", colour: torso, values: series.torsoSpeed, range: range),
            normalised(id: "arm", name: "Arm", colour: arm, values: series.armSpeed, range: range),
            normalised(id: "club", name: "Club", colour: club, values: series.handSpeed, range: range),
        ]
    }

    /*
      The window to plot, from the phase indices.

      Top through impact, with a short tail past impact because the club peaks at
      or just after the ball and clipping exactly at impact hides the very peak
      the graph exists to show. The tail is a fraction of the downswing, so it
      scales with tempo instead of being a fixed frame count that means different
      things at different frame rates.
    */
    static func window(topIndex: Int?, impactIndex: Int?, frameCount: Int) -> ClosedRange<Int>? {
        guard frameCount > 1, let top = topIndex, let impact = impactIndex, impact > top else { return nil }
        let tail = max(2, Int(Double(impact - top) * 0.35))
        let lo = max(0, top)
        let hi = min(frameCount - 1, impact + tail)
        guard hi > lo else { return nil }
        return lo...hi
    }

    private static func normalised(id: String, name: String, colour: Color, values: [Double], range: ClosedRange<Int>) -> GraphLine {
        let inWindow = range.compactMap { values.indices.contains($0) ? values[$0] : nil }
        let peak = max(1e-6, inWindow.max() ?? 1)
        let points = range.map { i in
            GraphPoint(x: i, y: (values.indices.contains(i) ? values[i] : 0) / peak)
        }
        return GraphLine(id: id, name: name, colour: colour, points: points)
    }
}
