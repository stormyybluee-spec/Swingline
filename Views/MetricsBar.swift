//
//  MetricsBar.swift
//  Swingline
//
//  The per frame metric bar, and the registry behind it.
//
//  A design note worth stating plainly. There is no metric bar in the web
//  source to port. The web FullscreenSwing takes a metrics prop and marks "Edit
//  metrics" as coming with the native app, so this is a native first feature.
//  It is built here from the real per frame series the engine already produces,
//  not invented values.
//
//  Where the numbers come from, and a correction to the brief. These cards read
//  a value that changes as the playhead moves, which means per frame data. That
//  data is not in SwingRecord, which stores only summaries. It comes from the
//  SwingSeries rebuilt from the stored frames (Biomechanics.buildSeries), which
//  is 1:1 with the frames, so series[frameIndex] lines up with what is on screen.
//  AnalysisView rebuilds it once when a swing opens and hands it in here.
//
//  The confidence dot. Green, orange or red for normal, unusual or extreme. This
//  is per frame plausibility, not swing quality: a torso turn legitimately
//  sweeps through zero at address, so a "good swing" band would paint the dot
//  red at address, which would be nonsense. Instead the dot asks whether the
//  measurement at this frame is physically plausible, the same reference range
//  idea Phase 1's bounds and scoring.js use, applied per frame. A red dot means
//  the pose almost certainly mismeasured this frame, which is the honest signal.
//
//  House rule: no em dashes anywhere.
//

import SwiftUI

// MARK: - Data the cards read from

struct MetricSource {
    let series: SwingSeries
    // Per frame turn measured from address, precomputed once via
    // series.turnFrom(P1) so the bar does not rebuild it every frame.
    let torsoTurnFromAddress: [Double]
    let pelvisTurnFromAddress: [Double]
    /*
      The camera angle this swing was filmed from, so the bar can hide the cards
      that angle cannot measure.

      Taken from the saved record's view string rather than a live SwingAnalysis,
      because this screen reads a stored SwingRecord and the analysis object is
      long gone by then. Defaults to unknown, which disables nothing.
    */
    var view: CameraViewKind = .unknown
    /*
      Swing level facts for the fixed lead cards. These are one figure for the
      whole swing rather than a per frame series, so they are passed in from the
      record rather than read out of the series.
    */
    var tempoRatio: Double? = nil
    var backswingMs: Double? = nil
    var downswingMs: Double? = nil
    var overallScore: Int? = nil
}

// MARK: - Confidence

enum MetricConfidence {
    case normal, unusual, extreme, unavailable

    var colour: Color {
        switch self {
        case .normal: return Color(red: 63 / 255, green: 217 / 255, blue: 140 / 255)   // green
        case .unusual: return Color(red: 240 / 255, green: 182 / 255, blue: 77 / 255)   // amber
        case .extreme: return Color(red: 224 / 255, green: 90 / 255, blue: 58 / 255)    // red
        case .unavailable: return Tok.bone3
        }
    }
}

// MARK: - A metric definition

struct SwingMetric: Identifiable {
    let id: String
    let label: String
    // Reads the display domain value at a frame, or nil when unavailable.
    let read: (MetricSource, Int) -> Double?
    // Formats the value for the card, unit included.
    let format: (Double) -> String
    // Optional directional word, like CLOSED or OPEN for a turn.
    let direction: ((Double) -> String)?
    // Physical plausibility ranges for the confidence dot.
    let normal: ClosedRange<Double>
    let unusual: ClosedRange<Double>
    /*
      An estimate rather than a measurement. Its card is driven by a model, so
      its confidence dot reflects how well the body was tracked, not whether the
      value sits in a plausible range, and a zero reads as unavailable.
    */
    var estimated: Bool = false

    func confidence(_ value: Double) -> MetricConfidence {
        if normal.contains(value) { return .normal }
        if unusual.contains(value) { return .unusual }
        return .extreme
    }
}

// MARK: - The registry

enum SwingMetrics {

    static let all: [SwingMetric] = [
        SwingMetric(
            id: "torsoTurn",
            label: "Torso Turn",
            read: { src, i in src.torsoTurnFromAddress.indices.contains(i) ? src.torsoTurnFromAddress[i] : nil },
            format: { String(format: "%.0f\u{00b0}", abs($0)) },
            direction: { $0 >= 0 ? "CLOSED" : "OPEN" },
            normal: -20...120,
            unusual: -35...140
        ),
        SwingMetric(
            id: "pelvisTurn",
            label: "Pelvis Turn",
            read: { src, i in src.pelvisTurnFromAddress.indices.contains(i) ? src.pelvisTurnFromAddress[i] : nil },
            format: { String(format: "%.0f\u{00b0}", abs($0)) },
            direction: { $0 >= 0 ? "CLOSED" : "OPEN" },
            normal: -15...80,
            unusual: -30...95
        ),
        SwingMetric(
            id: "xFactor",
            label: "X-Factor",
            read: { src, i in src.series.xFactor.indices.contains(i) ? src.series.xFactor[i] : nil },
            format: { String(format: "%.0f\u{00b0}", $0) },
            direction: nil,
            normal: -25...70,
            unusual: -40...85
        ),
        SwingMetric(
            id: "spineTilt",
            label: "Spine Tilt",
            read: { src, i in src.series.spineTilt.indices.contains(i) ? src.series.spineTilt[i] : nil },
            format: { String(format: "%.0f\u{00b0}", $0) },
            direction: nil,
            normal: 5...55,
            unusual: 0...70
        ),
        SwingMetric(
            id: "leadElbow",
            label: "Lead Elbow",
            read: { src, i in src.series.leadElbowAngle.indices.contains(i) ? src.series.leadElbowAngle[i] : nil },
            format: { String(format: "%.0f\u{00b0}", $0) },
            direction: nil,
            normal: 80...180,
            unusual: 45...185
        ),
        SwingMetric(
            id: "trailKnee",
            label: "Trail Knee",
            read: { src, i in src.series.trailKneeFlex.indices.contains(i) ? src.series.trailKneeFlex[i] : nil },
            format: { String(format: "%.0f\u{00b0}", $0) },
            direction: nil,
            normal: 110...180,
            unusual: 80...185
        ),
        SwingMetric(
            id: "handSpeed",
            label: "Hand Speed",
            read: { src, i in src.series.handSpeed.indices.contains(i) ? src.series.handSpeed[i] : nil },
            format: { String(format: "%.1f m/s", $0) },
            direction: nil,
            normal: 0...40,
            unusual: 0...60
        ),
        SwingMetric(
            id: "pressure",
            label: "Lead Pressure",
            read: { src, i in src.series.pressure.indices.contains(i) ? src.series.pressure[i] * 100 : nil },
            format: { String(format: "%.0f%%", $0) },
            direction: nil,
            normal: 0...100,
            unusual: 0...100
        ),
        // Stability metrics (Task 2.C). These read per swing scalars that are
        // filled by SwingSeries.fillStability once phases exist, so they read as
        // unavailable until that call is wired, rather than showing a made up
        // number. The read closures ignore the frame index because the value is
        // one figure for the whole swing.
        SwingMetric(
            id: "pelvisLift",
            label: "Pelvis Lift",
            read: { src, _ in src.series.normalizedPelvisLift },
            format: { String(format: "%.1f%%", $0) },
            direction: { $0 > 0 ? "EARLY EXT" : "SQUAT" },
            normal: -5.0...2.0,
            unusual: -10.0...5.0
        ),
        SwingMetric(
            id: "pelvisSway",
            label: "Pelvis Sway",
            read: { src, _ in src.series.normalizedPelvisSway },
            format: { String(format: "%.1f%%", $0) },
            direction: { $0 > 0 ? "TOWARD" : "AWAY" },
            normal: -12.0...12.0,
            unusual: -20.0...20.0
        ),
        SwingMetric(
            id: "torsoLift",
            label: "Torso Lift",
            read: { src, _ in src.series.normalizedTorsoLift },
            format: { String(format: "%.1f%%", $0) },
            direction: nil,
            normal: -5.0...5.0,
            unusual: -10.0...10.0
        ),
        SwingMetric(
            id: "leverRelease",
            label: "Lever Release",
            read: { src, _ in src.series.leverArmReleaseRatio },
            format: { String(format: "%.1fx", $0) },
            direction: nil,
            normal: 2.5...4.0,
            unusual: 1.5...5.0
        ),
        // Phase 3 metrics. Flight efficiency reads a fitted ball trajectory
        // (nil until a ball is tracked); the wrist proxies read the per frame
        // series. All three are depth sensitive and hidden down the line.
        SwingMetric(
            id: "flightEfficiency",
            label: "Flight Efficiency",
            read: { src, _ in src.series.flightEfficiency },
            format: { String(format: "%.1f", $0) },
            direction: nil,
            normal: 3.0...4.5,
            unusual: 2.0...5.5
        ),
        SwingMetric(
            id: "wristFlex",
            label: "Wrist Flex",
            read: { src, i in src.series.leadWristFlexion.indices.contains(i) ? src.series.leadWristFlexion[i] : nil },
            format: { String(format: "%.0f\u{00b0}", $0) },
            direction: { $0 > 0 ? "BOWED" : "CUPPED" },
            normal: -10.0...15.0,
            unusual: -20.0...25.0
        ),
        SwingMetric(
            id: "wristDeviation",
            label: "Wrist Deviation",
            read: { src, i in src.series.leadWristDeviation.indices.contains(i) ? src.series.leadWristDeviation[i] : nil },
            format: { String(format: "%.0f\u{00b0}", $0) },
            direction: { $0 > 0 ? "RADIAL" : "ULNAR" },
            normal: -10.0...10.0,
            unusual: -20.0...20.0
        ),
        // Phase 3.5A ball flight estimates. Club average models driven by hand
        // speed at impact, so they carry the estimated flag: shown labelled Est.
        // with a pose confidence dot rather than a plausibility dot.
        SwingMetric(
            id: "ballSpeedEst",
            label: "Ball Speed (Est.)",
            read: { src, _ in src.series.ballSpeedEstimate },
            format: { String(format: "%.0f mph", $0 * 2.237) },
            direction: nil,
            normal: 120...180,
            unusual: 80...200,
            estimated: true
        ),
        SwingMetric(
            id: "carryEst",
            label: "Carry (Est.)",
            read: { src, _ in src.series.carryDistanceEstimate },
            format: { String(format: "%.0f yds", $0 * 1.094) },
            direction: nil,
            normal: 150...300,
            unusual: 100...350,
            estimated: true
        ),
        SwingMetric(
            id: "launchAngleEst",
            label: "Launch (Est.)",
            read: { src, _ in src.series.launchAngleEstimate },
            format: { String(format: "%.0f\u{00b0}", $0) },
            direction: nil,
            normal: 8...16,
            unusual: 5...25,
            estimated: true
        ),
        SwingMetric(
            id: "spinRateEst",
            label: "Spin (Est.)",
            read: { src, _ in Double(src.series.spinRateEstimate) },
            format: { String(format: "%.0f rpm", $0) },
            direction: nil,
            normal: 2000...8000,
            unusual: 1000...12000,
            estimated: true
        ),
    ]

    /*
      The fixed lead cards, always shown first in this order. They read swing
      level facts off MetricSource rather than a per frame series, so their read
      closure ignores the frame index.
    */
    static let lead: [SwingMetric] = [
        SwingMetric(
            id: "tempo",
            label: "Tempo",
            read: { src, _ in src.tempoRatio },
            format: { String(format: "%.1f to 1", $0) },
            direction: { _ in "BACK TO DOWN" },
            normal: 2.5...3.5,
            unusual: 1.8...4.5
        ),
        SwingMetric(
            id: "backswingMs",
            label: "Backswing",
            read: { src, _ in src.backswingMs },
            format: { String(format: "%.0f ms", $0) },
            direction: nil,
            normal: 600...900,
            unusual: 400...1200
        ),
        SwingMetric(
            id: "downswingMs",
            label: "Downswing",
            read: { src, _ in src.downswingMs },
            format: { String(format: "%.0f ms", $0) },
            direction: nil,
            normal: 250...350,
            unusual: 150...500
        ),
        SwingMetric(
            id: "score",
            label: "Score",
            read: { src, _ in src.overallScore.map(Double.init) },
            format: { String(format: "%.0f", $0) },
            direction: nil,
            normal: 60...100,
            unusual: 30...100
        ),
    ]

    static let leadIDs: Set<String> = Set(lead.map(\.id))

    /*
      Always First: the eight cards that lead every layout and cannot be moved or
      removed. The first four are the swing level lead cards; the next four are
      the measurements a coach reaches for first. Torso and pelvis turn are here
      even though a down the line clip cannot measure them, in which case they
      read "camera angle", the same as anywhere else.
    */
    static let alwaysFirstIDs: [String] = [
        "tempo", "backswingMs", "downswingMs", "score",
        "handSpeed", "pressure", "torsoTurn", "pelvisTurn",
    ]
    static var alwaysFirst: [SwingMetric] { alwaysFirstIDs.compactMap { metric($0) } }
    static let alwaysFirstSet: Set<String> = Set(alwaysFirstIDs)

    // What a new golfer sees on the first customisable page, the registry metrics
    // that are not already locked into Always First.
    static let defaultBar1: [String] = ["spineTilt", "leadElbow", "trailKnee", "xFactor"]

    /*
      The six the analysis screen always shows, three by two, in this order. Not
      configurable: these are what a coach reads first, and a fixed block is
      easier to scan than a list that moves between swings.
    */
    static let fixedGridIDs: [String] = ["torsoTurn", "pelvisTurn", "xFactor", "pressure", "handSpeed", "tempo"]
    static var fixedGrid: [SwingMetric] { fixedGridIDs.compactMap { metric($0) } }

    /*
      What a new golfer sees after the lead four. Deliberately not the rotation
      family alone: those are hidden down the line, which used to leave the bar
      almost empty. Hand speed and pressure are measurable from either angle.
    */
    static let defaults: [String] = ["handSpeed", "pressure", "torsoTurn", "spineTilt"]

    // Searches the lead cards too, so ids like tempo resolve even though they
    // are not in the selectable registry.
    static func metric(_ id: String) -> SwingMetric? {
        all.first { $0.id == id } ?? lead.first { $0.id == id }
    }
}

// MARK: - The bar

/*
  How tall a metric page actually is.

  The paged layout used to be pinned to a guessed 150pt with the grid top
  aligned inside it, which left a band of dead space under the second row and
  pushed the transport further down the screen than it needed to be. Each page
  reports its natural height through this key instead, and the tallest one sets
  the frame, so the layout stays correct when the card text grows with Dynamic
  Type rather than being right at one text size and wrong at the others.
*/
private struct MetricPageHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct MetricsBar: View {
    let source: MetricSource
    let frameIndex: Int
    // Ordered, so the bar honours the arrangement from the picker.
    let selected: [String]
    // The second customisable page, used only by the paged fullscreen layout.
    var bar2: [String] = []
    /*
      How the bar lays out.

      .scroll is the fullscreen strip, the golfer's chosen metrics in their order.
      .grid is the analysis screen: a fixed three by two block of the six a coach
      reads first, which does not scroll and does not change.
      .pages is the swipeable fullscreen layout: Always First, then the two
      customisable pages, one per swipe.
    */
    enum Layout { case scroll, grid, grid2x4, pages }
    var layout: Layout = .scroll

    // The measured height of the tallest page, and what the paged layout adds on
    // top of it: the page dots sit inside the TabView's bounds, so without an
    // allowance they would print over the bottom row of cards. The floor keeps
    // the frame sane on the first pass, before anything has been measured.
    @State private var pageHeight: CGFloat = 0
    private static let pageDotsSpace: CGFloat = 26
    private static let pageHeightFloor: CGFloat = 84
    /* The shape of one swipeable page. Held here rather than written into the
       grid so the padding that keeps every page two rows tall and the grid it
       pads can never disagree about how many cells a page has. */
    private static let columnsPerPage = 4
    private static let rowsPerPage = 2

    // Registry order, filtered to the chosen ones, so the bar order is stable,
    // then minus anything this camera angle cannot honestly measure. Hiding a
    // card the angle cannot see is the point: a greyed number still reads as a
    // measurement, an absent one does not.
    /*
      The lead cards always come first, then the golfer's chosen metrics.

      The lead four are swing level facts (tempo, the two phase durations and the
      score) that every swing has and no camera angle can invalidate, so they are
      never gated and never reordered. Everything after them is the selection,
      minus anything this camera angle cannot honestly measure.

      This also fixes a real bug. The defaults used to be the rotation family
      plus spine tilt, and down the line gates the rotation family, so a down the
      line swing showed exactly one card.
    */
    private var metrics: [SwingMetric] {
        let disabled = MetricsBar.disabledMetricIDs(for: source.view)
        // Walk the golfer's order, not the registry's, so dragging a card in the
        // picker actually moves it here. Unknown ids from an older build are
        // skipped rather than crashing the bar.
        let chosen = selected.compactMap { id -> SwingMetric? in
            guard !disabled.contains(id), !SwingMetrics.leadIDs.contains(id) else { return nil }
            return SwingMetrics.metric(id)
        }
        return SwingMetrics.lead + chosen
    }

    var body: some View {
        switch layout {
        case .scroll:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Tok.s3) {
                    ForEach(metrics) { metric in
                        card(metric)
                    }
                }
                .padding(.horizontal, 2)
            }
        case .grid:
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Tok.s2), count: 3),
                spacing: Tok.s2
            ) {
                ForEach(SwingMetrics.fixedGrid) { metric in
                    card(metric, fill: true)
                }
            }
        case .grid2x4:
            // Two rows of four, compact, so the fullscreen viewer shows eight
            // metrics without scrolling. Uses the ordered selection, lead first.
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Tok.s2), count: 4),
                spacing: Tok.s2
            ) {
                ForEach(Array(metrics.prefix(8))) { metric in
                    card(metric, fill: true, compact: true)
                }
            }
        case .pages:
            // Three swipeable pages: Always First, then the two custom bars. Each
            // page is its own compact strip, dots below mark which one is showing.
            TabView {
                pageStrip(SwingMetrics.alwaysFirst)
                pageStrip(selected.compactMap { SwingMetrics.metric($0) })
                pageStrip(bar2.compactMap { SwingMetrics.metric($0) })
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .never))
            .frame(height: max(pageHeight, Self.pageHeightFloor) + Self.pageDotsSpace)
            .onPreferenceChange(MetricPageHeightKey.self) { height in
                // Guarded so a sub pixel report cannot bounce the frame back and
                // forth on every layout pass.
                guard height > 0, abs(height - pageHeight) > 0.5 else { return }
                pageHeight = height
            }
        }
    }

    // One page of the swipeable layout: a compact grid of up to eight cards, or a
    // quiet note when that page has nothing on it yet.
    @ViewBuilder
    private func pageStrip(_ items: [SwingMetric]) -> some View {
        Group {
            if items.isEmpty {
                Text("Nothing on this page yet")
                    .font(.body(TypeScale.small))
                    .foregroundStyle(Tok.bone3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Tok.s4)
            } else {
                /*
                  Always two rows, whatever is on the page.

                  With four columns a page holding one to four metrics laid out as
                  a single row, which made this page shorter than its neighbours.
                  The TabView takes its height from the tallest page and centres
                  the shorter ones inside it, so one metric on bar two floated in
                  the middle of a two row box while the other pages sat at the top.
                  That is the centring in the report, and it is a layout artefact
                  rather than a choice anyone made.

                  Padding the page out to a full second row with invisible cards
                  fixes it at the source: every page is genuinely two rows tall, so
                  they all report the same height and there is nothing left to
                  centre. The placeholders are real cards at zero opacity rather
                  than blank rectangles, so they occupy exactly the height a card
                  occupies and cannot drift out of step with it, and they are
                  hidden from VoiceOver so nothing announces an empty slot.
                */
                let shown = Array(items.prefix(8))
                let padded = max(0, Self.rowsPerPage * Self.columnsPerPage - shown.count)
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: Tok.s2), count: Self.columnsPerPage),
                    spacing: Tok.s2
                ) {
                    ForEach(shown) { metric in
                        card(metric, fill: true, compact: true)
                    }
                    if padded > 0, let filler = shown.first {
                        ForEach(0..<padded, id: \.self) { _ in
                            card(filler, fill: true, compact: true)
                                .opacity(0)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        }
        /*
          No maxHeight infinity and no bottom padding on purpose. Both were what
          created the empty band: the first let a page stretch to fill whatever
          height it was given, the second added a gap under the last row that the
          transport then had to sit below. Left as natural height, the page is
          exactly two rows tall and reports that upwards.
        */
        .frame(maxWidth: .infinity, alignment: .top)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: MetricPageHeightKey.self, value: proxy.size.height)
            }
        )
    }

    private func card(_ metric: SwingMetric, fill: Bool = false, compact: Bool = false) -> some View {
        // A metric this camera angle cannot measure says so, rather than showing
        // a dash that reads like a tracking failure.
        let gated = MetricsBar.disabledMetricIDs(for: source.view).contains(metric.id)
        let value = gated ? nil : metric.read(source, frameIndex)
        // An estimate reads unavailable at zero (not yet computed). Otherwise a
        // measurement uses its plausibility ranges, while an estimate shows a
        // pose confidence dot, since the value is a model, not a measurement.
        let hasValue = value != nil && !(metric.estimated && (value ?? 0) == 0)
        let confidence: MetricConfidence = {
            guard hasValue, let v = value else { return .unavailable }
            if metric.estimated {
                let c = source.series.confidence
                if c >= 0.75 { return .normal }
                if c >= 0.5 { return .unusual }
                return .extreme
            }
            return metric.confidence(v)
        }()

        // Compact card: label, value, direction word. Tightened so a row of them
        // costs little vertical space, which is what the reference layouts do.
        let isLead = SwingMetrics.leadIDs.contains(metric.id)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(metric.label.uppercased())
                    .font(.data(TypeScale.nano))
                    .tracking(0.5)
                    .foregroundStyle(Tok.bone3)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Circle()
                    .fill(confidence.colour)
                    .frame(width: 6, height: 6)
            }

            if gated {
                Text("Camera angle")
                    .font(.body(compact ? TypeScale.nano : TypeScale.small))
                    .foregroundStyle(Tok.bone3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text(hasValue ? (value.map { metric.format($0) } ?? "-") : "-")
                    .font(.data(compact ? TypeScale.small : TypeScale.body))
                    .foregroundStyle(Tok.bone)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            if !compact {
                Text(hasValue ? directionText(metric, value) : " ")
                    .font(.data(TypeScale.nano))
                    .foregroundStyle(Tok.bone2)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, compact ? 5 : (fill ? 8 : 7))
        .padding(.horizontal, compact ? 7 : (fill ? 11 : 9))
        .frame(maxWidth: fill ? .infinity : nil, alignment: .leading)
        // Narrower in the scroll strip so more cards fit at a glance. The fixed
        // grid on the analysis screen is unaffected, it uses fill.
        .frame(width: fill ? nil : 96, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous).fill(Tok.turf800))
        .overlay {
            RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                .strokeBorder(isLead ? Tok.citrusDim : Tok.line, lineWidth: 1)
        }
    }

    // A space keeps the card height stable when a metric has no direction word.
    private func directionText(_ metric: SwingMetric, _ value: Double?) -> String {
        guard let value, let direction = metric.direction else { return " " }
        return direction(value)
    }
}

// MARK: - View gated metrics (Task 1.D, data only)

extension MetricsBar {
    /*
      Which metric cards a given camera view cannot honestly measure.

      This is the physics the rest of the engine already encodes, expressed as a
      set of card ids so the UI can grey the right cards. Down the line, the
      swing runs along the camera axis and shoulder and hip width foreshorten to
      almost nothing, so the rotation family (turn and separation) is not
      measurable and is reported as camera angle, exactly as measureFundamentals
      already does. Face on sees rotation cleanly, so it disables nothing here.

      Note on the correction: an earlier draft inverted this (it disabled depth
      metrics down the line and X factor face on) and referenced metric ids that
      do not exist in this registry. Both are fixed. The ids below are the real
      ones from SwingMetric, and the direction matches the engine and the "camera
      angle" labels shown on device.
    */
    static func disabledMetricIDs(for view: CameraViewKind) -> Set<String> {
        // The rotation family, the only cards a single down the line camera
        // cannot measure from apparent width. Flight efficiency and the wrist
        // proxies are depth sensitive, so they are hidden down the line too.
        let rotationFamily: Set<String> = ["torsoTurn", "pelvisTurn", "xFactor"]
        let depthSensitive: Set<String> = ["flightEfficiency", "wristFlex", "wristDeviation"]

        switch view {
        case .downTheLine: return rotationFamily.union(depthSensitive)
        case .faceOn, .angled, .unknown: return []
        }
    }
}
