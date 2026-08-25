//
//  AnalysisView.swift
//  Swingline
//
//  Analysis. Hosts the kinematic sequence graph, the split screen playback stack,
//  the transport controls, and the per frame metric bar, all driven by one
//  PlaybackState frame clock, above the scores.
//
//  Layout, top to bottom: the kinematic graph, then the split screen (the 3D
//  segmented figure on top, the video with the 2D skeleton and traces below it),
//  then one shared set of transport controls, then the metric bar, then the
//  category scores. Every panel reads the same frameIndex, so scrubbing anywhere
//  moves all of them together. There is still exactly one clock.
//
//  WHAT PHASE 4 STEP 10 ADDED
//
//  The 3D panel, and with it a second reading of the same data. The 2D overlay
//  draws frames[i].norm, which is image space. The 3D figure draws
//  frames[i].world, which is metric space. One clock, two coordinate systems,
//  both a pure function of the same integer.
//
//  Why that matters rather than being a party trick: most rotation faults are
//  invisible from the angle people naturally film from. A golfer who filmed face
//  on can turn the figure to down the line and see the swing plane they could not
//  see in their own footage.
//
//  WHAT THE 3D PANEL CANNOT SHOW, STATED HERE SO IT IS NOT DISCOVERED AS A BUG
//
//  World landmarks are hip relative, so the hip centre is the origin on every
//  frame. The figure turns and the limbs move, but the body never translates.
//  Pelvis sway and pelvis lift are therefore invisible in this panel by
//  construction, in this build and in the web build equally. They are read in the
//  metric bar, which is why the metric bar sits directly beneath.
//
//  THE TEMPORARY BIT
//
//  Skeleton3DSettings is a local @Observable so the joint marker style can be
//  toggled on device right now. Phase 5 keeps it, because the joint style genuinely
//  is a 3D only setting with no home in the 2D overlay, and now also reads its
//  default from AppSettings so a choice made in Settings carries into a new
//  analysis. The 3D panel already reads dominantHand from the real settings,
//  because lead and trail would otherwise be wrong for a left handed golfer.
//
//  WHAT PHASE 5 ADDED HERE
//
//  The overflow menu, mirroring the web FullscreenSwing "more" popover: Share,
//  Download, then the four the web build stubbed as "Coming with the native app",
//  now real: Record this screen (ReplayKit), Trim, Mirror and Rotate video
//  (AVFoundation). Plus the PencilKit annotation layer over the video panel, with
//  its ink persisted on the swing.
//
//  The overlays now read the golfer's settings rather than fixed values: which
//  side is mirrored follows cameraFacing, and the joint style follows the stored
//  default. This is the Step 9 wiring on the analysis side.
//
//  WHAT THE LAST PASS ADDED
//
//  1. The layer plus menu, next to More metrics on the viewport bar. The five
//     overlay toggles were only reachable once you were already inside the
//     fullscreen viewer, which meant leaving the screen to turn off a line you
//     were looking at. They are bound to the same five pieces of state the
//     fullscreen dropdown drives, so the two menus are two doors into one room
//     and a layer switched off in either stays off in the other.
//
//  2. The firing order graph, above the existing text reading in the full
//     breakdown. The text says which order the segments peaked in. The graph says
//     by how much and how close together, which is the part a list cannot carry.
//     The text reading is untouched and still sits underneath it.
//
//  WHAT THIS PASS ADDED
//
//  1. finishFrame, which is P10. It is handed to both trace overlays, here and
//     in the fullscreen viewer, so the hand path and the club head path stop at
//     the finish rather than carrying on while the golfer lowers the club.
//
//  2. The ball flight gate. The layer is not finished, so it is a beta founder
//     flag away from being drawn at all. Because this screen and the fullscreen
//     viewer share one showBallFlight, the gate had to be applied in both, and
//     in both it is applied twice: the row refuses to turn on, and the overlay
//     refuses to draw. Gating only the fullscreen row would have left this menu
//     as a way around it, which is the kind of hole that ships.
//
//  3. Trim moved into the fullscreen viewer, which now picks the range and hands
//     it back through onTrimRange. The re export still runs here, because
//     swapping one clip for another means touching the store and the store is
//     not visible from in there.
//
//  House rule: no em dashes anywhere.
//

import SwiftUI
import PencilKit
import AVKit
import Charts

// MARK: - Temporary 3D settings

/*
  Phase 5 deletes this.

  It exists so the joint marker style and the appearance toggles can be driven
  from the panel itself while the 3D view is being looked at on a real device.
  Everything here has a home in AppSettings later. Nothing else in the app reads
  it, so removing it is a local change.
*/
@MainActor
@Observable
final class Skeleton3DSettings {
    var jointColorStyle: JointColorStyle = .dual
    var showTraces: Bool = true
    var showGrid: Bool = true
    var isUnlocked: Bool = false
    var paletteName: String = "blockout"

    var palette: HumanoidPalette {
        switch paletteName {
        case "bone": return .bone
        default: return .blockout
        }
    }

    static let paletteOptions: [(id: String, label: String)] = [
        (id: "blockout", label: "Blocks"),
        (id: "bone", label: "Bone"),
    ]
}

// MARK: - Firing order graph model

/*
  The four segment speed curves, windowed to the downswing and reduced to just
  what the chart draws.

  Built once per swing in loadSwing rather than per render, because the shape of
  the sequence does not change while you look at it. Each curve is scaled to its
  own peak, so every peak dot lands on the same line and the eye reads the one
  thing that matters here, which is the horizontal spacing of the dots. Scaling
  all four against a shared maximum would bury the pelvis curve under the hands,
  and the order would be the hardest thing on the chart to see rather than the
  easiest.
*/
private struct SequencePoint {
    let frame: Int
    let value: Double
}

private struct SequenceCurve: Identifiable {
    let id: String
    let label: String
    let colour: Color
    let points: [SequencePoint]
}

private struct SequencePeakMark: Identifiable {
    let id: String
    let colour: Color
    let frame: Int
    let value: Double
    let rank: Int
}

private struct SequenceChartData {
    var curves: [SequenceCurve] = []
    var peaks: [SequencePeakMark] = []
    var span: Int = 0
}

/*
  The chart itself.

  X runs from the top of the backswing to impact, in frames, because that is the
  only window where the firing order means anything. Y is peak relative speed. The
  numbered dots are the whole point of the drawing: read left to right, they are
  the order the golfer's body actually fired in.
*/
private struct FiringOrderChart: View {
    let curves: [SequenceCurve]
    let peaks: [SequencePeakMark]
    let span: Int

    private var upper: Int { max(1, span) }

    var body: some View {
        Chart {
            ForEach(curves) { curve in
                ForEach(curve.points, id: \.frame) { point in
                    LineMark(
                        x: .value("Frame", point.frame),
                        y: .value("Speed", point.value),
                        series: .value("Segment", curve.id)
                    )
                    .foregroundStyle(curve.colour)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }

            ForEach(peaks) { peak in
                PointMark(
                    x: .value("Frame", peak.frame),
                    y: .value("Speed", peak.value)
                )
                .foregroundStyle(peak.colour)
                .symbolSize(72)
                .annotation(position: .top, alignment: .center, spacing: 2) {
                    Text("\(peak.rank)")
                        .font(.data(TypeScale.nano))
                        .foregroundStyle(peak.colour)
                }
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: 0...upper)
        // Headroom above the peaks, so the numbered annotations are not clipped
        // by the top of the plot area.
        .chartYScale(domain: 0...1.2)
        .chartXAxis {
            AxisMarks(values: [0, upper]) { value in
                AxisGridLine().foregroundStyle(Tok.line)
                AxisValueLabel {
                    Text((value.as(Int.self) ?? 0) <= 0 ? "TOP" : "IMPACT")
                        .font(.data(TypeScale.nano))
                        .foregroundStyle(Tok.bone3)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 0.5, 1]) { _ in
                AxisGridLine().foregroundStyle(Tok.line.opacity(0.5))
            }
        }
        .frame(height: 150)
    }
}

struct AnalysisView: View {
    @Environment(AppStore.self) private var store

    // Playback
    @State private var frames: [Frame] = []
    @State private var handSeries: FrameSeries?
    @State private var clubSeries: FrameSeries?
    @State private var topFrame: Int?
    /*
      P10, the finish, and the last frame either swing trace is drawn to.

      Held separately from the p10 that bounds the path builders, because the two
      answer different questions. The builder's p10 says which frames a path is
      built from, and falls back to the end of the clip when the detector found
      no finish. This one says where drawing stops, and stays nil in that case,
      so a swing with no detected finish draws as it always did rather than
      stopping at an invented one.
    */
    @State private var finishFrame: Int?
    @State private var playback = PlaybackState()

    // Metrics and graph
    @State private var metricSource: MetricSource?
    @State private var graphLines: [GraphLine] = []
    @State private var phaseMarks: [PhaseMark] = []
    // The frames the kinematic graph plots: top through just past impact.
    @State private var graphWindow: ClosedRange<Int>? = nil
    // Schematic estimated ball flight, drawn over the clip. Empty when no
    // estimate has been produced.
    @State private var ballTrajectory: [CGPoint] = []
    // The firing order graph in the full breakdown, built from the same downswing
    // window the kinematic graph uses. Empty when the swing had no usable curves,
    // in which case the card falls back to the text reading alone.
    @State private var sequenceCurves: [SequenceCurve] = []
    @State private var sequencePeakMarks: [SequencePeakMark] = []
    @State private var sequenceSpan: Int = 0
    /*
      The metrics on the bar, in the golfer's order. Bound straight to settings so
      a drag in the picker persists, with no separate copy to keep in step.
    */
    private var selectedMetrics: Binding<[String]> {
        Binding(
            get: { store.settings.metricOrder.isEmpty ? SwingMetrics.defaults : store.settings.metricOrder },
            set: { newValue in store.update { $0.metricOrder = newValue } }
        )
    }
    // The two customisable metric pages, each bound to its own persisted order.
    private var metricBar1: Binding<[String]> {
        Binding(
            get: { store.settings.metricOrderBar1 },
            set: { newValue in store.update { $0.metricOrderBar1 = newValue } }
        )
    }
    private var metricBar2: Binding<[String]> {
        Binding(
            get: { store.settings.metricOrderBar2 },
            set: { newValue in store.update { $0.metricOrderBar2 = newValue } }
        )
    }
    @State private var metricPickerOpen = false
    @State private var confirmDelete = false
    @State private var breakdownOpen = false
    @State private var diagnosticOpen = false
    // The firing order explainer, opened from the "i" on the breakdown card.
    @State private var firingInfoOpen = false
    // The ball flight placeholder notice, shown when a golfer outside the beta
    // taps the layer. Same words as the fullscreen one, on purpose.
    @State private var ballFlightNoticeOpen = false

    // 3D
    @State private var anchor: SwingAnchor = .fallback
    @State private var handTrace3D: WorldFrameSeries?
    @State private var clubTrace3D: WorldFrameSeries?
    @State private var controls3D = SceneKitControls()
    @State private var settings3D = Skeleton3DSettings()
    @State private var show3D = true
    // Which viewport the inline panel shows. False is the 2D clip with overlays,
    // Local mirror of the record's favourite flag, so the star updates instantly
    // on tap. Seeded from the record when a swing loads.
    @State private var isFavourite = false
    // The skeleton and joints customisation, persisted by the model itself.
    @State private var skeleton = SkeletonSettings()
    @State private var skeletonSheetOpen = false
    @State private var drillSheetOpen = false
    // Overlay layer toggles, driving what the inline viewport draws.
    @State private var showSkeletonLayer = true
    @State private var showHandPath = false
    @State private var showClubPath = false
    @State private var showBallFlight = false
    @State private var showSpineLine = true
    // The plus menu on the viewport bar, which drives the five toggles above.
    @State private var layersOpen = false

    // Phase 5: annotation, screen recording, overflow menu, video editing.
    @State private var pencil = PencilKitController()
    @State private var drawingActive = false
    @State private var recorder = ReplayKitManager()
    @State private var overflowOpen = false
    @State private var isFullscreen = false

    // The video's true aspect, width over height, so the inline panel and its
    // overlays share the same box. Defaults to portrait 9:16 until the clip
    // reports its real size. This is the inline half of the Part 11 skeleton
    // alignment fix; the fullscreen viewer does the same with its own fit box.
    @State private var videoAspect: CGFloat = 9.0 / 16.0
    private var inlineAspect: CGFloat { videoAspect }
    @State private var editing = false
    @State private var trimSheetOpen = false
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0

    private var swing: SwingRecord? {
        guard let id = store.params.swingId else { return nil }
        return store.swings.first { $0.id == id }
    }

    private var hasPlayback: Bool { !frames.isEmpty }

    private var dominantHand: DominantHand {
        DominantHand(rawValue: store.settings.dominantHand) ?? .right
    }

    // The saved clip for this swing, if the capture pipeline has written one.
    // Nil today for most swings, which is why the player still shows its backdrop.
    private var videoURL: URL? {
        guard let id = swing?.id else { return nil }
        return store.videoURL(for: id)
    }

    private var hasVideo: Bool { videoURL != nil }

    // Step 9 on the analysis side. A front facing capture is mirrored, so the
    // overlays flip to stay aligned with the picture. environment (rear) is not.
    private var overlaysMirrored: Bool {
        store.settings.cameraFacing == "user"
    }

    /*
      Whether the ball flight layer actually draws here.

      The beta flag is a condition of drawing, not only of toggling, because
      showBallFlight outlives a settings change. A golfer who switched the layer
      on while the flag was set and then cleared it would otherwise keep seeing
      an unfinished layer with no way to work out why.
    */
    private var drawsBallFlight: Bool {
        showBallFlight && store.settings.betaFounder && !ballTrajectory.isEmpty
    }

    var body: some View {
        ScreenContainer {
            HStack {
                Button {
                    store.back()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Back")
                            .font(.body(TypeScale.small))
                    }
                    .foregroundStyle(Tok.bone)
                }
                .buttonStyle(PressScale())

                Spacer()

                if let swing {
                    Button {
                        isFavourite = store.toggleFavourite(for: swing.id)
                    } label: {
                        Image(systemName: isFavourite ? "star.fill" : "star")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(isFavourite ? Tok.citrus : Tok.bone2)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Tok.turf800))
                            .overlay(Circle().strokeBorder(isFavourite ? Tok.citrusDim : Tok.line, lineWidth: 1))
                    }
                    .buttonStyle(PressScale())
                    .accessibilityLabel(isFavourite ? "Remove from favourites" : "Save to favourites")
                }
            }

            // The clip leads.
            if hasPlayback {
                Button {
                    skeletonSheetOpen = true
                } label: {
                    HStack {
                        Text("Skeleton and joints")
                            .font(.body(TypeScale.body))
                            .foregroundStyle(Tok.bone)
                        Spacer()
                        Text(String(format: "%.1f thick", skeleton.thickness))
                            .font(.data(TypeScale.small))
                            .foregroundStyle(Tok.bone3)
                    }
                    .padding(.horizontal, Tok.s4)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                    .background(Capsule().fill(Tok.turf800.opacity(0.6)))
                    .overlay(Capsule().strokeBorder(Tok.line, lineWidth: 1))
                }
                .buttonStyle(PressScale())
                .padding(.top, 12)

                videoPanel
                    .padding(.top, 12)
                // One transport for both panels, because there is one clock.
                PlaybackControls(playback: playback, phaseMarks: phaseMarks)
            }

            Text(headline)
                .font(.serif(TypeScale.title))
                .foregroundStyle(Tok.bone)
                .padding(.top, 10)
                .padding(.bottom, Tok.s2)

            Text(subhead)
                .font(.body(TypeScale.small))
                .foregroundStyle(Tok.bone2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Tok.s5)

            VStack(spacing: Tok.s2) {
                ForEach(CategoryKey.allCases, id: \.self) { category in
                    categoryRow(category)
                }
            }

            drillCard

            fullBreakdownSection
            diagnosticReportSection

            /*
              The metrics, at the foot of the page.

              They used to sit directly under the transport, between the video and
              the headline, where they pushed the diagnosis and the category rows
              off the first screen and took the space a golfer wants for the
              picture. Down here the clip and its verdict lead, and the numbers are
              where somebody who wants to read them goes looking, rather than
              something everybody has to scroll past.
            */
            if let metricSource {
                measurementBadge
                metricsHeader
                MetricsBar(
                    source: metricSource,
                    frameIndex: playback.frameIndex,
                    selected: selectedMetrics.wrappedValue,
                    layout: .grid
                )
                .padding(.bottom, Tok.s3)
            }

            HStack(spacing: Tok.s3) {
                Button {
                    store.back()
                } label: {
                    Text("Back")
                        .font(.body(TypeScale.small))
                        .padding(.vertical, 12)
                        .padding(.horizontal, 20)
                        .foregroundStyle(Tok.bone)
                        .overlay { Capsule().strokeBorder(Tok.lineStrong, lineWidth: 1) }
                }
                .buttonStyle(PressScale())

                Button {
                    confirmDelete = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .medium))
                        Text("Delete")
                            .font(.body(TypeScale.small))
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 20)
                    .foregroundStyle(Tok.rust)
                    .overlay { Capsule().strokeBorder(Tok.rust.opacity(0.6), lineWidth: 1) }
                }
                .buttonStyle(PressScale())
            }
            .padding(.top, Tok.s5)
        }
        .task(id: swing?.id) {
            loadSwing()
            await measureVideoAspect()
        }
        .onDisappear {
            controls3D.teardown()
            persistAnnotation()
        }
        .onChange(of: recorder.lastMessage) { _, message in
            if let message { store.notify(message, tone: .info) }
        }
        .onChange(of: drawingActive) { _, active in
            pencil.isActive = active
            // Pause playback while drawing, so the picture the mark was drawn over
            // does not scrub out from under it.
            if active {
                playback.pause()
                layersOpen = false
            }
        }
        .sheet(isPresented: $drillSheetOpen) {
            drillDetail
        }
        .sheet(isPresented: $skeletonSheetOpen) {
            SkeletonSettingsView(settings: skeleton) { skeletonSheetOpen = false }
                .presentationDetents([.large])
        }
        .sheet(isPresented: $firingInfoOpen) {
            firingOrderInfoSheet
        }
        .alert("Delete this swing?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let id = swing?.id {
                    store.deleteSwing(id: id)
                    store.back()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the swing and its clip for good.")
        }
        /*
          The ball flight placeholder. Same title, same message and same single
          button as the fullscreen one, because they are the same claim about the
          same unfinished layer and a golfer should not be able to tell which
          menu they came from.
        */
        .alert("Ball Flight Tracking", isPresented: $ballFlightNoticeOpen) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("New version coming soon. Stay tuned!")
        }
        .sheet(isPresented: $metricPickerOpen) {
            MetricPicker(bar1: metricBar1, bar2: metricBar2)
        }
        .confirmationDialog("Swing options", isPresented: $overflowOpen, titleVisibility: .visible) {
            overflowMenuButtons
        }
        .sheet(isPresented: $trimSheetOpen) {
            trimSheet
        }
        .fullScreenCover(isPresented: $isFullscreen) {
            FullscreenSwingView(
                frames: frames,
                handSeries: handSeries,
                clubSeries: clubSeries,
                topFrame: topFrame,
                finishFrame: finishFrame,
                videoURL: videoURL,
                mirrored: overlaysMirrored,
                metricSource: metricSource,
                playback: playback,
                selectedMetrics: metricBar1,
                metricsBar2: metricBar2,
                isPresented: $isFullscreen,
                /* The overlay layer toggles live in the fullscreen bar and in the
                   plus menu on this screen's viewport bar. Both drive the same
                   state this screen draws with, so a layer switched off in either
                   place is off in the other. */
                showSkeleton: $showSkeletonLayer,
                showHandPath: $showHandPath,
                showClubPath: $showClubPath,
                showBallFlight: $showBallFlight,
                showSpine: $showSpineLine,
                skeleton: skeleton,
                ballTrajectory: ballTrajectory,
                /* The beta founder flag, read here because this screen owns the
                   store, and used there to decide whether the ball flight layer
                   draws or explains itself. */
                betaFounder: store.settings.betaFounder,
                // The 3D panel's scene, and the sequence graph, both of which
                // moved here off the inline screen.
                sceneID: swing?.id ?? "none",
                anchor: anchor,
                handTrace3D: handTrace3D,
                clubTrace3D: clubTrace3D,
                dominantHand: dominantHand,
                settings3D: settings3D,
                controls3D: controls3D,
                graphLines: graphLines,
                phaseMarks: phaseMarks,
                graphWindow: graphWindow,
                recorder: recorder,
                onVoiceNote: { store.notify("Voice notes coming soon.", tone: .info) },
                frontCameraOn: store.settings.cameraFacing == "user",
                onToggleFacing: {
                    store.update { $0.cameraFacing = ($0.cameraFacing == "user") ? "environment" : "user" }
                },
                /*
                  Trim picks its range in the viewer now, and reports it here.

                  The viewer is closed first, deliberately. Two reasons, and both
                  are about not lying to the golfer. The working toast and any
                  failure notice are presented by this screen, which sits under
                  the cover and would be invisible from in there. And the pose
                  frames are indexed to the clip as it was: once the clip is
                  recut, this screen reloads the swing, which is the only thing
                  that puts the overlays back in step with the picture.
                */
                onTrimRange: { start, end in
                    isFullscreen = false
                    runEdit { try await VideoEditor.trim(source: $0, startSeconds: start, endSeconds: end) }
                },
                hasVideo: hasVideo,
                pencil: pencil,
                onSaveAnnotation: {
                    if let id = swing?.id { store.saveAnnotation(for: id, data: pencil.currentDrawingData()) }
                }
            )
        }
    }

    // MARK: Overflow menu

    private var overflowButton: some View {
        Button {
            overflowOpen = true
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Tok.bone)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Tok.turf800))
                .overlay(Circle().strokeBorder(Tok.line, lineWidth: 1))
        }
        .buttonStyle(PressScale())
        .disabled(editing)
    }

    /*
      The menu, in the same order as the web FullscreenSwing "more" popover.
      Share and Download are always offered. The four the web build stubbed as
      "Coming with the native app" are now real, and the three that touch the
      video clip disable themselves when there is no clip yet rather than failing
      after the fact.
    */
    @ViewBuilder
    private var overflowMenuButtons: some View {
        // Record and voice note live in the fullscreen top bar. The video edits
        // were moved out to keep this menu to the one action it needs here.
        Group {
            Button("Draw on this swing") { drawingActive = true }
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: Split screen

    /*
      3D on top, video below, sharing one scrubber.

      The 3D panel is 4:3 rather than the video's 9:16 because the figure is
      widest when it turns, and a portrait panel wastes height on empty sky above
      the head. The video keeps its own aspect so the normalised overlays line up
      with the picture, which they only do under aspect fit.
    */
    /*
      Retained for the fullscreen viewer's 3D panel, which reads the same scene
      state this screen loads. The inline layout no longer stacks the two
      panels, because the clip is the main content here.
    */
    private var splitScreen: some View {
        VStack(spacing: Tok.s3) {
            scenePanel
            sceneControlBar
        }
    }

    private var scenePanel: some View {
        ZStack(alignment: .topLeading) {
            SceneKitView(
                frames: frames,
                frameIndex: playback.frameIndex,
                anchor: anchor,
                handTrace: handTrace3D,
                clubTrace: clubTrace3D,
                topFrame: topFrame,
                dominantHand: dominantHand,
                jointColorStyle: settings3D.jointColorStyle,
                palette: settings3D.palette,
                markerPalette: .standard,
                showTraces: settings3D.showTraces,
                showGrid: settings3D.showGrid,
                showConnectingLines: skeleton.showConnectingLines,
                hiddenLineJoints: skeleton.hiddenLineJoints,
                controls: controls3D,
                isUnlocked: settings3D.isUnlocked
            )
            /* Structural changes go through identity, not through updateUIView.
               Changing the swing, the palette or the trace visibility means a
               different scene, so the view is rebuilt. Changing the frame index
               or the marker style does not appear here, because those are cheap
               updates the representable handles in place. */
            .id("\(swing?.id ?? "none")-\(settings3D.paletteName)-\(settings3D.showTraces)-\(settings3D.showGrid)")

            sceneBadges
        }
        .background {
            /* Matches the web panel's radial wash, so the 3D view sits on the
               same surface the rest of the app uses. */
            RadialGradient(
                colors: [Color(hex: "#16261c"), Tok.turf900],
                center: UnitPoint(x: 0.5, y: 0),
                startRadius: 0,
                endRadius: 420
            )
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                .strokeBorder(settings3D.isUnlocked ? Tok.citrusDim : Tok.line, lineWidth: 1)
        }
    }

    /*
      The SKETCH badge is not decoration.

      src/components/Pose3D.jsx records that the solid rig was built, watched
      against a real swing, and switched off, because it drew limbs that were not
      there and joints bent at angles the golfer had not reached. This build ships
      the solid figure anyway, so it says what it is. The figure is a reading of
      thirteen tracked points, not a measurement of a body.
    */
    private var sceneBadges: some View {
        HStack(spacing: 6) {
            Text("SKETCH")
                .font(.data(TypeScale.nano))
                .tracking(1)
                .foregroundStyle(Tok.bone2)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Tok.ink.opacity(0.55)))
                .overlay(Capsule().strokeBorder(Tok.line, lineWidth: 1))

            if settings3D.isUnlocked {
                Text("DRAG TO TURN")
                    .font(.data(TypeScale.nano))
                    .tracking(1)
                    .foregroundStyle(Tok.citrus)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Tok.ink.opacity(0.55)))
                    .overlay(Capsule().strokeBorder(Tok.citrusDim, lineWidth: 1))
            }
        }
        .padding(Tok.s3)
        .allowsHitTesting(false)
    }

    /*
      Temporary controls, Phase 5 replaces them.

      Deliberately sitting on the panel rather than buried in settings, because
      the point of this batch is to be able to look at the figure and change how
      it looks without leaving the screen.
    */
    private var sceneControlBar: some View {
        VStack(spacing: Tok.s2) {
            HStack(spacing: Tok.s2) {
                sceneChip(
                    label: settings3D.isUnlocked ? "Locked view" : "Turn figure",
                    system: settings3D.isUnlocked ? "lock.open" : "hand.draw",
                    active: settings3D.isUnlocked
                ) {
                    settings3D.isUnlocked.toggle()
                }
                sceneChip(label: "Face on", system: "person.fill") { controls3D.faceOn() }
                sceneChip(label: "Down line", system: "arrow.right.to.line") { controls3D.downTheLine() }
                sceneChip(label: "Reset", system: "arrow.counterclockwise") { controls3D.reset() }
            }

            HStack(spacing: Tok.s2) {
                // The joint marker style toggle this batch was built around.
                Picker("Joints", selection: Binding(
                    get: { settings3D.jointColorStyle },
                    set: { settings3D.jointColorStyle = $0 }
                )) {
                    ForEach(JointColorStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                sceneChip(
                    label: "Traces",
                    system: settings3D.showTraces ? "scribble.variable" : "scribble",
                    active: settings3D.showTraces
                ) {
                    settings3D.showTraces.toggle()
                }
            }

            HStack(spacing: Tok.s2) {
                // Grid stays. Palette options and the Hide 3D chip were removed
                // from the inline controls: the inline panel is for reading the
                // swing, not restyling the figure, and the VIEW 2D button above
                // is the way back to the clip.
                sceneChip(label: "Grid", system: "grid", active: settings3D.showGrid) {
                    settings3D.showGrid.toggle()
                }
            }
        }
        .padding(.horizontal, 2)
    }

    // A round translucent icon button for the viewport top bar.
    private func viewportIcon(system: String, tint: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
    }

    private func sceneChip(
        label: String,
        system: String,
        active: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: system)
                    .font(.system(size: 10, weight: .medium))
                Text(label)
                    .font(.data(TypeScale.nano))
            }
            .foregroundStyle(active ? Tok.ink : Tok.bone2)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Capsule().fill(active ? Tok.citrus : Tok.turf800))
            .overlay(Capsule().strokeBorder(active ? .clear : Tok.line, lineWidth: 1))
        }
        .buttonStyle(PressScale())
    }

    private var videoPanel: some View {
        VStack(spacing: Tok.s2) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    VideoPlayerView(videoURL: videoURL, playback: playback)
                    if showSkeletonLayer {
                        SkeletonOverlay(
                            frames: frames,
                            frameIndex: playback.frameIndex,
                            mirrored: overlaysMirrored,
                            showSpine: showSpineLine,
                            settings: skeleton
                        )
                    }
                    TraceOverlay(
                        handSeries: showHandPath ? handSeries : nil,
                        clubSeries: showClubPath ? clubSeries : nil,
                        frameIndex: playback.frameIndex,
                        topFrame: topFrame,
                        endFrame: finishFrame,
                        mirrored: overlaysMirrored,
                        frames: frames,
                        trackedLandmarks: skeleton.trackedJoints.map(\.landmark),
                        traceWidth: CGFloat(skeleton.thickness),
                        ballTrajectory: drawsBallFlight ? ballTrajectory : nil
                    )

                    // The drawing surface sits above the overlays and only takes
                    // touches while the tool is open. Ink takes them with the pen
                    // or eraser up; the shape overlay takes them with a shape tool
                    // up, so the two never fight for the same tap.
                    PencilCanvas(controller: pencil)
                        .allowsHitTesting(drawingActive && pencil.shapeMode == .none)
                    if drawingActive && pencil.shapeMode != .none {
                        ShapeOverlay(controller: pencil)
                    }
                }

                /*
                  Top bar inside the viewport.

                  Left: record this screen (ReplayKit, real start/stop), a voice
                  note button (honest toast until the recorder is built), and a
                  front/rear camera toggle that flips cameraFacing so the overlay
                  mirroring follows the feed. Right: the layers plus menu, then
                  More metrics, which opens the immersive fullscreen viewer where
                  2D, 3D and the sequence live. One translucent bar over the clip,
                  hidden while drawing so a stray stroke cannot hit it.
                */
                if !drawingActive {
                    VStack {
                        HStack(spacing: Tok.s3) {
                            viewportIcon(
                                system: "arrow.triangle.2.circlepath.camera",
                                tint: overlaysMirrored ? Tok.citrus : Tok.bone,
                                label: "Switch camera facing"
                            ) {
                                store.update { $0.cameraFacing = ($0.cameraFacing == "user") ? "environment" : "user" }
                            }

                            Spacer()

                            /*
                              The layer plus, sibling to More metrics.

                              Same glyph and same five rows as the fullscreen
                              dropdown, bound to the same five pieces of state, so
                              this is not a second set of switches, it is the same
                              set reached from a second place.
                            */
                            Button {
                                withAnimation(.easeInOut(duration: 0.16)) { layersOpen.toggle() }
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(layersOpen ? Tok.ink : Tok.bone)
                                    .frame(width: 32, height: 32)
                                    .background(Circle().fill(layersOpen ? Tok.citrus : Tok.ink.opacity(0.62)))
                                    .overlay(Circle().strokeBorder(layersOpen ? Color.clear : Tok.line, lineWidth: 1))
                            }
                            .buttonStyle(PressScale())
                            .accessibilityLabel("Overlay layers")

                            Button {
                                layersOpen = false
                                isFullscreen = true
                            } label: {
                                HStack(spacing: 4) {
                                    Text("More metrics")
                                        .font(.data(TypeScale.nano))
                                        .tracking(0.5)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .foregroundStyle(Tok.bone)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(Tok.ink.opacity(0.62)))
                                .overlay(Capsule().strokeBorder(Tok.line, lineWidth: 1))
                            }
                            .buttonStyle(PressScale())
                            .accessibilityLabel("Open fullscreen viewer with more metrics")
                        }
                        .padding(.horizontal, Tok.s3)
                        .padding(.vertical, Tok.s2)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(Tok.s3)

                        Spacer()
                    }
                }

                // The dropdown itself, hung under the bar it belongs to.
                if layersOpen && !drawingActive {
                    layersPopover
                }
            }
            .aspectRatio(inlineAspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                    .strokeBorder(drawingActive ? Tok.citrusDim : Tok.line, lineWidth: 1)
            }

            if drawingActive {
                PencilToolbar(controller: pencil) {
                    drawingActive = false
                    persistAnnotation()
                }
            }
        }
    }

    // MARK: Layer dropdown

    /*
      The five overlay toggles, in the fullscreen dropdown's clothes.

      The scrim underneath is nearly invisible on purpose: it exists so a tap
      anywhere else on the clip closes the menu, which is how the fullscreen one
      behaves and what a golfer will try first. Club head disables itself when
      the swing carries no such path, so the row says why it will not light up
      rather than toggling a layer that has nothing to draw.

      Ball flight is the odd one out. It is not disabled, because a disabled row
      cannot explain itself, and "coming soon" is the whole message. It is the
      same gate and the same words as the fullscreen menu, since the two menus
      are two doors into one room.
    */
    private var layersPopover: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.16)) { layersOpen = false }
                }

            VStack(alignment: .leading, spacing: 2) {
                layerSwitchRow(title: "Skeleton", on: showSkeletonLayer) {
                    showSkeletonLayer.toggle()
                }
                layerSwitchRow(title: "Hand path", on: showHandPath) {
                    showHandPath.toggle()
                }
                layerSwitchRow(
                    title: "Club head",
                    hint: clubSeries == nil ? nil : "Estimated from the lead arm",
                    on: showClubPath,
                    disabled: clubSeries == nil
                ) {
                    showClubPath.toggle()
                }
                layerSwitchRow(
                    title: "Ball flight",
                    hint: ballFlightHint,
                    on: showBallFlight && store.settings.betaFounder
                ) {
                    guard store.settings.betaFounder else {
                        withAnimation(.easeInOut(duration: 0.16)) { layersOpen = false }
                        ballFlightNoticeOpen = true
                        return
                    }
                    showBallFlight.toggle()
                }
                layerSwitchRow(title: "Spine", on: showSpineLine) {
                    showSpineLine.toggle()
                }
            }
            .padding(6)
            .frame(width: 224, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Tok.turf800.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Tok.glassEdge, lineWidth: 1)
            )
            .padding(.top, 60)
            .padding(.trailing, Tok.s3 + 4)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // What the ball flight row says under its title, which depends on why it
    // will or will not draw.
    private var ballFlightHint: String {
        if !store.settings.betaFounder { return "Coming soon" }
        if ballTrajectory.isEmpty { return "No flight estimate for this swing" }
        return "Beta, estimated from impact"
    }

    private func layerSwitchRow(
        title: String,
        hint: String? = nil,
        on: Bool,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.body(TypeScale.small))
                        .foregroundStyle(disabled ? Tok.bone3 : Tok.bone)
                    if let hint {
                        Text(hint)
                            .font(.body(TypeScale.nano))
                            .foregroundStyle(Tok.bone3)
                    }
                }
                Spacer(minLength: 0)
                // The same compact pill switch the fullscreen menu uses, on is
                // citrus.
                Capsule()
                    .fill(on ? Tok.citrus : Tok.turf700)
                    .frame(width: 34, height: 20)
                    .overlay(
                        Circle()
                            .fill(on ? Tok.ink : Tok.bone2)
                            .frame(width: 15, height: 15)
                            .padding(2),
                        alignment: on ? .trailing : .leading
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel("\(title) layer")
        .accessibilityValue(on ? "on" : "off")
    }

    /*
      Says plainly when the numbers below are degraded, and why.

      Built from what the saved record actually carries: the camera angle it was
      filmed from, and the tracked confidence. A live SwingAnalysis (and so the
      SessionQuality object) does not exist by the time this screen opens, it is
      rebuilt from a stored SwingRecord, so the badge derives the same two facts
      from the record rather than pretending to read a quality object that is not
      there.

      Down the line hides the rotation family, which the bar has already removed,
      so the badge explains the gap rather than leaving cards mysteriously
      missing. Low confidence warns that everything shown is shakier than usual.
      Nothing to say means no badge.
    */
    private var measurementBadge: some View {
        let view = CameraViewKind(rawValue: swing?.view ?? "") ?? .unknown
        let confidence = swing?.confidence ?? 1
        let lowConfidence = confidence > 0 && confidence < SessionQuality.lowConfidenceThreshold
        let downTheLine = view == .downTheLine

        let text: String? = {
            if lowConfidence && downTheLine { return "Low tracking confidence, and depth metrics are unavailable down the line" }
            if lowConfidence { return "Low tracking confidence, treat these numbers as rough" }
            if downTheLine { return "Filmed down the line, so turn and separation cannot be measured" }
            return nil
        }()

        let tint: Color = lowConfidence
            ? Color(red: 1.0, green: 0.6, blue: 0.0)
            : Color(red: 0.2, green: 0.5, blue: 1.0)

        return Group {
            if let text {
                HStack(spacing: 6) {
                    Image(systemName: lowConfidence ? "exclamationmark.triangle" : "info.circle")
                        .font(.system(size: 12, weight: .medium))
                    Text(text)
                        .font(.data(TypeScale.nano))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Capsule().fill(tint.opacity(0.12)))
                .padding(.bottom, 6)
            }
        }
    }

    private var metricsHeader: some View {
        HStack {
            Text("Metrics")
                .font(.data(TypeScale.nano))
                .tracking(1)
                .foregroundStyle(Tok.bone3)
            Spacer()
        }
        .padding(.top, Tok.s3)
        .padding(.bottom, 6)
    }

    // MARK: Loading

    private func loadSwing() {
        guard let swing else {
            resetPlayback()
            return
        }

        // Phase 5: restore any freehand annotation for this swing before the
        // canvas is built, and default the joint style from settings.
        pencil.load(from: store.annotation(for: swing.id))
        drawingActive = false
        layersOpen = false
        isFavourite = swing.favourite
        settings3D.jointColorStyle = JointColorStyle(rawValue: store.settings.jointColorStyle) ?? .dual

        let loaded = store.frames(for: swing.id) ?? []
        frames = loaded
        playback.load(frameTimes: loaded.map(\.t))

        guard !loaded.isEmpty else {
            resetPlayback(keepFramesCleared: true)
            return
        }

        let idx = swing.phases?.idx ?? [:]
        let p1 = idx["p1"] ?? 0
        let to = idx["p10"] ?? (loaded.count - 1)
        topFrame = idx["p4"]
        /* Where the traces stop. The detector's own p10 only, with no fallback
           to the end of the clip, because a fallback here would mean drawing a
           cap the swing does not have. */
        finishFrame = idx["p10"]

        let hand = dominantHand

        // Phase 2 traces, image space, drawn over the video.
        let built = TrackingLayers.build(frames: loaded, from: p1, to: to, dominantHand: hand)
        handSeries = built.hand
        clubSeries = built.club

        /* Phase 4 step 10. Measured once per swing, not per frame: the ground
           plane, the body height, the shoulder span and which way y points. */
        let measured = SwingAnchor.measure(frames: loaded)
        anchor = measured

        // The same two paths in metric space, for the 3D scene.
        let built3D = SwingTrace3D.build(
            frames: loaded,
            from: p1,
            to: to,
            dominantHand: hand,
            anchor: measured
        )
        handTrace3D = built3D.hand
        clubTrace3D = built3D.club

        // Phase 3: rebuild the full series once. It feeds both the graph and the
        // metric bar, and is 1:1 with the frames so it lines up with frameIndex.
        var series = Biomechanics.buildSeries(loaded, hand)
        // Now that phases are known, fill the stability metrics so their cards
        // read real values instead of unavailable.
        let p4 = idx["p4"] ?? 0
        let p7 = idx["p7"] ?? 0
        series.fillStability(p1: p1, p4: p4, p7: p7)

        /*
          Ball flight estimates. Computed here, not in the engine, because the
          club is a user setting and the engine cannot see settings. Model
          figures driven by hand speed at impact plus club average tables, set on
          the series so the Est. cards and the schematic trajectory can read them.
        */
        let club = ClubType(rawValue: store.settings.selectedClub) ?? .driver
        if loaded.indices.contains(p7), series.handSpeed.indices.contains(p7) {
            let sides = Landmarks.sides(hand)
            let wv = loaded[p7].world
            let elbow = wv[sides.leadElbow].vec
            let wrist = wv[sides.leadWrist].vec
            let shoulder = wv[sides.leadShoulder].vec
            let forearm = Geometry.v.sub(wrist, elbow)
            let horiz = (forearm.x * forearm.x + (forearm.z ?? 0) * (forearm.z ?? 0)).squareRoot()
            let forearmAngleFromVertical = atan2(horiz, abs(forearm.y)) * 180.0 / Double.pi
            let spineTiltAtImpact = series.spineTilt.indices.contains(p7) ? series.spineTilt[p7] : 0
            let armLength = Geometry.v.dist(shoulder, wrist)
            let wristSpeed = series.handSpeed[p7]

            let clubheadSpeed = BallFlightEstimator.estimateClubheadSpeed(wristSpeed: wristSpeed, club: club, armLength: armLength)
            let ballSpeed = BallFlightEstimator.estimateBallSpeed(clubheadSpeed: clubheadSpeed, club: club)
            let launch = BallFlightEstimator.estimateLaunchAngle(forearmAngleFromVertical: forearmAngleFromVertical, spineTilt: spineTiltAtImpact, club: club)
            let carry = BallFlightEstimator.estimateCarryDistance(ballSpeed: ballSpeed, launchAngleDeg: launch, club: club)
            let start = CGPoint(x: loaded[p7].norm[sides.leadWrist].x, y: loaded[p7].norm[sides.leadWrist].y)

            series.clubheadSpeedEstimate = clubheadSpeed
            series.ballSpeedEstimate = ballSpeed
            series.launchAngleEstimate = launch
            series.carryDistanceEstimate = carry
            series.spinRateEstimate = BallFlightEstimator.estimateSpinRate(club: club)
            series.estimatedClub = club
            series.ballTrajectory = BallFlightEstimator.generateTrajectory(ballSpeed: ballSpeed, launchAngleDeg: launch, startPoint: start)
        }
        ballTrajectory = series.ballTrajectory

        /* Persist the estimates on the record so the timeline can show the most
           recent numbers without reopening and recomputing the swing. Only when
           they changed, so this does not write on every open. */
        if series.ballSpeedEstimate > 0,
           let i = store.swings.firstIndex(where: { $0.id == swing.id }),
           store.swings[i].ballSpeedEstimate != series.ballSpeedEstimate {
            store.swings[i].ballSpeedEstimate = series.ballSpeedEstimate
            store.swings[i].carryDistanceEstimate = series.carryDistanceEstimate
            store.swings[i].launchAngleEstimate = series.launchAngleEstimate
            store.swings[i].spinRateEstimate = series.spinRateEstimate
            store.persistRecord(store.swings[i])
        }
        let turns = series.turnFrom(p1)
        metricSource = MetricSource(
            series: series,
            torsoTurnFromAddress: turns.torso,
            pelvisTurnFromAddress: turns.pelvis,
            view: CameraViewKind(rawValue: swing.view ?? "") ?? .unknown,
            tempoRatio: swing.phases?.tempoRatio,
            backswingMs: swing.phases?.backswingMs,
            downswingMs: swing.phases?.downswingMs,
            overallScore: swing.scores?.overall
        )
        /* The sequence is a downswing event, so the graph is windowed to it. See
           KinematicGraph.build for why plotting the whole clip misreported the
           order. Falls back to the whole clip when phases are missing. */
        let window = KinematicGraph.window(
            topIndex: idx["p4"],
            impactIndex: idx["p7"],
            frameCount: loaded.count
        )
        graphWindow = window
        graphLines = KinematicGraph.build(
            series: series,
            from: window?.lowerBound,
            to: window?.upperBound
        )
        phaseMarks = ["p3", "p4", "p5", "p7"].compactMap { key in
            guard let index = idx[key] else { return nil }
            return PhaseMark(label: key.uppercased(), index: index)
        }

        /* The firing order graph in the full breakdown. Same window as the
           kinematic graph above, and the same four speed series, so the drawing
           and the text reading underneath it can never disagree about what
           happened. This is the one place the four segment speeds are named, so
           it is the one place to touch if the series ever renames them. */
        let chart = Self.buildSequenceChart(
            pelvis: series.pelvisSpeed,
            torso: series.torsoSpeed,
            arm: series.armSpeed,
            club: series.handSpeed,
            window: window,
            observedOrder: swing.sequence?.observedOrder ?? []
        )
        sequenceCurves = chart.curves
        sequencePeakMarks = chart.peaks
        sequenceSpan = chart.span
    }

    private func resetPlayback(keepFramesCleared: Bool = false) {
        if !keepFramesCleared { frames = [] }
        handSeries = nil
        clubSeries = nil
        topFrame = nil
        finishFrame = nil
        metricSource = nil
        graphLines = []
        phaseMarks = []
        graphWindow = nil
        ballTrajectory = []
        sequenceCurves = []
        sequencePeakMarks = []
        sequenceSpan = 0
        handTrace3D = nil
        clubTrace3D = nil
        anchor = .fallback
        playback.load(frameTimes: [])
    }

    // MARK: Phase 5 actions

    // Read the clip's true aspect so the inline panel and its overlays share one
    // box. Without this the panel is forced to 9:16 while the video letterboxes
    // inside it, and the skeleton, drawn across the full forced box, drifts off
    // the body. This is the Part 11 fix on the inline side.
    private func measureVideoAspect() async {
        guard let videoURL else {
            videoAspect = 9.0 / 16.0
            return
        }
        let asset = AVURLAsset(url: videoURL)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else {
            return
        }
        let resolved = natural.applying(transform)
        let w = abs(resolved.width)
        let h = abs(resolved.height)
        guard w > 0, h > 0 else { return }
        await MainActor.run { videoAspect = w / h }
    }

    private func persistAnnotation() {
        guard let id = swing?.id else { return }
        store.saveAnnotation(for: id, data: pencil.currentDrawingData())
    }

    /*
      The old inline trim sheet, kept and no longer reachable.

      Trim is picked in the fullscreen viewer now, on a filmstrip with two
      handles, and arrives back here through onTrimRange. This is left in place
      rather than deleted because it is the fallback if the viewer's sheet has to
      be pulled, and because deleting it is a separate change with its own
      review. Delete openTrim, trimSheet, trimSheetOpen, trimStart and trimEnd
      together when the new sheet has been on a device for a while.
    */
    private func openTrim() {
        guard hasVideo else {
            store.notify("This swing has no video clip to trim yet.", tone: .warn)
            return
        }
        trimStart = 0
        trimEnd = playback.durationMs / 1000
        trimSheetOpen = true
    }

    private var trimSheet: some View {
        let total = max(0.1, playback.durationMs / 1000)
        return NavigationStack {
            VStack(alignment: .leading, spacing: Tok.s5) {
                Text("Trim")
                    .font(.serif(TypeScale.title))
                    .foregroundStyle(Tok.bone)

                VStack(alignment: .leading, spacing: Tok.s2) {
                    Text("Start  \(trimStart, specifier: "%.2f")s")
                        .font(.data(TypeScale.small))
                        .foregroundStyle(Tok.bone2)
                    Slider(value: $trimStart, in: 0...total)
                        .tint(Tok.citrus)

                    Text("End  \(trimEnd, specifier: "%.2f")s")
                        .font(.data(TypeScale.small))
                        .foregroundStyle(Tok.bone2)
                    Slider(value: $trimEnd, in: 0...total)
                        .tint(Tok.citrus)
                }

                Button {
                    let lo = min(trimStart, trimEnd)
                    let hi = max(trimStart, trimEnd)
                    trimSheetOpen = false
                    runEdit { try await VideoEditor.trim(source: $0, startSeconds: lo, endSeconds: hi) }
                } label: {
                    Text("Save trimmed clip")
                        .font(.body(TypeScale.small, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .foregroundStyle(Tok.ink)
                        .background(Capsule().fill(Tok.citrus))
                }
                .buttonStyle(PressScale())

                Spacer()
            }
            .padding(Tok.s5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AmbientGround())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { trimSheetOpen = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    /*
      Run a video edit and swap the result in.

      One place for all three operations, so each menu item is one line. The edit
      runs off the main actor, the swap and the notification come back to it. A
      swing with no clip never reaches here, because the menu items that call this
      are hidden without a video, but the guard stays as a second line of defence.
    */
    private func runEdit(_ operation: @escaping (URL) async throws -> URL) {
        guard let id = swing?.id, let source = videoURL else {
            store.notify("This swing has no video clip to edit yet.", tone: .warn)
            return
        }
        editing = true
        store.notify("Working on the video.", tone: .info)
        Task {
            do {
                let output = try await operation(source)
                store.replaceVideo(for: id, with: output)
            } catch {
                store.notify((error as? LocalizedError)?.errorDescription ?? "Video edit failed.", tone: .warn)
            }
            editing = false
        }
    }

    private func shareVideo() {
        guard let url = videoURL else {
            store.notify("Nothing to share yet: this swing has no clip.", tone: .warn)
            return
        }
        Sharing.present(url: url)
    }

    // MARK: Scores

    private var headline: String {
        if let swing, let overall = swing.scores?.overall {
            return "Overall \(overall)"
        }
        return "Not scored yet"
    }

    private var subhead: String {
        if swing == nil {
            return "Open a swing from the timeline to see it here. Nothing has been recorded and scored on this device yet."
        }
        if swing?.scores == nil {
            return "This swing was recorded but not scored. You can still scrub the graph, the 3D figure, the skeleton and the traces above, frame by frame."
        }
        return "Sequencing, rotation, balance and finish, weighted into the overall score above."
    }

    /*
      The drill the diagnosis recommends, if there is one.

      Draws nothing when the swing has no drill, so a clean swing gets no empty
      state. Tapping opens the detail sheet with the cue, the constraint and the
      explanation of what the fault actually was.
    */
    // MARK: Full breakdown

    /*
      The firing order and the whole fault list, folded away by default.

      The headline card already names the one thing to work on. This is for the
      golfer who wants everything, so it stays shut until asked for.
    */
    @ViewBuilder
    private var fullBreakdownSection: some View {
        if let swing, swing.sequence != nil || !(swing.diagnosis?.faults.isEmpty ?? true) {
            VStack(alignment: .leading, spacing: Tok.s3) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { breakdownOpen.toggle() }
                } label: {
                    HStack {
                        Text(breakdownOpen ? "Hide the full breakdown" : "Show the full breakdown")
                            .font(.body(TypeScale.small))
                            .foregroundStyle(Tok.bone)
                        Spacer()
                        Image(systemName: breakdownOpen ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Tok.bone3)
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 18)
                    .overlay { RoundedRectangle(cornerRadius: Tok.rLg, style: .continuous).strokeBorder(Tok.line, lineWidth: 1) }
                }
                .buttonStyle(PressScale())

                if breakdownOpen {
                    if let sequence = swing.sequence {
                        firingOrderCard(sequence)
                    }
                    faultListCard(swing.diagnosis?.faults ?? [])
                }
            }
            .padding(.top, Tok.s4)
        }
    }

    /*
      The firing order: which segment peaked when, between the top and impact.

      A good swing runs hips, chest, arm, hands. Showing the observed order beside
      that ideal is the whole point, so a golfer can see an inversion rather than
      be told a score.

      The graph sits above the text reading, not in place of it. The text answers
      "what order", which is the thing to act on. The graph answers "by how much
      and how close together", which is the thing that tells you whether an
      inversion is a habit or a near miss, and no list of four words can carry it.
      When the swing produced no usable curves the graph is simply absent and the
      text reading stands alone, exactly as it did before.
    */
    private func firingOrderCard(_ sequence: SequenceSummary) -> some View {
        let names = sequence.observedOrder.map { Self.segmentLabel($0) }
        return VStack(alignment: .leading, spacing: Tok.s3) {
            HStack(spacing: 2) {
                Text("FIRING ORDER")
                    .font(.data(TypeScale.nano))
                    .tracking(1.5)
                    .foregroundStyle(Tok.bone3)

                Button {
                    firingInfoOpen = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Tok.bone3)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .accessibilityLabel("How to read the firing order")

                Spacer()

                if sequence.orderCorrect {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Tok.fairwayLit)
                }
            }

            if !sequenceCurves.isEmpty && sequenceSpan > 0 {
                FiringOrderChart(
                    curves: sequenceCurves,
                    peaks: sequencePeakMarks,
                    span: sequenceSpan
                )

                sequenceLegend

                Text("Each line is scaled to its own peak, so read the order the numbered dots come in rather than how high they sit.")
                    .font(.body(TypeScale.micro))
                    .foregroundStyle(Tok.bone3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("TOP")
                    .font(.data(TypeScale.nano))
                    .foregroundStyle(Tok.bone3)
                Spacer()
                Text("IMPACT")
                    .font(.data(TypeScale.nano))
                    .foregroundStyle(Tok.bone3)
            }

            HStack(spacing: Tok.s3) {
                ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                    HStack(spacing: 5) {
                        Text("\(index + 1)")
                            .font(.data(TypeScale.nano))
                            .foregroundStyle(Tok.bone3)
                        Circle()
                            .fill(Self.segmentColour(sequence.observedOrder[index]))
                            .frame(width: 8, height: 8)
                        Text(name)
                            .font(.body(TypeScale.micro))
                            .foregroundStyle(Tok.bone)
                    }
                }
                Spacer(minLength: 0)
            }

            Text(
                sequence.orderCorrect
                    ? "A good swing peaks hips, chest, arm, hands. Yours matched that."
                    : "A good swing peaks hips, chest, arm, hands. Yours went \(names.joined(separator: ", "))."
            )
            .font(.body(TypeScale.small))
            .foregroundStyle(Tok.bone2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    // The graph's key. Drawn by hand rather than through the Charts legend so the
    // swatches sit on the card's own type scale and colours.
    private var sequenceLegend: some View {
        HStack(spacing: Tok.s3) {
            ForEach(sequenceCurves) { curve in
                HStack(spacing: 5) {
                    Circle()
                        .fill(curve.colour)
                        .frame(width: 7, height: 7)
                    Text(curve.label)
                        .font(.data(TypeScale.nano))
                        .foregroundStyle(Tok.bone2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /*
      The explainer behind the "i".

      Written for a golfer who has never heard the phrase kinematic sequence, so
      it names the four steps in the colours the graph draws them in. The point of
      the last line is that a bad order is not a mystery: it is energy that went
      somewhere other than the ball.
    */
    private var firingOrderInfoSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tok.s4) {
                HStack(alignment: .top) {
                    Text("Firing Order: How to Read It")
                        .font(.serif(TypeScale.title))
                        .foregroundStyle(Tok.bone)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: Tok.s3)

                    Button {
                        firingInfoOpen = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Tok.bone2)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Tok.turf800))
                            .overlay(Circle().strokeBorder(Tok.line, lineWidth: 1))
                    }
                    .buttonStyle(PressScale())
                    .accessibilityLabel("Close")
                }

                Text("The kinematic sequence shows the order in which your body segments reach peak speed during the downswing.")
                    .font(.body(TypeScale.small))
                    .foregroundStyle(Tok.bone)
                    .fixedSize(horizontal: false, vertical: true)

                Text("A good sequence looks like this:")
                    .font(.body(TypeScale.small))
                    .foregroundStyle(Tok.bone2)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Tok.s2) {
                    infoStep(1, Self.hipsColour, "Hips start the downswing.")
                    infoStep(2, Self.chestColour, "Chest follows the hips.")
                    infoStep(3, Self.armsColour, "Arms transfer energy to the club.")
                    infoStep(4, Self.clubColour, "Club peaks last, just before impact.")
                }

                Text("In the graph, each coloured line shows one segment's speed. The numbered dots mark when each segment peaks.")
                    .font(.body(TypeScale.small))
                    .foregroundStyle(Tok.bone)
                    .fixedSize(horizontal: false, vertical: true)

                Text("If the order is different, energy is lost. Your swing's own order is written out below the graph.")
                    .font(.body(TypeScale.small))
                    .foregroundStyle(Tok.bone)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    firingInfoOpen = false
                } label: {
                    Text("Done")
                        .font(.body(TypeScale.small, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .foregroundStyle(Tok.ink)
                        .background(Capsule().fill(Tok.citrus))
                }
                .buttonStyle(PressScale())
                .padding(.top, Tok.s2)

                Spacer(minLength: 0)
            }
            .padding(Tok.s4)
        }
        .background(Tok.turf900.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func infoStep(_ number: Int, _ colour: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Tok.s3) {
            Text("\(number)")
                .font(.data(TypeScale.nano))
                .foregroundStyle(Tok.ink)
                .frame(width: 18, height: 18)
                .background(Circle().fill(colour))
            Text(text)
                .font(.body(TypeScale.small))
                .foregroundStyle(Tok.bone)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // Everything the checklist found, numbered, with its category.
    private func faultListCard(_ faults: [DiagnosisFaultSummary]) -> some View {
        VStack(alignment: .leading, spacing: Tok.s3) {
            Text("EVERYTHING THE CHECKLIST FOUND")
                .font(.data(TypeScale.nano))
                .tracking(1.5)
                .foregroundStyle(Tok.bone3)

            if faults.isEmpty {
                Text("Nothing to report, this was a clean swing.")
                    .font(.body(TypeScale.small))
                    .foregroundStyle(Tok.bone2)
            } else {
                ForEach(Array(faults.enumerated()), id: \.offset) { index, fault in
                    HStack(alignment: .top, spacing: Tok.s3) {
                        Text(String(format: "%02d", index + 1))
                            .font(.data(TypeScale.nano))
                            .foregroundStyle(Tok.bone3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(fault.headline)
                                .font(.body(TypeScale.small))
                                .foregroundStyle(Tok.bone)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(fault.category.label)
                                .font(.data(TypeScale.nano))
                                .foregroundStyle(Self.categoryColour(fault.category))
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .card()
    }

    // MARK: Diagnostic report

    /*
      What the engine could and could not measure, where the coaching positions
      landed, and the diagnosis itself. This is the honesty surface: a metric the
      camera angle could not read is named as such rather than quietly scored.
    */
    @ViewBuilder
    private var diagnosticReportSection: some View {
        if let swing, swing.validity != nil || swing.phases != nil || swing.diagnosis != nil {
            VStack(alignment: .leading, spacing: Tok.s3) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { diagnosticOpen.toggle() }
                } label: {
                    HStack {
                        Text(diagnosticOpen ? "Hide the diagnostic report" : "Show the diagnostic report")
                            .font(.body(TypeScale.small))
                            .foregroundStyle(Tok.bone)
                        Spacer()
                        Image(systemName: diagnosticOpen ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Tok.bone3)
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 18)
                    .overlay { RoundedRectangle(cornerRadius: Tok.rLg, style: .continuous).strokeBorder(Tok.line, lineWidth: 1) }
                }
                .buttonStyle(PressScale())

                if diagnosticOpen {
                    /*
                      Coaching positions first, then what the camera could and
                      could not read.

                      That order matches how the report is used: the positions say
                      where in the swing the engine landed, and the measured card
                      then qualifies every number above it. The raw diagnostic data
                      card that used to sit last is gone; it printed the fault id
                      and a fault count, which are engine internals a golfer has no
                      use for and which the headline already says in plain words.
                    */
                    if let phases = swing.phases {
                        coachingPositionsCard(phases)
                    }
                    if let measured = swing.validity?.measured {
                        measuredCard(measured)
                    }
                }
            }
            .padding(.top, Tok.s3)
        }
    }

    private func measuredCard(_ measured: MeasuredSet) -> some View {
        VStack(alignment: .leading, spacing: Tok.s3) {
            Text("WHAT COULD AND COULD NOT BE MEASURED")
                .font(.data(TypeScale.nano))
                .tracking(1.5)
                .foregroundStyle(Tok.bone3)

            ForEach(Self.measuredOrder, id: \.self) { key in
                if let m = measured[key] {
                    HStack {
                        Text(Self.measuredLabel(key))
                            .font(.body(TypeScale.small))
                            .foregroundStyle(Tok.bone)
                        Spacer()
                        Text(m.valid ? "measured" : Self.unmeasuredReason(m.why))
                            .font(.data(TypeScale.nano))
                            .foregroundStyle(m.valid ? Tok.fairwayLit : Tok.bone3.opacity(0.8))
                    }
                }
            }

            Text("Anything not measured is left out of the score entirely rather than counted as bad.")
                .font(.body(TypeScale.micro))
                .foregroundStyle(Tok.bone3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .card()
    }

    private func coachingPositionsCard(_ phases: PhaseSummary) -> some View {
        VStack(alignment: .leading, spacing: Tok.s2) {
            Text("COACHING POSITIONS")
                .font(.data(TypeScale.nano))
                .tracking(1.5)
                .foregroundStyle(Tok.bone3)
                .padding(.bottom, 2)

            ForEach(Self.coachingPositions, id: \.key) { entry in
                HStack(spacing: Tok.s3) {
                    Text(entry.key.uppercased())
                        .font(.data(TypeScale.nano))
                        .foregroundStyle(Tok.bone3)
                        .frame(width: 28, alignment: .leading)
                    Text(entry.label)
                        .font(.body(TypeScale.small))
                        .foregroundStyle(Tok.bone)
                    Spacer()
                    if let frame = phases.idx[entry.key] {
                        Text("frame \(frame)")
                            .font(.data(TypeScale.nano))
                            .foregroundStyle(Tok.bone3)
                    } else {
                        Text("not found")
                            .font(.data(TypeScale.nano))
                            .foregroundStyle(Tok.bone3.opacity(0.6))
                    }
                }
            }
        }
        .card()
    }

    // MARK: Breakdown lookups

    private static func segmentLabel(_ key: String) -> String {
        switch key {
        case "pelvis": return "Hips"
        case "torso": return "Chest"
        case "arm": return "Lead arm"
        case "club": return "Club"
        default: return key.capitalized
        }
    }

    private static func segmentColour(_ key: String) -> Color {
        switch key {
        case "pelvis": return Tok.catSequencing
        case "torso": return Tok.catRotation
        case "arm": return Tok.catBalance
        case "club": return Tok.catFinish
        default: return Tok.bone3
        }
    }

    // MARK: Firing order graph

    /*
      The graph's own four colours, fixed here rather than pulled from the
      category tokens.

      The category tokens carry a meaning already, which is sequencing, rotation,
      balance and finish. Reusing them on this chart would say that the pelvis
      curve is about sequencing and the torso curve is about rotation, which is
      not what the lines are. These four are just the four segments, in the
      hips blue, chest magenta, arms orange, club green order.
    */
    private static let hipsColour = Color(hex: "#4C8DFF")
    private static let chestColour = Color(hex: "#E45FC8")
    private static let armsColour = Color(hex: "#FF9430")
    private static let clubColour = Color(hex: "#5CD67A")

    /*
      Reduce the four speed series to curves, peaks and a frame span.

      Everything is clamped to the shortest series and to the window, so a series
      that came back a frame short cannot crash the chart. A segment whose peak in
      the window is zero is dropped rather than drawn as a flat line at the floor,
      because a flat line reads as a measurement and it is not one.

      Numbering follows the engine's observed order where the engine named the
      segment, so the dots on the graph and the numbered reading underneath agree
      by construction. Where it did not, the fallback numbers by when the curve
      actually peaked, which is the same rule the engine applies.
    */
    private static func buildSequenceChart(
        pelvis: [Double],
        torso: [Double],
        arm: [Double],
        club: [Double],
        window: ClosedRange<Int>?,
        observedOrder: [String]
    ) -> SequenceChartData {
        let sources: [(key: String, label: String, colour: Color, values: [Double])] = [
            (key: "pelvis", label: "Hips", colour: hipsColour, values: pelvis),
            (key: "torso", label: "Chest", colour: chestColour, values: torso),
            (key: "arm", label: "Arms", colour: armsColour, values: arm),
            (key: "club", label: "Club", colour: clubColour, values: club),
        ]

        let shortest = sources.map { $0.values.count }.min() ?? 0
        guard shortest > 1 else { return SequenceChartData() }

        let lower = max(0, window?.lowerBound ?? 0)
        let upper = min(shortest - 1, window?.upperBound ?? (shortest - 1))
        guard upper > lower else { return SequenceChartData() }

        var built: [(key: String, label: String, colour: Color, points: [SequencePoint], peakFrame: Int)] = []

        for source in sources {
            let slice = Array(source.values[lower...upper])
            guard let peak = slice.enumerated().max(by: { $0.element < $1.element }),
                  peak.element > 0 else { continue }
            let points = slice.enumerated().map { offset, value in
                SequencePoint(frame: offset, value: value / peak.element)
            }
            built.append((
                key: source.key,
                label: source.label,
                colour: source.colour,
                points: points,
                peakFrame: peak.offset
            ))
        }

        guard !built.isEmpty else { return SequenceChartData() }

        var fallback: [String: Int] = [:]
        for (index, item) in built.sorted(by: { $0.peakFrame < $1.peakFrame }).enumerated() {
            fallback[item.key] = index + 1
        }

        var data = SequenceChartData()
        data.span = upper - lower
        data.curves = built.map { item in
            SequenceCurve(id: item.key, label: item.label, colour: item.colour, points: item.points)
        }
        data.peaks = built.map { item in
            let rank = observedOrder.firstIndex(of: item.key).map { $0 + 1 } ?? fallback[item.key] ?? 0
            return SequencePeakMark(
                id: item.key,
                colour: item.colour,
                frame: item.peakFrame,
                value: 1,
                rank: rank
            )
        }
        return data
    }

    private static func categoryColour(_ key: CategoryKey) -> Color {
        switch key {
        case .sequencing: return Tok.catSequencing
        case .rotation: return Tok.catRotation
        case .balance: return Tok.catBalance
        case .finish: return Tok.catFinish
        }
    }

    private static let measuredOrder: [String] = [
        "shoulderTurn", "hipTurn", "separation", "stretch", "tempo",
        "headSway", "spineDrift", "finishPressure", "pressureShift",
    ]

    private static func measuredLabel(_ key: String) -> String {
        switch key {
        case "shoulderTurn": return "Shoulder Turn"
        case "hipTurn": return "Hip Turn"
        case "separation": return "Separation"
        case "stretch": return "Stretch"
        case "tempo": return "Tempo"
        case "headSway": return "Head Sway"
        case "spineDrift": return "Spine Drift"
        case "finishPressure": return "Finish Pressure"
        case "pressureShift": return "Pressure Shift"
        default: return key
        }
    }

    // The engine's own reason, so the card says why rather than guessing.
    private static func unmeasuredReason(_ why: String?) -> String {
        guard let why else { return "unmeasured" }
        return why.replacingOccurrences(of: "-", with: " ")
    }

    private static let coachingPositions: [(key: String, label: String)] = [
        ("p1", "Address"),
        ("p2", "Takeaway"),
        ("p3", "Lead arm parallel"),
        ("p4", "Top"),
        ("p5", "Transition"),
        ("p6", "Delivery"),
        ("p7", "Impact"),
        ("p8", "Release"),
        ("p9", "Follow through"),
        ("p10", "Finish"),
    ]

    @ViewBuilder
    private var drillCard: some View {
        if let drill = swing?.diagnosis?.drill, !drill.isEmpty {
            Button {
                drillSheetOpen = true
            } label: {
                HStack(spacing: Tok.s3) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("YOUR DRILL")
                            .font(.data(TypeScale.nano))
                            .tracking(1)
                            .foregroundStyle(Tok.bone3)
                        Text(drillTitle(drill))
                            .font(.body(TypeScale.body))
                            .foregroundStyle(Tok.bone)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tok.bone3)
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous).fill(Tok.turf800))
                .overlay {
                    RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                        .strokeBorder(Tok.line, lineWidth: 1)
                }
            }
            .buttonStyle(PressScale())
            .padding(.top, Tok.s3)
        }
    }

    // A drill id like "step-change" reads as "Step change".
    private func drillTitle(_ id: String) -> String {
        let words = id.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    @ViewBuilder
    private var drillDetail: some View {
        let drill = swing?.diagnosis?.drill ?? ""
        let cue = swing?.diagnosis?.faultId.flatMap {
            Cues.cueFor(faultId: $0, category: swing?.diagnosis?.category, swingCount: store.swings.count)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: Tok.s4) {
                HStack {
                    Text(drillTitle(drill))
                        .font(.serif(TypeScale.title))
                        .foregroundStyle(Tok.bone)
                    Spacer()
                    Button("Done") { drillSheetOpen = false }
                        .font(.body(TypeScale.small, weight: .semibold))
                        .foregroundStyle(Tok.citrus)
                }

                if let cue {
                    drillBlock(title: "THE FEEL", body: cue.cue)
                    drillBlock(title: "SET IT UP", body: cue.constraint)
                    drillBlock(title: "WHY", body: cue.internal_)
                } else if let headline = swing?.diagnosis?.headline {
                    drillBlock(title: "WHY", body: headline)
                }
            }
            .padding(Tok.s4)
        }
        .background(Tok.turf900.ignoresSafeArea())
    }

    private func drillBlock(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.data(TypeScale.nano))
                .tracking(1.5)
                .foregroundStyle(Tok.bone3)
            Text(body)
                .font(.body(TypeScale.small))
                .foregroundStyle(Tok.bone)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func categoryRow(_ category: CategoryKey) -> some View {
        HStack {
            Text(category.label)
                .font(.body(TypeScale.small))
                .foregroundStyle(Tok.bone)
            Spacer()
            Text(scoreText(for: category))
                .font(.data(TypeScale.small))
                .foregroundStyle(scoreColour(for: category))
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous).fill(Tok.turf800))
        .overlay {
            RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                .strokeBorder(Tok.line, lineWidth: 1)
        }
    }

    private func scoreText(for category: CategoryKey) -> String {
        guard let value = swing?.scores?.score(for: category) else { return "Not yet" }
        return "\(value)"
    }

    private func scoreColour(for category: CategoryKey) -> Color {
        swing?.scores?.score(for: category) == nil ? Tok.bone3 : Tok.citrus
    }
}

// MARK: - Share sheet bridge

/*
  A minimal bridge to UIActivityViewController for sharing a file URL.

  SwiftUI's ShareLink is the modern route, but it wants a Transferable and a
  declared binding, which is more ceremony than a single "share this file" call
  from a menu. This reaches the active window's root and presents the system
  share sheet, which is what the web build's share() does through the Web Share
  API. It finds the topmost presented controller so the sheet is not presented on
  a controller that is already covered.

  That last part is why the fullscreen viewer can call this too. The viewer is
  presented in a fullScreenCover, so the root controller is already covered, and
  presenting on it would raise rather than show a sheet.
*/
enum Sharing {
    @MainActor
    static func present(url: URL) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.flatMap(\.windows).first(where: { $0.isKeyWindow }) ?? scenes.first?.windows.first else {
            return
        }
        var top = window.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // The iPad popover needs an anchor, or it raises rather than presenting.
        if let pop = activity.popoverPresentationController, let view = top?.view {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top?.present(activity, animated: true)
    }
}
