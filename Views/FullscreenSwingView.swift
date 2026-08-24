//
//  FullscreenSwingView.swift
//  Swingline
//
//  The fullscreen swing viewer. A direct port of the web FullscreenSwing.jsx
//  layout: a black immersive stage with the video centred, every overlay pinned
//  to it on one shared frame index, and the chrome, top bar, side docks, scrubber,
//  transport and metric strip, arranged exactly where the web places them.
//
//  THE FIT BOX, WHICH IS ALSO THE PART 11 FIX
//
//  The web build measures the real on screen rectangle the letterboxed video
//  occupies and pins the skeleton and traces to that exact box, through fitBox.
//  The old iOS analysis panel did not: it forced the whole stack to 9:16 and let
//  the overlays draw across the full forced frame while the video letterboxed
//  inside it under objectFit contain. When the clip was not 9:16, the skeleton
//  stretched across the padded box while the body sat in the letterboxed video,
//  so the two did not line up. That is the skeleton looking off.
//
//  This view computes the same fit box from the video's true aspect ratio and
//  places the video and all overlays inside one container of exactly that size,
//  centred in the stage. The overlays draw in the same 0 to 1 space the video
//  occupies, so the skeleton sits on the body at every device size and every clip
//  aspect. There is no forced aspect on the overlays anywhere.
//
//  CHROME
//
//  Tap the stage to toggle the chrome, matching the web. Close is the one control
//  that never hides, because the way out must always be present. Everything else,
//  the top tools, the docks, the scrubber, the transport and the metrics, fades
//  with the chrome so a tap clears the swing to just the body.
//
//  WHAT THIS PASS ADDED
//
//  1. THE FINISH CAP. finishFrame is P10, handed down to the trace overlay so
//     the hand path and the club head path stop at the finish instead of
//     scribbling over the last second of the clip.
//
//  2. THE BALL FLIGHT GATE. Ball flight is not finished, so for everyone except
//     a beta founder the row explains itself instead of drawing a half built
//     layer. The gate is applied in two places on purpose: the toggle refuses to
//     turn on, and the overlay refuses to draw. One without the other leaks,
//     because showBallFlight is shared with the analysis screen and could
//     already be true from a session where the flag was on.
//
//  3. SHARE, FOR REAL. It exports a copy of the clip with whatever layers are
//     switched on burned into the pixels, then opens the system share sheet. The
//     encode lives in OverlayExporter. If it fails for any reason the clip
//     itself is shared rather than the tap doing nothing, because a golfer who
//     asked to share a swing should end up at a share sheet.
//
//  4. TRIM, IN HERE. It used to close the viewer and hand off to the analysis
//     screen's sheet. It now opens its own sheet over the stage, with a
//     filmstrip and two handles, and reports the chosen range through
//     onTrimRange. The re export itself still belongs to the analysis screen,
//     which owns the store and therefore the swap of one clip for another.
//
//  WHAT IS REAL AND WHAT IS A LABELLED PLACEHOLDER
//
//  Playback, scrubbing, speed, loop, frame step, skeleton and trace toggles,
//  hide and show metrics, edit metrics, share and trim are all wired to real
//  state. The line and text drawing tools, and ball flight for everyone outside
//  the beta, are labelled placeholders that say so when tapped.
//
//  House rule: no em dashes anywhere.
//

import SwiftUI
import AVFoundation
import UIKit
import Photos

struct FullscreenSwingView: View {

    // Data, all read only. The frame index is the one clock.
    let frames: [Frame]
    let handSeries: FrameSeries?
    let clubSeries: FrameSeries?
    let topFrame: Int?
    /*
      P10, the finish. Both swing traces stop here, so the overlay does not carry
      on drawing while the golfer lowers the club and walks off. Nil means the
      phase detector did not find a finish, and the traces run as they used to.
    */
    var finishFrame: Int? = nil
    let videoURL: URL?
    let mirrored: Bool
    let metricSource: MetricSource?

    @Bindable var playback: PlaybackState
    @Binding var selectedMetrics: [String]
    // The second customisable metric page. Bar 1 is selectedMetrics above.
    @Binding var metricsBar2: [String]
    @Binding var isPresented: Bool
    /*
      The overlay layers, owned by the analysis screen so both views draw the same
      thing. Switching a layer off in the plus menu here keeps it off out there.
    */
    @Binding var showSkeleton: Bool
    @Binding var showHandPath: Bool
    @Binding var showClubPath: Bool
    @Binding var showBallFlight: Bool
    @Binding var showSpine: Bool
    // The shared skeleton style, so the fullscreen figure and its angle arcs
    // match the analysis screen rather than falling back to the plain style.
    var skeleton: SkeletonSettings? = nil
    var ballTrajectory: [CGPoint] = []
    /*
      The beta founder flag out of AppSettings, passed in rather than read here,
      because this view does not own the store and the analysis screen already
      does. It is the only thing standing between a golfer and an unfinished
      ball flight layer, so it is read in one place and used in two.
    */
    var betaFounder: Bool = false

    /*
      The 3D figure and the kinematic sequence live here now.

      They used to sit above the video on the analysis screen, which put two
      abstractions in front of the clip. This viewer is where a golfer goes to
      study, so it owns the advanced panels and the analysis screen stays clip
      first. The scene state is passed in rather than rebuilt, so the figure and
      the video stay on the one frame index.
    */
    var sceneID: String = "none"
    var anchor: SwingAnchor = .fallback
    var handTrace3D: WorldFrameSeries?
    var clubTrace3D: WorldFrameSeries?
    var dominantHand: DominantHand = .right
    var settings3D: Skeleton3DSettings?
    var controls3D: SceneKitControls?
    var graphLines: [GraphLine] = []
    var phaseMarks: [PhaseMark] = []
    var graphWindow: ClosedRange<Int>? = nil
    /*
      Screen recording and the voice note, moved here off the inline viewport, and
      the shared drawing controller so annotations made here are the same ones the
      analysis screen shows.
    */
    var recorder: ReplayKitManager? = nil
    var onVoiceNote: (() -> Void)? = nil
    /*
      Front camera is driven from the analysis screen, which owns the store.
      Fullscreen just reports the tap, so there is no second copy of that logic
      here to drift.
    */
    var frontCameraOn: Bool = false
    var onToggleFacing: (() -> Void)? = nil
    /*
      Trim reports a range in seconds and nothing else. The viewer picks the
      range, the analysis screen runs VideoEditor.trim and swaps the clip in,
      because swapping a clip means touching the store and the store is not
      visible from here.
    */
    var onTrimRange: ((Double, Double) -> Void)? = nil
    var hasVideo: Bool = false
    var pencil: PencilKitController? = nil
    var onSaveAnnotation: (() -> Void)? = nil

    // Chrome and menu state.
    @State private var chrome = true

    @State private var showMetrics = true

    @State private var tracksOpen = false
    @State private var moreOpen = false
    @State private var layoutOpen = false
    @State private var editMetricsOpen = false

    // The ball flight placeholder notice, and the trim sheet.
    @State private var ballFlightNoticeOpen = false
    /*
      What the download just did, or nil. Shown as a banner over the stage and
      cleared on a timer, so a save that worked confirms itself and a save that
      did not says why instead of failing in silence.
    */
    @State private var downloadNotice: String?
    @State private var trimOpen = false

    // The share export. The task is held so the cancel button can reach it.
    @State private var exporting = false
    @State private var exportProgress: Double = 0
    @State private var exportTask: Task<Void, Never>? = nil

    // The video's true aspect ratio, width over height. Nil until measured, and
    // it drives the fit box that keeps the overlays on the body.
    @State private var videoAspect: CGFloat?

    // Which panel the stage is showing. All three read the same frame index, so
    // switching never disturbs the playhead.
    enum Panel: String, Hashable, CaseIterable { case video, threeD, graph }
    @State private var panel: Panel = .video
    /*
      Two panel view. When on, the stage splits and each half carries its own
      kind, so a golfer can watch the clip above the 3D figure, or either against
      the kinematic sequence. Both halves read the same frame index, so they can
      never drift apart.
    */
    // Drives the slow fade that marks a live recording. Set by recordButton.
    @State private var recordPulse = false

    /*
      Where the two panel divider sits, as the top panel's share of the stage.

      A fraction rather than a point offset so the split survives a rotation with
      its proportions intact. Clamped to the range below whenever it is dragged,
      so neither panel can be squeezed to nothing and lose its own selector with
      it. Screen state, not a setting: a golfer sizing the panels for one clip is
      not choosing a permanent layout.
    */
    @State private var splitFraction: CGFloat = 0.5
    // Live while the divider is under a finger, for the highlight.
    @State private var splitDragging = false
    /*
      The fraction the current drag started from. @GestureState so it resets
      itself to nil the moment the finger lifts, which is what makes the next drag
      latch its own starting point rather than inheriting the last one.
    */
    @GestureState private var splitStart: CGFloat?
    // Neither panel drops below a fifth of the stage.
    private static let splitRange: ClosedRange<CGFloat> = 0.2...0.8

    @State private var twoPanel = false
    @State private var panelB: Panel = .threeD
    // Drawing takes the stage's touches while it is on, so a stroke never
    // scrubs the clip or toggles chrome.
    @State private var drawingActive = false
    // A short note for tools that are not built, shown in the panel itself.
    @State private var drawNote: String? = nil
    @State private var speedSheetOpen = false

    /*
      Text tool. The sheet lives here, on a View, because a SwiftUI sheet cannot
      be raised from the controller. The draft holds what the golfer is typing,
      and the controller holds where it will land (pendingTextPoint), set either
      by tapping the Text tool or by tapping the canvas in text mode.
    */
    @State private var textSheetOpen = false
    @State private var textDraft = ""

    /*
      The custom colour, the fourth swatch. The first three swatches are the
      fixed citrus, red and blue, and this one opens a system ColorPicker so a
      coach can mark in any colour they like. It seeds from bone, the palette's
      fourth entry, so the swatch is never empty before it is first opened.
    */
    @State private var colourPickerOpen = false
    @State private var customColour: Color = PencilKitController.palette[3]

    private static let speeds: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            stage

            if chrome {
                topBar
                sideDocks
                bottomChrome
            }

            menus

            if drawingActive, let pencil {
                drawingPanel(pencil)
            }

            if exporting {
                exportPanel
            }
        }
        .onChange(of: drawingActive) { _, active in
            pencil?.isActive = active
            // Install the text input bridge while drawing is on: a tap on the
            // canvas in text mode, or on the Text tool, raises the sheet here.
            if active {
                pencil?.onRequestText = { _ in
                    textDraft = ""
                    textSheetOpen = true
                }
            } else {
                pencil?.onRequestText = nil
            }
        }
        .sheet(isPresented: $speedSheetOpen) {
            SpeedPickerView(speeds: Self.speeds, current: playback.speed) { chosen in
                playback.speed = chosen
                speedSheetOpen = false
            }
            .presentationDetents([.height(360)])
            .presentationDragIndicator(.visible)
        }
        .statusBarHidden(true)
        .onAppear { measureAspect() }
        .onDisappear { exportTask?.cancel() }
        .onChange(of: videoURL) { _, _ in measureAspect() }
        .sheet(isPresented: $editMetricsOpen) {
            MetricPicker(bar1: $selectedMetrics, bar2: $metricsBar2)
        }
        .sheet(isPresented: $trimOpen) {
            TrimSheetView(
                videoURL: videoURL,
                duration: clipDuration,
                onCancel: { trimOpen = false },
                onConfirm: { start, end in
                    trimOpen = false
                    onTrimRange?(start, end)
                }
            )
            .presentationDetents([.height(400)])
            .presentationDragIndicator(.visible)
        }
        /*
          The placeholder, said plainly. Ball flight is modelled rather than
          detected and the layer is not finished, so outside the beta this is
          what the row does. It is an alert rather than a toast because a toast
          over a black immersive stage is easy to miss.
        */
        .alert("Ball Flight Tracking", isPresented: $ballFlightNoticeOpen) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("New version coming soon. Stay tuned!")
        }
        /*
          The download result, as a banner across the top of the stage.

          A banner rather than an alert: the outcome of a save is not a question,
          so it should not need dismissing. It sits below the top bar, clear of
          the close and record buttons, and clears itself after a few seconds. A
          tap dismisses it early for anyone who has already read it.
        */
        .overlay(alignment: .top) {
            if let downloadNotice {
                Text(downloadNotice)
                    .font(.body(TypeScale.small))
                    .foregroundStyle(Tok.bone)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 18)
                    .background(
                        RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                            .fill(Color.black.opacity(0.82))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                            .strokeBorder(Tok.line, lineWidth: 1)
                    }
                    .padding(.horizontal, Tok.s5)
                    .padding(.top, 108)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { self.downloadNotice = nil }
                    .task(id: downloadNotice) {
                        try? await Task.sleep(nanoseconds: 3_200_000_000)
                        guard !Task.isCancelled else { return }
                        self.downloadNotice = nil
                    }
            }
        }
        .animation(.easeInOut(duration: 0.22), value: downloadNotice)
        /*
          The text tool's input. Typing here and tapping Done commits a label at
          the controller's pending point, in the current colour and size. The
          sheet is small and drags to dismiss, and Cancel drops the draft.
        */
        .sheet(isPresented: $textSheetOpen) {
            if let pencil {
                TextAnnotationSheet(
                    text: $textDraft,
                    colour: pencil.colour,
                    onCancel: { textSheetOpen = false },
                    onDone: {
                        pencil.commitText(textDraft)
                        textDraft = ""
                        textSheetOpen = false
                    }
                )
                .presentationDetents([.height(220)])
                .presentationDragIndicator(.visible)
            }
        }
        /*
          The fourth colour swatch's picker. Changing the colour applies it to
          every tool at once through the controller, the same path the three
          fixed swatches use.
        */
        .sheet(isPresented: $colourPickerOpen) {
            NavigationStack {
                VStack(spacing: Tok.s5) {
                    ColorPicker("Ink colour", selection: $customColour, supportsOpacity: false)
                        .font(.body(TypeScale.body))
                        .foregroundStyle(Tok.bone)
                        .padding(.horizontal, Tok.s5)
                        .padding(.top, Tok.s5)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Tok.turf800.ignoresSafeArea())
                .navigationTitle("Custom Colour")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { colourPickerOpen = false }
                            .foregroundStyle(Tok.citrus)
                    }
                }
            }
            .presentationDetents([.height(260)])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: customColour) { _, newColour in
            // Keep the custom swatch and the active ink in step: dragging the
            // picker recolours the tool live.
            pencil?.setColour(newColour)
        }
    }

    // MARK: - Stage

    /*
      The video and its overlays, centred and sized to the fit box.

      GeometryReader gives the available stage size. fitBox picks the largest
      rectangle of the video's aspect that fits inside it. The video and every
      overlay live in one ZStack of exactly that size, so a normalised landmark at
      x 0.5 lands on the centre of the picture, not the centre of the padded
      screen.
    */
    private var stage: some View {
        GeometryReader { geo in
            Group {
                if twoPanel {
                    /*
                      Two stages with a divider the golfer can drag.

                      A fixed half and half split assumes both panels deserve the
                      same room, which they rarely do: studying the 2D overlay
                      against the video wants most of the screen, and the 3D figure
                      or the sequence strip is a reference glance. The split is a
                      fraction of the stage rather than a point offset, so it holds
                      its proportion through a rotation instead of leaving one
                      panel nearly closed.
                    */
                    let bar: CGFloat = 22
                    let usable = max(0, geo.size.height - bar)
                    let topHeight = usable * splitFraction
                    let bottomHeight = usable - topHeight
                    VStack(spacing: 0) {
                        panelContent($panel, in: CGSize(width: geo.size.width, height: topHeight))
                            .frame(width: geo.size.width, height: topHeight)
                            .clipped()
                        splitHandle(stageHeight: usable, barHeight: bar)
                        panelContent($panelB, in: CGSize(width: geo.size.width, height: bottomHeight))
                            .frame(width: geo.size.width, height: bottomHeight)
                            .clipped()
                    }
                } else {
                    panelContent($panel, in: geo.size)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay {
                if let pencil {
                    PencilCanvas(controller: pencil)
                        .allowsHitTesting(drawingActive && pencil.shapeMode == .none)
                    if drawingActive && pencil.shapeMode != .none {
                        ShapeOverlay(controller: pencil)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // A tap while drawing belongs to the canvas, not the chrome.
                guard !drawingActive else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    chrome.toggle()
                    if !chrome { closeAllMenus() }
                }
            }
        }
        .ignoresSafeArea()
    }

    /*
      One panel's content, sized to the space it has been given.

      Shared by the single and split layouts so the two can never render the clip
      differently. The video keeps its aspect through fitBox, while the figure and
      the graph fill what they are given.
    */
    @ViewBuilder
    private func panelContent(_ kind: Binding<Panel>, in size: CGSize) -> some View {
        ZStack {
            switch kind.wrappedValue {
            case .video:
                let box = fitBox(in: size)
                ZStack {
                    VideoPlayerView(videoURL: videoURL, playback: playback)

                    if showSkeleton {
                        SkeletonOverlay(
                            frames: frames,
                            frameIndex: playback.frameIndex,
                            mirrored: mirrored,
                            showSpine: showSpine,
                            settings: skeleton
                        )
                    }

                    TraceOverlay(
                        handSeries: showHandPath ? handSeries : nil,
                        clubSeries: showClubPath ? clubSeries : nil,
                        frameIndex: playback.frameIndex,
                        topFrame: topFrame,
                        endFrame: finishFrame,
                        mirrored: mirrored,
                        ballTrajectory: drawsBallFlight ? ballTrajectory : nil
                    )
                }
                .frame(width: box.width, height: box.height)
                .clipped()

            case .threeD:
                scenePanel

            case .graph:
                graphPanel
            }
        }
        .frame(width: size.width, height: size.height)
        // One button, vertically centred on the left edge of this panel. The
        // HStack with a trailing Spacer pins it to the left while the centre
        // alignment of the overlay keeps it vertically centred. A tap cycles 2D,
        // 3D, SEQ for this panel alone. Hidden with the chrome, inert while
        // drawing.
        .overlay {
            if chrome && !drawingActive {
                HStack {
                    Button {
                        cyclePanel(&kind.wrappedValue)
                    } label: {
                        Text(label(for: kind.wrappedValue))
                            .font(.data(TypeScale.nano))
                            .foregroundStyle(Tok.bone)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Tok.ink.opacity(0.65)))
                            .overlay(Capsule().strokeBorder(Tok.line, lineWidth: 1))
                    }
                    .buttonStyle(PressScale())
                    .padding(.leading, 14)
                    .accessibilityLabel("\(label(for: kind.wrappedValue)) panel, tap to change")

                    Spacer()
                }
            }
        }
    }

    private func label(for kind: Panel) -> String {
        switch kind {
        case .video: return "2D"
        case .threeD: return "3D"
        case .graph: return "SEQ"
        }
    }

    private func cyclePanel(_ kind: inout Panel) {
        switch kind {
        case .video: kind = .threeD
        case .threeD: kind = .graph
        case .graph: kind = .video
        }
    }

    /*
      The 3D figure.

      Reads the same frames and frame index as the video, so turning the figure
      never desynchronises it from the clip. The SKETCH badge is kept: the solid
      rig is a reading of a handful of tracked points, not a measurement of a
      body, and the web build recorded exactly why that distinction matters.

      Rebuilt on identity when the swing or the visual options change, because
      those mean a different scene. Frame index changes do not appear in the id,
      since those are cheap in place updates.
    */
    private var scenePanel: some View {
        ZStack(alignment: .topLeading) {
            if let settings3D, let controls3D {
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
                    showConnectingLines: skeleton?.showConnectingLines ?? true,
                    hiddenLineJoints: skeleton?.hiddenLineJoints ?? [],
                    controls: controls3D,
                    isUnlocked: settings3D.isUnlocked
                )
                .id("\(sceneID)-\(settings3D.paletteName)-\(settings3D.showTraces)-\(settings3D.showGrid)")
            } else {
                Color.clear
            }

            Text("SKETCH")
                .font(.data(TypeScale.nano))
                .tracking(1)
                .foregroundStyle(Tok.bone2)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Tok.ink.opacity(0.55)))
                .overlay(Capsule().strokeBorder(Tok.line, lineWidth: 1))
                .padding(Tok.s3)
        }
    }

    /*
      The kinematic sequence.

      Windowed to the downswing by the caller, which is the only span where the
      firing order is legible. An empty set of lines means the swing had no
      usable sequence, and it says so rather than drawing an empty axis.
    */
    private var graphPanel: some View {
        Group {
            if graphLines.isEmpty {
                Text("No kinematic sequence for this swing.")
                    .font(.body(TypeScale.small))
                    .foregroundStyle(Tok.bone3)
            } else {
                KinematicGraph(
                    lines: graphLines,
                    phaseMarks: phaseMarks,
                    frameCount: frames.count,
                    playback: playback,
                    window: graphWindow
                )
                .padding(.horizontal, Tok.s3)
            }
        }
    }

    /* The largest rectangle of the video's aspect that fits the stage. Falls back
       to a portrait 9:16 only when the aspect is not yet known, which matches the
       old default but is replaced the moment the video reports its real size. */
    private func fitBox(in size: CGSize) -> CGSize {
        let aspect = videoAspect ?? (9.0 / 16.0)
        guard size.width > 0, size.height > 0, aspect > 0 else { return size }
        let boxByWidth = CGSize(width: size.width, height: size.width / aspect)
        if boxByWidth.height <= size.height {
            return boxByWidth
        }
        return CGSize(width: size.height * aspect, height: size.height)
    }

    private func measureAspect() {
        guard let videoURL else {
            videoAspect = nil
            return
        }
        Task {
            let asset = AVURLAsset(url: videoURL)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let natural = try? await track.load(.naturalSize),
                  let transform = try? await track.load(.preferredTransform) else {
                return
            }
            // Apply the preferred transform, so a portrait clip recorded sideways
            // reports portrait rather than landscape.
            let resolved = natural.applying(transform)
            let w = abs(resolved.width)
            let h = abs(resolved.height)
            guard w > 0, h > 0 else { return }
            await MainActor.run { videoAspect = w / h }
        }
    }

    // MARK: - Layer state

    /*
      Whether the ball flight layer actually draws.

      Three conditions, and the beta flag is one of them rather than being
      checked only at the toggle. showBallFlight is shared with the analysis
      screen and persists across a settings change, so without this a golfer who
      switched the layer on as a beta founder would keep seeing it after the flag
      came off.
    */
    private var drawsBallFlight: Bool {
        showBallFlight && betaFounder && !ballTrajectory.isEmpty
    }

    // Anything switched on that would change the picture. Nothing on means the
    // share is just the clip, and there is no reason to spend an encode on it.
    private var anyOverlayOn: Bool {
        showSkeleton || showSpine
            || (showHandPath && handSeries != nil)
            || (showClubPath && clubSeries != nil)
            || drawsBallFlight
    }

    private var clipDuration: Double {
        max(0.1, playback.durationMs / 1000)
    }

    // MARK: - Top bar

    /*
      Close on the left, always visible in the ZStack but the whole top bar only
      shows with the chrome, matching the web where Close persists but the gradient
      and the right hand tools ride with the chrome. Kept simple here: the whole
      bar is inside the chrome branch, and Close is also mirrored into a always on
      affordance below so there is never no way out.
    */
    private var topBar: some View {
        VStack {
            HStack {
                iconButton(system: "xmark.circle") {
                    isPresented = false
                }

                Spacer()

                /*
                  Record, and while recording, a stop beside it.

                  One button that swapped its own glyph between record and stop
                  asked the golfer to read an icon mid take to know what a tap
                  would do, and a mistaken tap either loses the take or fails to
                  end it. Now the record button simply turns red and stays put as
                  the state indicator, and a separate square stop appears to its
                  right as the only control that ends the take. Start and stop are
                  never the same target, so neither can be hit by accident. There
                  is no pause: start, stop, save, which is what stopToURL already
                  does.
                */
                if let recorder {
                    recordButton(recorder)
                    if recorder.isRecording {
                        stopRecordingButton(recorder)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                if let onToggleFacing {
                    iconButton(
                        system: "arrow.triangle.2.circlepath.camera",
                        active: frontCameraOn
                    ) { onToggleFacing() }
                }

                iconButton(system: "plus.circle", active: tracksOpen) {
                    tracksOpen.toggle()
                    layoutOpen = false
                    moreOpen = false
                }
                iconButton(system: "ellipsis", active: moreOpen) {
                    moreOpen.toggle()
                    tracksOpen = false
                    layoutOpen = false
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()
        }
        .background(
            VStack {
                LinearGradient(
                    colors: [Color.black.opacity(0.55), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 120)
                Spacer()
            }
            .allowsHitTesting(false)
        )
    }

    // MARK: - Side docks

    // The 2D panel pill on the left, the pencil on the right, both just under the
    // top bar, exactly where the web places them.
    private var sideDocks: some View {
        VStack {
            HStack(alignment: .top) {
                // The panel selector moved onto each panel as a centred cycling
                // button, so the dock now holds only the drawing control.
                Spacer()

                Button {
                    drawingActive.toggle()
                    if !drawingActive { onSaveAnnotation?() }
                } label: {
                    Image(systemName: "pencil.tip.crop.circle")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(drawingActive ? Tok.citrus : Tok.bone2)
                        .frame(width: 34, height: 34)
                        .glass(radius: 9, border: Tok.glassEdge)
                }
                .buttonStyle(PressScale())
            }
            .padding(.horizontal, 14)
            .padding(.top, 64)

            Spacer()
        }
    }

    // MARK: - Bottom chrome

    private var bottomChrome: some View {
        VStack(spacing: 0) {
            Spacer()

            // The drawing toolbar sits above the transport while drawing, so the
            // tools are reachable without leaving the stage.
            // Scrubber, full width.
            scrubber
                .padding(.horizontal, 16)
                .padding(.bottom, 4)

            // Transport row.
            transport
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            // Metrics strip. Always First always has cards, so this shows even
            // when both custom pages are empty.
            if showMetrics, let metricSource {
                MetricsBar(
                    source: metricSource,
                    frameIndex: playback.frameIndex,
                    selected: selectedMetrics,
                    bar2: metricsBar2,
                    layout: .pages
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
        }
        .background(
            LinearGradient(
                colors: [.clear, Color.black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        )
    }

    private var scrubber: some View {
        Slider(
            value: Binding(
                get: { Double(playback.frameIndex) },
                set: { playback.pause()
                playback.seek(toFrame: Int($0.rounded())) }
            ),
            in: 0...Double(max(1, playback.frameCount - 1)),
            step: 1
        )
        .tint(Tok.citrus)
    }

    private var transport: some View {
        HStack {
            // Speed and loop, left.
            HStack(spacing: 14) {
                Button {
                    speedSheetOpen = true
                } label: {
                    Text(speedLabel)
                        .font(.body(TypeScale.small, weight: .bold))
                        .foregroundStyle(Tok.bone)
                }

                Button {
                    playback.loop.toggle()
                } label: {
                    Image(systemName: "repeat")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(playback.loop ? Tok.citrus : Tok.bone3)
                }
            }

            Spacer()

            // Step, play, step, centre.
            HStack(spacing: 18) {
                stepButton(system: "backward.frame") {
                    playback.pause()
                    playback.seek(toFrame: max(0, playback.frameIndex - 1))
                }
                Button {
                    playback.togglePlay()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Tok.bone)
                }
                stepButton(system: "forward.frame") {
                    playback.pause()
                    playback.seek(toFrame: min(playback.frameCount - 1, playback.frameIndex + 1))
                }
            }

            Spacer()

            // Layout, right.
            Button {
                layoutOpen.toggle()
                tracksOpen = false
                moreOpen = false
            } label: {
                Text("Layout")
                    .font(.data(TypeScale.small))
                    .foregroundStyle(Tok.bone2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glass(radius: 8, border: Tok.glassEdge)
            }
            .buttonStyle(PressScale())
        }
    }

    private var speedLabel: String {
        let s = playback.speed
        if s == s.rounded() { return "\(Int(s))x" }
        return "\(s.formatted(.number.precision(.fractionLength(0...2))))x"
    }

    // MARK: - Menus

    @ViewBuilder
    private var menus: some View {
        // Tracking layers, below the top bar on the left.
        if tracksOpen {
            popover(top: 64, leading: 16) {
                switchRow(title: "Skeleton", on: showSkeleton) { showSkeleton.toggle() }
                switchRow(
                    title: "Hand path",
                    hint: handSeries == nil ? "No hand path for this swing" : nil,
                    on: showHandPath,
                    disabled: handSeries == nil
                ) { showHandPath.toggle() }
                /*
                  The club head line is projected from the lead forearm, not
                  detected. It used to say so by being dashed, and this pass made
                  it solid so it reads as part of the same drawing as the hand
                  path. The claim did not get dropped, it moved here, where it is
                  in words rather than in a dash pattern a golfer has to know how
                  to read.
                */
                switchRow(
                    title: "Club head",
                    hint: clubSeries == nil ? "No club path for this swing" : "Estimated from the lead arm",
                    on: showClubPath,
                    disabled: clubSeries == nil
                ) { showClubPath.toggle() }
                switchRow(
                    title: "Ball flight",
                    hint: ballFlightHint,
                    on: showBallFlight && betaFounder
                ) {
                    guard betaFounder else {
                        // Not built yet. Close the menu first, so the alert is
                        // not sitting behind a popover scrim.
                        closeAllMenus()
                        ballFlightNoticeOpen = true
                        return
                    }
                    showBallFlight.toggle()
                }
                switchRow(title: "Spine", on: showSpine) { showSpine.toggle() }
            }
        }

        // More, below the top bar on the right.
        if moreOpen {
            popover(top: 64, trailing: 16) {
                menuRow(
                    title: "Download",
                    hint: downloadHint,
                    disabled: !hasVideo || exporting
                ) {
                    moreOpen = false
                    startDownload()
                }
                if hasVideo, onTrimRange != nil {
                    menuRow(title: "Trim video", hint: "Set the start and the end") {
                        moreOpen = false
                        playback.pause()
                        trimOpen = true
                    }
                }
            }
        }

        // Layout, above the transport on the right.
        if layoutOpen {
            popover(bottom: 96, trailing: 16) {
                menuRow(title: "1 panel view", hint: "One stage", active: !twoPanel) {
                    twoPanel = false
                    layoutOpen = false
                }
                menuRow(title: "2 panel view", hint: "Two stages, one playhead", active: twoPanel) {
                    // Open the split with the figure on top and the clip below,
                    // the arrangement device testing preferred, without changing
                    // what single panel opens on.
                    panel = .threeD
                    panelB = .video
                    twoPanel = true
                    layoutOpen = false
                }
                menuRow(title: showMetrics ? "Hide metrics" : "Show metrics", hint: nil) {
                    showMetrics.toggle()
                    layoutOpen = false
                }
                menuRow(title: "Edit metrics", hint: "Choose and reorder the bar") {
                    layoutOpen = false
                    editMetricsOpen = true
                }
            }
        }
    }

    // What the ball flight row says under its title, which depends on why it
    // will or will not draw.
    private var ballFlightHint: String {
        if !betaFounder { return "Coming soon" }
        if ballTrajectory.isEmpty { return "No flight estimate for this swing" }
        return "Beta, estimated from impact"
    }

    private var downloadHint: String {
        if !hasVideo { return "No clip to save yet" }
        if anyOverlayOn { return "Save to Photos with your overlays" }
        return "Save to Photos as it was filmed"
    }

    // MARK: - Download

    /*
      Export with the overlays burned in, then save straight to Photos.

      This used to hand the file to the system share sheet. A share sheet is the
      right control when the destination is unknown, but the destination here is
      always the same: the golfer wants the clip in their camera roll, and making
      them pick "Save Video" out of a row of apps every time is a step that only
      ever has one answer. So it saves, and says whether it worked.

      Two paths, as before. Nothing switched on means the clip is already what
      the golfer is looking at, so it is copied over with no encode at all.
      Otherwise OverlayExporter redraws every frame with the layers on top, which
      takes real time on a long or high frame rate clip, so it is modal, it shows
      progress, and it can be cancelled.

      If the encode fails the plain clip is saved rather than nothing, and the
      toast says which one arrived, so the golfer is never left guessing whether
      their overlays made it.
    */
    @MainActor
    private func startDownload() {
        guard let videoURL else { return }
        playback.pause()

        guard anyOverlayOn else {
            Task { await saveToPhotos(videoURL, burned: false, temporary: false) }
            return
        }

        exportProgress = 0
        exporting = true

        let cache = OverlayFrameCache()
        exportTask = Task { @MainActor in
            defer {
                exporting = false
                exportTask = nil
            }
            do {
                let url = try await OverlayExporter.burn(
                    source: videoURL,
                    renderOverlay: { seconds, size in
                        overlayImage(atSeconds: seconds, size: size, cache: cache)
                    },
                    onProgress: { value in
                        exportProgress = value
                    }
                )
                await saveToPhotos(url, burned: true, temporary: true)
            } catch is CancellationError {
                // The golfer stopped it. Nothing to say.
            } catch {
                // Fall back to the clip rather than leaving them with nothing,
                // and say so, because a clip without the overlays is not what
                // was asked for even though it is better than a failure.
                await saveToPhotos(videoURL, burned: false, temporary: false)
            }
        }
    }

    /*
      Copy a finished file into the photo library.

      Authorisation is requested for addOnly, the narrowest scope there is: the
      app adds its own clip and never reads the library, so asking for more would
      be asking for access it has no use for. A refusal is reported rather than
      swallowed, because a golfer who declined once and forgot needs to be told
      why nothing arrived instead of tapping Download again.

      `temporary` marks a file this app made for the transfer, which is deleted
      once Photos has its own copy. The swing's own clip is never deleted, since
      the app still needs it.
    */
    @MainActor
    private func saveToPhotos(_ url: URL, burned: Bool, temporary: Bool) async {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { continuation.resume(returning: $0) }
        }

        guard status == .authorized || status == .limited else {
            if temporary { try? FileManager.default.removeItem(at: url) }
            downloadNotice = "Permission to add to Photos was declined. Turn it on in Settings to save clips."
            return
        }

        let saved = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
            } completionHandler: { success, _ in
                continuation.resume(returning: success)
            }
        }

        if temporary { try? FileManager.default.removeItem(at: url) }
        downloadNotice = saved
            ? (burned ? "Saved to Photos with your overlays." : "Saved to Photos.")
            : "Could not save to Photos."
    }

    /*
      One frame of overlay, drawn for the moment the video frame happens at.

      Drawn through the same views the stage uses, not a second drawing routine,
      because two routines would drift and the shared video is the copy that
      leaves the app and cannot be corrected afterwards.

      THE SIZE, WHICH IS THE ONE SUBTLE PART

      The overlays are laid out in points and stroked in points, so rendering
      them straight into a 1080 wide frame would give a three pixel line on a
      1080 pixel picture, which is a hair. So the view is laid out at a phone
      sized box and the renderer's scale is set to the ratio between that box and
      the output. The drawing is rasterised at full output resolution while its
      proportions stay exactly what the golfer saw on the stage.
    */
    @MainActor
    private func overlayImage(atSeconds seconds: Double, size: CGSize, cache: OverlayFrameCache) -> CGImage? {
        let index = frameIndex(atSeconds: seconds)
        if cache.index == index { return cache.image }

        let aspect = size.height > 0 ? size.width / size.height : (9.0 / 16.0)
        let boxWidth: CGFloat = 390
        let boxHeight = boxWidth / max(0.2, aspect)

        let content = ZStack {
            if showSkeleton {
                SkeletonOverlay(
                    frames: frames,
                    frameIndex: index,
                    mirrored: mirrored,
                    showSpine: showSpine,
                    settings: skeleton
                )
            }
            TraceOverlay(
                handSeries: showHandPath ? handSeries : nil,
                clubSeries: showClubPath ? clubSeries : nil,
                frameIndex: index,
                topFrame: topFrame,
                endFrame: finishFrame,
                mirrored: mirrored,
                ballTrajectory: drawsBallFlight ? ballTrajectory : nil
            )
        }
        .frame(width: boxWidth, height: boxHeight)

        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: boxWidth, height: boxHeight)
        renderer.scale = max(1, size.width / boxWidth)
        renderer.isOpaque = false

        let image = renderer.cgImage
        cache.index = index
        cache.image = image
        return image
    }

    /*
      Video time to pose frame index.

      The two clocks are the same clock read two ways: the video knows seconds,
      the overlays know a frame index. frames carries the time of every tracked
      frame, so this is a lookup rather than a multiplication by an assumed frame
      rate, which is what keeps it correct on a clip that dropped frames or was
      recorded at 240 and stored at a different rate.

      The unit is sniffed rather than assumed. Everything else in the app treats
      Frame.t as milliseconds, and this agrees with that, but a swing clip is
      never more than about fifteen seconds, so a last timestamp under a hundred
      can only be seconds. Getting this wrong would pin every exported frame to
      the address position, which is a silent and very confusing failure.
    */
    private func frameIndex(atSeconds seconds: Double) -> Int {
        guard !frames.isEmpty else { return 0 }
        guard frames.count > 1 else { return 0 }

        let last = frames[frames.count - 1].t
        let scale: Double = last > 100 ? 1000 : 1
        let target = seconds * scale

        var lo = 0
        var hi = frames.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if frames[mid].t < target { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(frames[lo - 1].t - target) <= abs(frames[lo].t - target) {
            return lo - 1
        }
        return lo
    }

    // The modal progress panel. Nothing else is reachable while it is up, which
    // is what lets the encode run on the main actor without fighting the UI.
    private var exportPanel: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { }

            VStack(spacing: Tok.s3) {
                Text("Building your video")
                    .font(.body(TypeScale.body))
                    .foregroundStyle(Tok.bone)

                Text("Drawing your overlays into every frame.")
                    .font(.body(TypeScale.micro))
                    .foregroundStyle(Tok.bone3)
                    .multilineTextAlignment(.center)

                ProgressView(value: exportProgress)
                    .tint(Tok.citrus)
                    .frame(width: 220)

                Text("\(Int(exportProgress * 100))%")
                    .font(.data(TypeScale.small))
                    .foregroundStyle(Tok.bone2)

                Button {
                    exportTask?.cancel()
                } label: {
                    Text("Cancel")
                        .font(.body(TypeScale.small))
                        .foregroundStyle(Tok.bone)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .overlay(Capsule().strokeBorder(Tok.lineStrong, lineWidth: 1))
                }
                .buttonStyle(PressScale())
                .padding(.top, 2)
            }
            .padding(Tok.s5)
            .frame(width: 280)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                    .strokeBorder(Tok.glassEdge, lineWidth: 1)
            }
        }
    }

    // MARK: - Building blocks

    /*
      The draggable divider between the two stages.

      Wider than it looks: the visible bar is a few points of line and a grip, but
      the gesture target is the full bar height, which is what makes it catchable
      without aiming. The grip is three dots, the one shape that reads as "drag
      me" without a label, and the whole bar lights citrus while it is held so the
      golfer can see which thing their finger has hold of.

      The drag is translation based, taken against the fraction the gesture began
      at rather than the live one, so a slow drag cannot accumulate rounding drift
      and creep away from the finger.
    */
    private func splitHandle(stageHeight: CGFloat, barHeight: CGFloat) -> some View {
        let active = splitDragging
        return ZStack {
            Rectangle()
                .fill(active ? Tok.citrus.opacity(0.18) : Color.white.opacity(0.04))
            VStack(spacing: 0) {
                Rectangle()
                    .fill(active ? Tok.citrus : Tok.line)
                    .frame(height: active ? 2 : 1)
            }
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(active ? Tok.citrus : Tok.bone3)
                        .frame(width: 4, height: 4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(Color.black.opacity(active ? 0.5 : 0.35))
            )
        }
        .frame(height: barHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($splitStart) { _, start, _ in
                    // Latched once per gesture, so every translation is measured
                    // from where the drag began.
                    if start == nil { start = splitFraction }
                }
                .onChanged { value in
                    guard stageHeight > 1 else { return }
                    let base = splitStart ?? splitFraction
                    let next = base + value.translation.height / stageHeight
                    splitFraction = min(max(next, Self.splitRange.lowerBound), Self.splitRange.upperBound)
                    if !splitDragging {
                        withAnimation(.easeOut(duration: 0.12)) { splitDragging = true }
                    }
                }
                .onEnded { _ in
                    withAnimation(.easeOut(duration: 0.18)) { splitDragging = false }
                }
        )
        // A double tap puts the split back to even, which is faster than
        // dragging it back by eye.
        .onTapGesture(count: 2) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                splitFraction = 0.5
            }
        }
        .accessibilityLabel("Panel divider, drag to resize")
    }

    /*
      The record button.

      Red and filled while a take is running, so the state is readable at a glance
      from across the room rather than from a glyph. It starts a take and does
      nothing else: while recording it is inert, because stopping belongs to the
      stop button beside it. A slow pulse marks it as live without the flashing
      that would fight the video behind it.
    */
    @ViewBuilder
    private func recordButton(_ recorder: ReplayKitManager) -> some View {
        let live = recorder.isRecording
        Button {
            guard !live else { return }
            recorder.start()
        } label: {
            Image(systemName: live ? "record.circle.fill" : "record.circle")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(live ? Color(red: 1, green: 0.23, blue: 0.19) : Tok.bone)
                .frame(width: 38, height: 38)
                .background(
                    Circle().fill(
                        live
                            ? Color(red: 1, green: 0.23, blue: 0.19).opacity(0.18)
                            : Color.white.opacity(0.06)
                    )
                )
                .overlay {
                    if live {
                        Circle().strokeBorder(
                            Color(red: 1, green: 0.23, blue: 0.19).opacity(0.9),
                            lineWidth: 1.5
                        )
                    }
                }
                .opacity(live && recordPulse ? 0.55 : 1)
        }
        .buttonStyle(PressScale())
        .disabled(live)
        .accessibilityLabel(live ? "Recording" : "Start screen recording")
        .onChange(of: live) { _, isLive in
            recordPulse = false
            guard isLive else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                recordPulse = true
            }
        }
    }

    /*
      Stop, and with it save.

      A square, the one shape every recorder in the world uses for stop, and it
      exists only while a take is running. stopToURL writes the finished movie and
      saves it to Photos, so this is the whole of the end of a take: no pause, no
      confirm, no editor.
    */
    private func stopRecordingButton(_ recorder: ReplayKitManager) -> some View {
        Button {
            recorder.stopToURL()
        } label: {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Tok.bone)
                .frame(width: 14, height: 14)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.white.opacity(0.14)))
        }
        .buttonStyle(PressScale())
        .accessibilityLabel("Stop recording and save to Photos")
    }

    private func iconButton(system: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(active ? Tok.citrus : Tok.bone)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.white.opacity(active ? 0.14 : 0.06)))
        }
        .buttonStyle(PressScale())
    }

    private func stepButton(system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Tok.bone2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
    }

    private func closeAllMenus() {
        tracksOpen = false
        moreOpen = false
        layoutOpen = false
    }

    // A popover anchored to one corner, dimming the rest so a tap outside closes
    // it. Positions mirror the web Popover offsets.
    private func popover<Content: View>(
        top: CGFloat? = nil,
        bottom: CGFloat? = nil,
        leading: CGFloat? = nil,
        trailing: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack(alignment: alignment(top: top, leading: leading)) {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { closeAllMenus() }

            VStack(alignment: .leading, spacing: 2) {
                content()
            }
            .padding(6)
            .frame(width: 232, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Tok.turf800.opacity(0.96))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Tok.line, lineWidth: 1)
            )
            .padding(.top, top)
            .padding(.bottom, bottom)
            .padding(.leading, leading)
            .padding(.trailing, trailing)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: alignment(top: top, leading: leading)
            )
        }
    }

    private func alignment(top: CGFloat?, leading: CGFloat?) -> Alignment {
        let vertical: VerticalAlignment = top != nil ? .top : .bottom
        let horizontal: HorizontalAlignment = leading != nil ? .leading : .trailing
        return Alignment(horizontal: horizontal, vertical: vertical)
    }

    private func menuRow(
        title: String,
        hint: String?,
        active: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
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
                if active {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Tok.citrus)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(active ? Tok.citrusDim : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    /*
      A layer row. The hint is where a layer says what it actually is, which is
      the honesty this build keeps insisting on: an estimate is labelled an
      estimate, and a layer that is not finished says so instead of drawing.
    */
    private func switchRow(
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
                // A compact pill switch, on is citrus.
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

    // MARK: - Drawing panel

    /*
      The drawing tools, as a floating panel on the right edge.

      Pen, eraser, angle and circle are the real tools, wired to the controller.
      Line and text are not built, so they say so plainly rather than pretending:
      tapping one reports it instead of silently doing nothing.
    */
    private func drawingPanel(_ pencil: PencilKitController) -> some View {
        VStack {
            Spacer(minLength: 0)
            VStack(spacing: Tok.s2) {
                panelTool("pencil.tip", "Freehand", active: pencil.shapeMode == .none && pencil.tool == .pen) {
                    pencil.selectPen()
                    drawNote = nil
                }
                panelTool("eraser", "Eraser", active: pencil.shapeMode == .none && pencil.tool == .eraser) {
                    pencil.selectEraser()
                    drawNote = nil
                }
                panelTool("angle", "Angle", active: pencil.shapeMode == .protractor) {
                    pencil.selectShape(.protractor)
                    drawNote = nil
                }
                panelTool("circle.dashed", "Circle", active: pencil.shapeMode == .circle) {
                    pencil.selectShape(.circle)
                    drawNote = nil
                }
                panelTool("line.diagonal", "Line", active: pencil.shapeMode == .line) {
                    pencil.selectShape(.line)
                    drawNote = "Tap the start, then the end."
                }
                panelTool("textformat", "Text", active: pencil.shapeMode == .text) {
                    pencil.selectShape(.text)
                    drawNote = "Tap where the text should go."
                    // Also raise the sheet straight away, seeded at the centre,
                    // so tapping the tool is enough to start typing.
                    pencil.requestText(at: CGPoint(x: 0.5, y: 0.5))
                }

                Rectangle().fill(Tok.line).frame(height: 1).padding(.vertical, 2)

                HStack(spacing: Tok.s2) {
                    panelIcon("arrow.uturn.backward", enabled: pencil.canUndo || pencil.hasShapes) {
                        if pencil.shapeMode != .none && pencil.hasShapes {
                            pencil.undoLastShape()
                        } else {
                            pencil.undo()
                        }
                    }
                    panelIcon("trash", enabled: pencil.hasInk || pencil.hasShapes) {
                        pencil.clear()
                        pencil.clearShapes()
                    }
                }

                /*
                  The colour row is universal: whichever swatch is tapped sets
                  the colour for every tool, freehand, line, protractor, circle
                  and text, through the one controller. The first three are the
                  fixed citrus, red and blue. The fourth is the custom swatch,
                  which shows the current custom colour and opens a system
                  ColorPicker so a coach can mark in any colour.
                */
                HStack(spacing: 6) {
                    ForEach(Array(PencilKitController.palette.prefix(3).enumerated()), id: \.offset) { _, colour in
                        colourSwatch(colour, selected: pencil.colour == colour) {
                            pencil.setColour(colour)
                        }
                    }

                    // Custom. The ring shows when the live colour is not one of
                    // the three fixed swatches, so a picked colour reads as the
                    // active one.
                    let usingCustom = !PencilKitController.palette.prefix(3).contains(pencil.colour)
                    Button {
                        // Adopt whatever the tool is set to, so opening the picker
                        // starts from the current colour rather than snapping away.
                        customColour = pencil.colour
                        pencil.setColour(customColour)
                        colourPickerOpen = true
                    } label: {
                        ZStack {
                            Circle()
                                .fill(customColour)
                                .frame(width: 18, height: 18)
                                .overlay {
                                    Circle().strokeBorder(
                                        usingCustom ? Tok.bone : Tok.line,
                                        lineWidth: usingCustom ? 2 : 1
                                    )
                                }
                            // A tiny plus so the swatch reads as "pick a colour"
                            // rather than a fourth preset.
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Tok.ink.opacity(0.7))
                        }
                    }
                    .buttonStyle(PressScale())
                    .accessibilityLabel("Custom colour")
                }
                .padding(.top, 2)

                if let drawNote {
                    Text(drawNote)
                        .font(.body(TypeScale.micro))
                        .foregroundStyle(Tok.bone3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    drawingActive = false
                    onSaveAnnotation?()
                } label: {
                    Text("Done")
                        .font(.data(TypeScale.nano))
                        .foregroundStyle(Tok.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Tok.citrus))
                }
                .buttonStyle(PressScale())
                .padding(.top, 2)
            }
            .padding(Tok.s3)
            .frame(width: 160)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                    .strokeBorder(Tok.glassEdge, lineWidth: 1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 12)
    }

    private func panelTool(_ system: String, _ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: system)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 16)
                Text(title)
                    .font(.body(TypeScale.micro))
                Spacer(minLength: 0)
            }
            .foregroundStyle(active ? Tok.ink : Tok.bone)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? Tok.citrus : Color.clear)
            )
        }
        .buttonStyle(PressScale())
    }

    private func panelIcon(_ system: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(enabled ? Tok.bone2 : Tok.bone3.opacity(0.4))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Tok.line, lineWidth: 1))
        }
        .buttonStyle(PressScale())
        .disabled(!enabled)
    }

    // One fixed colour swatch in the drawing panel's colour row.
    private func colourSwatch(_ colour: Color, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(colour)
                .frame(width: 18, height: 18)
                .overlay {
                    Circle().strokeBorder(
                        selected ? Tok.bone : Tok.line,
                        lineWidth: selected ? 2 : 1
                    )
                }
        }
        .buttonStyle(PressScale())
    }

}

// MARK: - Text annotation sheet

/*
  The text tool's input sheet.

  A single field and a Done button, in the app's language rather than a bare
  system alert, so a coach can type a label, see it in the colour it will land
  in, and drop it on the swing. Kept deliberately small: it is a caption, not a
  document, so it commits on Done or on the keyboard's submit.
*/
struct TextAnnotationSheet: View {
    @Binding var text: String
    var colour: Color
    var onCancel: () -> Void
    var onDone: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.s4) {
            Text("ADD TEXT")
                .font(.data(TypeScale.nano))
                .tracking(1)
                .foregroundStyle(Tok.bone3)

            TextField("Label", text: $text)
                .font(.body(TypeScale.body))
                .foregroundStyle(colour)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit { onDone() }
                .padding(.horizontal, Tok.s4)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                        .fill(Tok.turf700)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                        .strokeBorder(Tok.line, lineWidth: 1)
                )

            HStack {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.body(TypeScale.small))
                        .foregroundStyle(Tok.bone)
                        .padding(.vertical, 11)
                        .padding(.horizontal, 24)
                        .overlay(Capsule().strokeBorder(Tok.lineStrong, lineWidth: 1))
                }
                .buttonStyle(PressScale())

                Spacer()

                Button(action: onDone) {
                    Text("Done")
                        .font(.body(TypeScale.small, weight: .bold))
                        .foregroundStyle(Tok.ink)
                        .padding(.vertical, 11)
                        .padding(.horizontal, 30)
                        .background(Capsule().fill(Tok.citrus))
                }
                .buttonStyle(PressScale())
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
            }
        }
        .padding(Tok.s5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Tok.turf800.ignoresSafeArea())
        .onAppear { focused = true }
    }
}

// MARK: - Overlay frame cache

/*
  One rendered overlay, kept between calls.

  A class rather than view state on purpose. The export asks for a drawing once
  per video frame, and on a clip with more video frames than tracked frames the
  same drawing is asked for twice in a row. Holding it in @State would mean
  invalidating the view several hundred times during an export, which is exactly
  the churn the modal panel exists to avoid.
*/
final class OverlayFrameCache {
    var index: Int = -1
    var image: CGImage?
}

// MARK: - Trim sheet

/*
  Pick a start and an end, on a filmstrip of the clip.

  The old trim was two independent sliders and two numbers, which meant reading
  a decimal to work out what you had selected and made it possible to set an end
  before the start. This is one strip with two handles, so the selection is the
  shape of the thing rather than a pair of numbers, and the handles cannot cross
  because each is clamped by the other.

  It reports a range and nothing else. It does not know what a swing is, it does
  not touch the store, and it does not run the export. The caller does all three,
  which is why this can be looked at, and changed, on its own.
*/
struct TrimSheetView: View {
    let videoURL: URL?
    let duration: Double
    let onCancel: () -> Void
    let onConfirm: (Double, Double) -> Void

    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var thumbs: [UIImage] = []
    @State private var loadedThumbs = false

    /*
      The zoom preview: the exact frame under whichever handle is being dragged.

      A filmstrip of eight thumbnails is enough to find roughly where the swing
      is, and useless for deciding whether the cut lands before or after the
      takeaway. This pulls the real frame at the handle's time and shows it large
      while the finger is down, so the edit is made against the picture rather
      than against a decimal.
    */
    @State private var previewImage: UIImage?
    @State private var previewIsStart = true
    @State private var scrubbing = false
    // Serialised so a fast drag cannot leave a stale frame on screen: each new
    // request cancels the one before it.
    @State private var previewTask: Task<Void, Never>?
    // Reused across the whole drag rather than rebuilt per frame, which is what
    // keeps the preview up with the finger.
    @State private var previewGenerator: AVAssetImageGenerator?
    // The last whole tenth of a second a tick fired at, so the haptics mark real
    // movement instead of firing on every pixel of travel.
    @State private var lastHapticStep: Int?
    @State private var haptics = UISelectionFeedbackGenerator()

    // Nothing shorter than this can be selected, so a fumbled drag cannot
    // produce a clip with no frames in it.
    private let minimumSpan: Double = 0.2
    private let handleWidth: CGFloat = 18
    private let stripHeight: CGFloat = 68
    private let thumbCount = 8

    private var span: Double { max(0, end - start) }

    var body: some View {
        VStack(spacing: Tok.s4) {
            header
            zoomPreview
            strip
            Spacer(minLength: 0)
            footer
        }
        .padding(Tok.s4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Tok.turf900.ignoresSafeArea())
        .task {
            if end <= 0 { end = duration }
            // The frame the trimmed clip will open on, so the preview is useful
            // before anything has been dragged.
            updatePreview(seconds: start, isStart: true)
            await loadThumbnails()
        }
        .onDisappear {
            previewTask?.cancel()
            previewTask = nil
            previewGenerator = nil
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(clock(span))
                .font(.data(TypeScale.title))
                .foregroundStyle(Tok.bone)
                .monospacedDigit()

            Text("\(clock(start)) to \(clock(end))  of  \(clock(duration))")
                .font(.data(TypeScale.nano))
                .foregroundStyle(Tok.bone3)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Tok.s2)
    }

    /*
      The frame under the handle, shown large.

      Always present, so the sheet does not jump in height the instant a finger
      lands on a handle. It holds the start frame at rest, which is the frame the
      trimmed clip will open on, and swaps to whichever end is being dragged
      while a drag is running. The caption names which end is being looked at,
      because two ends that look alike on a range clip are otherwise impossible
      to tell apart.
    */
    private var zoomPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                .fill(Tok.turf800)

            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous))
            } else {
                Text("Drag a handle to preview")
                    .font(.body(TypeScale.micro))
                    .foregroundStyle(Tok.bone3)
            }
        }
        .frame(height: 210)
        .overlay {
            RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                .strokeBorder(scrubbing ? Tok.citrus : Tok.line, lineWidth: scrubbing ? 2 : 1)
        }
        .overlay(alignment: .bottom) {
            Text("\(previewIsStart ? "Start" : "End")  \(clock(previewIsStart ? start : end))")
                .font(.data(TypeScale.nano))
                .foregroundStyle(Tok.bone)
                .monospacedDigit()
                .padding(.vertical, 5)
                .padding(.horizontal, 12)
                .background(Capsule().fill(Color.black.opacity(0.7)))
                .padding(.bottom, 8)
        }
        .animation(.easeOut(duration: 0.15), value: scrubbing)
    }

    /*
      Pull one frame for the preview.

      Zero tolerance both ways, unlike the filmstrip: this is the frame the cut
      actually lands on, so an image from a quarter second away would be a
      picture of a different moment being used to make the decision. The
      generator is built once per sheet and kept, because rebuilding it per frame
      is what makes a scrub stutter.
    */
    private func updatePreview(seconds: Double, isStart: Bool) {
        previewIsStart = isStart
        guard let videoURL else { return }

        if previewGenerator == nil {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 720, height: 720)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            previewGenerator = generator
        }
        guard let generator = previewGenerator else { return }

        previewTask?.cancel()
        previewTask = Task { @MainActor in
            let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
            guard let cg = try? await generator.image(at: time).image else { return }
            guard !Task.isCancelled else { return }
            previewImage = UIImage(cgImage: cg)
        }
    }

    /*
      One tick per tenth of a second crossed, the cadence the system camera's own
      scrubber uses. Firing on every gesture callback would be a continuous buzz
      rather than feedback, and firing per frame would be worse on a 240 fps clip,
      so the tick is tied to the time being selected instead of to the finger.
    */
    private func hapticStep(_ seconds: Double) {
        let step = Int((seconds * 10).rounded())
        guard step != lastHapticStep else { return }
        lastHapticStep = step
        haptics.selectionChanged()
    }

    private var strip: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let x0 = position(for: start, in: width)
            let x1 = position(for: end, in: width)

            ZStack(alignment: .topLeading) {
                thumbnailRow(width: width)

                // Everything outside the selection is dimmed, so the selection
                // is what the eye lands on.
                Rectangle()
                    .fill(Tok.ink.opacity(0.66))
                    .frame(width: max(0, x0), height: stripHeight)
                Rectangle()
                    .fill(Tok.ink.opacity(0.66))
                    .frame(width: max(0, width - x1), height: stripHeight)
                    .offset(x: x1)

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Tok.citrus, lineWidth: 2)
                    .frame(width: max(2, x1 - x0), height: stripHeight)
                    .offset(x: x0)

                handle(at: x0, isStart: true, width: width)
                handle(at: x1, isStart: false, width: width)
            }
            .frame(width: width, height: stripHeight, alignment: .topLeading)
            .coordinateSpace(name: "trimStrip")
        }
        .frame(height: stripHeight)
        .padding(.horizontal, handleWidth / 2)
    }

    private func thumbnailRow(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if loadedThumbs && !thumbs.isEmpty {
                ForEach(Array(thumbs.enumerated()), id: \.offset) { _, image in
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width / CGFloat(thumbs.count), height: stripHeight)
                        .clipped()
                }
            } else {
                Rectangle()
                    .fill(Tok.turf800)
                    .frame(width: width, height: stripHeight)
            }
        }
        .frame(width: width, height: stripHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func handle(at x: CGFloat, isStart: Bool, width: CGFloat) -> some View {
        Capsule()
            .fill(Tok.citrus)
            .frame(width: handleWidth, height: stripHeight + 10)
            .overlay(
                Capsule()
                    .fill(Tok.ink.opacity(0.75))
                    .frame(width: 2, height: 22)
            )
            .offset(x: x - handleWidth / 2, y: -5)
            .contentShape(Rectangle().size(width: handleWidth + 22, height: stripHeight + 20))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("trimStrip"))
                    .onChanged { value in
                        if !scrubbing {
                            scrubbing = true
                            // Warm the Taptic Engine so the first tick lands with
                            // the finger rather than a beat behind it.
                            haptics.prepare()
                        }
                        let seconds = time(atX: value.location.x, in: width)
                        let landed: Double
                        if isStart {
                            start = min(max(0, seconds), max(0, end - minimumSpan))
                            landed = start
                        } else {
                            end = max(min(duration, seconds), min(duration, start + minimumSpan))
                            landed = end
                        }
                        hapticStep(landed)
                        updatePreview(seconds: landed, isStart: isStart)
                    }
                    .onEnded { _ in
                        scrubbing = false
                        lastHapticStep = nil
                    }
            )
            .accessibilityLabel(isStart ? "Trim start" : "Trim end")
            .accessibilityValue(clock(isStart ? start : end))
    }

    private var footer: some View {
        HStack {
            Button {
                onCancel()
            } label: {
                Text("Cancel")
                    .font(.body(TypeScale.small))
                    .foregroundStyle(Tok.bone)
                    .padding(.vertical, 13)
                    .padding(.horizontal, 28)
                    .overlay(Capsule().strokeBorder(Tok.lineStrong, lineWidth: 1))
            }
            .buttonStyle(PressScale())

            Spacer()

            Button {
                onConfirm(min(start, end), max(start, end))
            } label: {
                Text("Confirm")
                    .font(.body(TypeScale.small, weight: .bold))
                    .foregroundStyle(Tok.ink)
                    .padding(.vertical, 13)
                    .padding(.horizontal, 34)
                    .background(Capsule().fill(Tok.citrus))
            }
            .buttonStyle(PressScale())
            .disabled(span < minimumSpan)
            .opacity(span < minimumSpan ? 0.5 : 1)
        }
        .padding(.bottom, Tok.s2)
    }

    // MARK: Geometry and time

    private func position(for seconds: Double, in width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(1, max(0, seconds / duration))) * width
    }

    private func time(atX x: CGFloat, in width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(width, max(0, x)) / width) * duration
    }

    // Minutes, seconds and hundredths. A swing clip is short, and trimming one
    // to the nearest second is not precise enough to cut on the takeaway.
    private func clock(_ seconds: Double) -> String {
        let value = max(0, seconds)
        let minutes = Int(value) / 60
        let rest = value - Double(minutes * 60)
        return String(format: "%d:%05.2f", minutes, rest)
    }

    // MARK: Thumbnails

    /*
      A handful of stills across the clip, drawn behind the handles.

      Deliberately few and small. The strip is there to answer "where in the
      swing am I cutting", which eight frames answers, and asking for one per
      frame would spend a second of work to answer the same question.
    */
    private func loadThumbnails() async {
        guard let videoURL, duration > 0 else {
            loadedThumbs = true
            return
        }
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 180, height: 180)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)

        var built: [UIImage] = []
        for i in 0..<thumbCount {
            let fraction = (Double(i) + 0.5) / Double(thumbCount)
            let time = CMTime(seconds: duration * fraction, preferredTimescale: 600)
            if let image = try? await generator.image(at: time).image {
                built.append(UIImage(cgImage: image))
            }
        }
        thumbs = built
        loadedThumbs = true
    }
}

// MARK: - Speed picker

struct SpeedPickerView: View {
    let speeds: [Double]
    let current: Double
    let onSelect: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("PLAYBACK SPEED")
                .font(.data(TypeScale.nano))
                .tracking(1)
                .foregroundStyle(Tok.bone3)
                .padding(.horizontal, Tok.s5)
                .padding(.top, Tok.s5)
                .padding(.bottom, Tok.s3)

            ForEach(speeds, id: \.self) { speed in
                Button {
                    onSelect(speed)
                } label: {
                    HStack {
                        Text(label(speed))
                            .font(.body(TypeScale.body))
                            .foregroundStyle(speed == current ? Tok.citrus : Tok.bone)
                        Spacer()
                        if speed == current {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Tok.citrus)
                        }
                    }
                    .padding(.horizontal, Tok.s5)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if speed != speeds.last {
                    Rectangle()
                        .fill(Tok.line)
                        .frame(height: 1)
                        .padding(.leading, Tok.s5)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.turf800.ignoresSafeArea())
    }

    private func label(_ speed: Double) -> String {
        if speed == speed.rounded() { return "\(Int(speed))x" }
        return "\(speed.formatted(.number.precision(.fractionLength(0...2))))x"
    }
}

