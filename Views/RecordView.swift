//
//  RecordView.swift
//  Swingline
//
//  The capture chrome from src/screens/Capture.jsx. Chrome-less: no tab bar,
//  because a nav bar over a live viewfinder both wastes the space and invites a
//  mis-tap while somebody is trying to film themselves. The X returns home, at
//  which point the bar comes back.
//
//  In single swing mode the record disc is not a manual shutter. Detection is
//  automatic: the camera watches continuously and SwingDetector decides when a
//  swing happens. The disc reflects that machine directly. It reads lime WAIT
//  while idle, red STOP with a running timer once a swing is armed and underway,
//  then flashes the instant a swing is captured before falling back to WAIT.
//  Tapping it cancels a false arm and drops straight back to WAIT.
//
//  In a multi swing set the disc becomes a real start and stop control, because
//  the golfer is filming a run of swings and decides themselves when the set is
//  over. Auto save is suppressed for the whole set and the buffer is split into
//  one clip per swing afterwards. See CaptureViewModel.splitSwingWindows.
//
//  Two numbers on this screen have to stay honest when the pipeline lands:
//  the quality badge reports the resolution and frame rate actually granted,
//  not the ones requested, and the tracked fps readout is the real measured
//  rate. The web app turns the badge rust coloured when the browser capped the
//  rate. On iOS there should be no cap to report, which is the whole reason for
//  going native, so if that badge ever goes rust here something is wrong.
//
//  House rule: no em dashes anywhere.
//

import SwiftUI

struct RecordView: View {
    @Environment(AppStore.self) private var store

    @State private var settingsDrawerOpen = false
    @State private var qualityPickerOpen = false
    // The exposure explainer expands inside the capture drawer rather than
    // opening a second sheet on top of the first, which iOS handles badly.
    @State private var exposureInfoOpen = false

    // Drives the STOP timer. Set when a swing becomes active, cleared when it
    // ends. Wall clock, so the readout ticks smoothly between frames.
    @State private var activeSince: Date?
    // A brief bright wash confirming a swing was caught.
    @State private var flash = false

    // The live capture engine. Owns the AVCaptureSession and the connection to
    // VisionPoseProvider. Every telemetry value below is read off this rather
    // than held as local state, so the numbers on screen are the real detector
    // output, not placeholders.
    @StateObject private var capture = CaptureViewModel()

    private var handSpeed: Double { capture.handSpeed }
    private var trackedFps: Int { capture.trackedFps }
    private var detectorReady: Bool { capture.detectorReady }
    private var phase: SwingDetector.Phase { capture.swingPhase }

    private var qualityLabel: String {
        store.settings.cameraQuality
            .replacingOccurrences(of: "p", with: "p ")
            .appending("fps")
    }

    var body: some View {
        ZStack {
            // Live camera feed, full bleed, behind the chrome. Falls back to a
            // flat surface and a short line of copy when the camera is not
            // available, which on the simulator it never is.
            if capture.permission == .denied {
                Tok.turf900.ignoresSafeArea()
                Text("Camera access is off. Turn it on in Settings to record.")
                    .font(.body(TypeScale.small))
                    .foregroundStyle(Tok.bone2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Tok.s6)
            } else {
                CameraPreview(session: capture.session).ignoresSafeArea()
                guideOverlay.ignoresSafeArea().allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                topBar
                hintBar
                Spacer()
                bottomControls
            }

            // Capture flash. A quick bright wash over the whole viewfinder the
            // moment a swing is caught, then gone.
            if flash {
                Tok.citrus.opacity(0.18)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .background(Tok.ink.ignoresSafeArea())
        .onAppear {
            capture.attach(store: store)
            capture.setSwingTarget(swingTarget)
            capture.requestPermissionAndStart()
        }
        .onDisappear { capture.stop() }
        .onChange(of: capture.swingPhase) { _, newPhase in
            handlePhaseChange(newPhase)
        }
        // The set size lives in settings, so a change made anywhere reaches the
        // engine rather than only the label on the button.
        .onChange(of: store.settings.recordMode) { _, _ in
            capture.setSwingTarget(swingTarget)
        }
        .sheet(isPresented: $settingsDrawerOpen) { captureSettingsDrawer }
        .sheet(isPresented: $qualityPickerOpen) { qualityPicker }
    }

    // MARK: Phase reactions

    private func handlePhaseChange(_ newPhase: SwingDetector.Phase) {
        switch newPhase {
        case .armed, .swinging, .settling:
            if activeSince == nil { activeSince = Date() }
        case .captured:
            // Mid set the timer belongs to the set, not to the swing, so only
            // the flash fires and the clock keeps running.
            if !capture.isMultiRecording { activeSince = nil }
            triggerFlash()
        case .idle:
            if !capture.isMultiRecording { activeSince = nil }
        }
    }

    private func triggerFlash() {
        withAnimation(.easeOut(duration: 0.12)) { flash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            withAnimation(.easeIn(duration: 0.3)) { flash = false }
        }
    }

    // MARK: Top bar

    // Full width, overlaid on the camera, on a top to transparent scrim,
    // respecting the top safe area.
    private var topBar: some View {
        HStack(alignment: .center, spacing: Tok.s3) {
            HStack(spacing: Tok.s2) {
                Button {
                    store.go(.home)
                } label: {
                    SLIcon(kind: .close, size: 20)
                        .foregroundStyle(Tok.bone)
                        .frame(width: 40, height: 40)
                        .glass(radius: 20)
                }
                .buttonStyle(PressScale())

                Button {
                    qualityPickerOpen = true
                } label: {
                    Text(qualityLabel)
                        .font(.data(TypeScale.nano))
                        .foregroundStyle(Tok.bone2)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 10)
                        .glass(radius: 999)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // One compact telemetry strip. Hand speed goes citrus above
            // 1.7 m/s, tracked fps goes citrus at 20 or more.
            HStack(spacing: Tok.s2) {
                Text("HANDS")
                    .font(.data(TypeScale.nano))
                    .foregroundStyle(Tok.bone3)
                Text(String(format: "%.1f", handSpeed))
                    .font(.data(TypeScale.small))
                    .foregroundStyle(handSpeed > 1.7 ? Tok.citrus : Tok.bone2)
                Text("m/s")
                    .font(.data(TypeScale.nano))
                    .foregroundStyle(Tok.bone3)

                Text("|").foregroundStyle(Tok.bone3.opacity(0.5))

                Text("TRACK")
                    .font(.data(TypeScale.nano))
                    .foregroundStyle(Tok.bone3)
                Text("\(trackedFps)")
                    .font(.data(TypeScale.small))
                    .foregroundStyle(trackedFps >= 20 ? Tok.citrus : Tok.bone2)
                Text("fps")
                    .font(.data(TypeScale.nano))
                    .foregroundStyle(Tok.bone3)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .glass(radius: 999)

            Spacer()

            Button {
                settingsDrawerOpen = true
            } label: {
                SLIcon(kind: .gear, size: 20)
                    .foregroundStyle(Tok.bone)
                    .frame(width: 40, height: 40)
                    .glass(radius: 20)
            }
            .buttonStyle(PressScale())
        }
        .padding(.horizontal, Tok.s4)
        .padding(.vertical, Tok.s3)
        .background {
            LinearGradient(colors: [Tok.ink.opacity(0.85), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        }
    }

    private var hintBar: some View {
        Text(hintText)
            .font(.body(TypeScale.small))
            .foregroundStyle(Tok.bone2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Tok.ink.opacity(0.35))
    }

    // One line, one job. The set states take priority over the framing hint,
    // because during a set the framing is already settled.
    private var hintText: String {
        if capture.multiProcessing {
            return "Splitting the recording into swings"
        }
        if capture.isMultiRecording {
            return "Swing away. Tap the disc when the set is done."
        }
        if capture.multiSavedCount > 0 {
            return capture.multiSavedCount == 1
                ? "Saved 1 swing from that set"
                : "Saved \(capture.multiSavedCount) swings from that set"
        }
        if swingTarget > 1 {
            return "Tap the disc to start a set of \(swingTarget)"
        }
        return detectorReady ? "Ready when you are" : "Step into frame so the camera can find you"
    }

    // MARK: Guide overlay

    // A line guide, not a silhouette. Lines survive any body shape, any camera
    // height and either handedness, where a traced outline only fits the golfer
    // it was drawn from.
    @ViewBuilder private var guideOverlay: some View {
        switch store.settings.guideStyle {
        case "faceon":
            FaceOnGuide(mirrored: store.settings.dominantHand == "left")
        case "downline":
            DownTheLineGuide(mirrored: store.settings.dominantHand == "left")
        default:
            EmptyView()
        }
    }

    // MARK: Bottom controls

    // Two rows. The upper row is setup, the things chosen once and left alone.
    // The lower row is the swing itself: how many, the disc, and what club.
    private var bottomControls: some View {
        VStack(spacing: Tok.s3) {
            HStack(spacing: Tok.s2) {
                guideButton
                flipButton
                Spacer()
                readinessRing
            }

            HStack(alignment: .center) {
                setSizeButton
                    .frame(maxWidth: .infinity, alignment: .leading)

                recordDisc

                clubButton
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, Tok.s5)
        .padding(.bottom, Tok.s5)
        .background {
            LinearGradient(colors: [.clear, Tok.ink.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private var guideButton: some View {
        Menu {
            Picker("Guide", selection: guideBinding) {
                Text("No guide").tag("none")
                Text("Face on").tag("faceon")
                Text("Down the line").tag("downline")
            }
        } label: {
            pillLabel(guideLabel)
        }
        .menuStyle(.borderlessButton)
    }

    private var guideBinding: Binding<String> {
        Binding(
            get: { normalisedGuideStyle },
            set: { value in store.update { $0.guideStyle = value } }
        )
    }

    private var flipButton: some View {
        Button {
            capture.flipCamera()
        } label: {
            SLIcon(kind: .flip, size: 18)
                .foregroundStyle(store.settings.cameraFacing == "user" ? Tok.citrus : Tok.bone2)
                .frame(width: 36, height: 36)
                .glass(radius: 18)
        }
        .buttonStyle(PressScale())
    }

    // Readiness ring, reflecting detector state and framing.
    private var readinessRing: some View {
        ZStack {
            Circle()
                .strokeBorder(Tok.lineStrong, lineWidth: 3)
            Circle()
                .trim(from: 0, to: detectorReady ? 1 : 0.25)
                .stroke(detectorReady ? Tok.fairwayLit : Tok.bone3, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 36, height: 36)
    }

    private var setSizeButton: some View {
        Menu {
            Picker("Swings", selection: setSizeBinding) {
                Text("1 swing").tag("single")
                Text("3 swings").tag("multi3")
                Text("5 swings").tag("multi5")
            }
        } label: {
            pillLabel(setSizeLabel)
        }
        .menuStyle(.borderlessButton)
        // Changing the set size mid recording would leave the counter lying
        // about what is being collected.
        .disabled(capture.isMultiRecording || capture.multiProcessing)
        .opacity(capture.isMultiRecording || capture.multiProcessing ? 0.4 : 1)
    }

    private var setSizeBinding: Binding<String> {
        Binding(
            get: { normalisedRecordMode },
            set: { value in store.update { $0.recordMode = value } }
        )
    }

    private var clubButton: some View {
        Menu {
            Picker("Club", selection: clubBinding) {
                ForEach(SettingsOptions.clubs) { club in
                    Text(club.label).tag(club.value)
                }
            }
        } label: {
            pillLabel(clubLabel)
        }
        .menuStyle(.borderlessButton)
    }

    private var clubBinding: Binding<String> {
        Binding(
            get: { store.settings.selectedClub },
            set: { value in store.update { $0.selectedClub = value } }
        )
    }

    private func pillLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.data(TypeScale.nano))
            .tracking(1)
            .lineLimit(1)
            .foregroundStyle(Tok.bone2)
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .glass(radius: 999)
    }

    // MARK: Record disc

    // In a single swing the disc is a state indicator and tapping it cancels a
    // false arm. In a set it starts and stops the recording.
    private var recordDisc: some View {
        Button {
            discTapped()
        } label: {
            ZStack {
                Circle().fill(discFill)
                discLabel
            }
            .frame(width: 78, height: 78)
            .overlay {
                Circle().strokeBorder(.white.opacity(flash ? 0.9 : 0), lineWidth: 4)
            }
            .scaleEffect(flash ? 1.08 : 1)
            .shadow(color: discGlow.opacity(0.5), radius: 20, y: 8)
        }
        .buttonStyle(PressScale())
        .disabled(capture.multiProcessing)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: flash)
        .animation(.easeInOut(duration: 0.25), value: phase)
    }

    private func discTapped() {
        guard !capture.multiProcessing else { return }
        if swingTarget > 1 {
            if capture.isMultiRecording {
                capture.stopMultiCapture()
                activeSince = nil
            } else {
                capture.startMultiCapture()
                activeSince = Date()
            }
        } else {
            capture.cancelDetection()
        }
    }

    private var discFill: LinearGradient {
        if capture.multiProcessing {
            return LinearGradient(
                colors: [Tok.bone3, Tok.bone3.opacity(0.8), Tok.bone3.opacity(0.6)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        if capture.isMultiRecording {
            return LinearGradient(
                colors: [Tok.rust.opacity(0.95), Tok.rust, Tok.rust.opacity(0.78)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        switch phase {
        case .idle:
            return LinearGradient(
                colors: [Tok.citrusLit, Tok.citrus, Tok.citrusDeep],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .captured:
            return LinearGradient(
                colors: [.white, Tok.citrusLit, Tok.citrus],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .armed, .swinging, .settling:
            return LinearGradient(
                colors: [Tok.rust.opacity(0.95), Tok.rust, Tok.rust.opacity(0.78)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var discGlow: Color {
        (capture.isMultiRecording || phase.isActive) ? Tok.rust : Tok.citrus
    }

    @ViewBuilder private var discLabel: some View {
        if capture.multiProcessing {
            Text("SAVING")
                .font(.data(TypeScale.micro))
                .foregroundStyle(Tok.ink)
        } else if capture.isMultiRecording {
            VStack(spacing: 1) {
                Text("STOP")
                    .font(.data(TypeScale.micro))
                    .foregroundStyle(Tok.bone)
                Text("\(capture.multiDetectedCount)/\(swingTarget)")
                    .font(.data(TypeScale.small))
                    .foregroundStyle(Tok.bone)
                SwiftUI.TimelineView(.periodic(from: .now, by: 0.05)) { context in
                    Text(timerString(now: context.date))
                        .font(.data(TypeScale.nano))
                        .foregroundStyle(Tok.bone.opacity(0.85))
                }
            }
        } else if swingTarget > 1 {
            VStack(spacing: 1) {
                Text("REC")
                    .font(.data(TypeScale.micro))
                    .foregroundStyle(Tok.ink)
                Text("0/\(swingTarget)")
                    .font(.data(TypeScale.nano))
                    .foregroundStyle(Tok.ink.opacity(0.7))
            }
        } else {
            switch phase {
            case .idle:
                Text("WAIT")
                    .font(.data(TypeScale.micro))
                    .foregroundStyle(Tok.ink)
            case .captured:
                SLIcon(kind: .target, size: 26)
                    .foregroundStyle(Tok.ink)
            case .armed, .swinging, .settling:
                VStack(spacing: 1) {
                    Text("STOP")
                        .font(.data(TypeScale.micro))
                        .foregroundStyle(Tok.bone)
                    SwiftUI.TimelineView(.periodic(from: .now, by: 0.05)) { context in
                        Text(timerString(now: context.date))
                            .font(.data(TypeScale.nano))
                            .foregroundStyle(Tok.bone.opacity(0.85))
                    }
                }
            }
        }
    }

    private func timerString(now: Date) -> String {
        guard let start = activeSince else { return "0.0s" }
        let elapsed = max(0, now.timeIntervalSince(start))
        return String(format: "%.1fs", elapsed)
    }

    // MARK: Labels

    // AppSettings still ships "faceon" as the stored default. Anything that is
    // not one of the two real guides reads as no guide, so an unknown or legacy
    // value fails to the quietest overlay rather than to a wrong one.
    private var normalisedGuideStyle: String {
        switch store.settings.guideStyle {
        case "faceon": return "faceon"
        case "downline": return "downline"
        default: return "none"
        }
    }

    private var guideLabel: String {
        switch normalisedGuideStyle {
        case "faceon": return "Face on"
        case "downline": return "Down the line"
        default: return "No guide"
        }
    }

    // recordMode is shared with the settings screen, so an unrecognised value
    // lands on a single swing rather than silently arming a set.
    private var normalisedRecordMode: String {
        switch store.settings.recordMode {
        case "multi3": return "multi3"
        case "multi5": return "multi5"
        default: return "single"
        }
    }

    private var swingTarget: Int {
        switch normalisedRecordMode {
        case "multi3": return 3
        case "multi5": return 5
        default: return 1
        }
    }

    private var setSizeLabel: String {
        swingTarget == 1 ? "1 swing" : "\(swingTarget) swings"
    }

    private var clubLabel: String {
        SettingsOptions.clubs.first { $0.value == store.settings.selectedClub }?.label ?? "Club"
    }

    // MARK: Drawers

    // Built to grow. Torch is only enabled when the camera exposes it, and the
    // grid row is a deliberate placeholder rather than a hidden feature.
    private var captureSettingsDrawer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Capsule().fill(Tok.lineStrong).frame(width: 44, height: 4)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Tok.s4)

                Eyebrow(text: "Capture")
                Text("While you film")
                    .font(.serif(TypeScale.title))
                    .foregroundStyle(Tok.bone)
                    .padding(.top, 6)
                    .padding(.bottom, Tok.s4)

                HStack(spacing: Tok.s2) {
                    Text("Exposure")
                        .font(.data(TypeScale.nano))
                        .tracking(1)
                        .foregroundStyle(Tok.bone3)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { exposureInfoOpen.toggle() }
                    } label: {
                        Text("i")
                            .font(.serif(TypeScale.nano))
                            .foregroundStyle(exposureInfoOpen ? Tok.citrus : Tok.bone2)
                            .frame(width: 22, height: 22)
                            .overlay {
                                Circle().strokeBorder(exposureInfoOpen ? Tok.citrus : Tok.lineStrong, lineWidth: 1)
                            }
                    }
                    .buttonStyle(PressScale())
                    .accessibilityLabel("What shutter speed and ISO do")
                    Spacer()
                }
                .padding(.bottom, exposureInfoOpen ? Tok.s3 : 0)

                if exposureInfoOpen { exposureExplainer }

                SwitchRow(
                    label: "Manual exposure",
                    note: "Reduces motion blur on a fast swing. Set shutter and ISO below.",
                    isOn: store.settings.manualExposureEnabled
                ) { value in
                    store.update { $0.manualExposureEnabled = value }
                    capture.applyExposureSettings()
                }

                if store.settings.manualExposureEnabled {
                    let shutterOptions = [30, 60, 125, 250, 500, 1000, 2000, 4000, 8000]
                    SliderRow(
                        label: "Shutter speed",
                        value: Binding(
                            get: { Double(shutterOptions.firstIndex(of: store.settings.exposureDurationDenominator) ?? 6) },
                            set: { newValue in
                                let denom = shutterOptions[min(max(Int(newValue.rounded()), 0), shutterOptions.count - 1)]
                                store.update { $0.exposureDurationDenominator = denom }
                                capture.applyExposureSettings()
                            }
                        ),
                        range: 0...Double(shutterOptions.count - 1),
                        step: 1,
                        format: { "1/\(shutterOptions[min(max(Int($0.rounded()), 0), shutterOptions.count - 1)])s" }
                    )

                    SliderRow(
                        label: "ISO",
                        value: Binding(
                            get: { Double(store.settings.exposureISO) },
                            set: { newValue in
                                store.update { $0.exposureISO = Float(newValue) }
                                capture.applyExposureSettings()
                            }
                        ),
                        range: 25...2000,
                        step: 25,
                        format: { "\(Int($0))" }
                    )
                }

                Spacer(minLength: Tok.s5)
            }
            .padding(.horizontal, Tok.s5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Tok.turf800.ignoresSafeArea())
        .presentationDetents([.height(320), .large])
        .presentationDragIndicator(.hidden)
    }

    private var exposureExplainer: some View {
        VStack(alignment: .leading, spacing: Tok.s3) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Shutter speed")
                    .font(.data(TypeScale.small))
                    .foregroundStyle(Tok.bone)
                Text("Controls motion blur. Faster shutter = less blur, darker image. 1/2000s freezes club head.")
                    .font(.body(TypeScale.nano))
                    .foregroundStyle(Tok.bone2)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("ISO")
                    .font(.data(TypeScale.small))
                    .foregroundStyle(Tok.bone)
                Text("Controls brightness. Higher ISO = brighter image, more grain. Keep as low as possible.")
                    .font(.body(TypeScale.nano))
                    .foregroundStyle(Tok.bone2)
            }
        }
        .padding(Tok.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.turf900, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Tok.line, lineWidth: 1)
        }
        .padding(.bottom, Tok.s4)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var qualityPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "Quality")
                .padding(.top, Tok.s5)
            Text("Resolution and frame rate")
                .font(.serif(TypeScale.title))
                .foregroundStyle(Tok.bone)
                .padding(.top, 6)
                .padding(.bottom, Tok.s4)

            ForEach(["720p30", "1080p30", "1080p60", "1080p120", "4k30"], id: \.self) { option in
                Button {
                    store.update { $0.cameraQuality = option }
                    qualityPickerOpen = false
                    capture.reconfigureCamera()
                } label: {
                    HStack {
                        Text(option)
                            .font(.data(TypeScale.small))
                            .foregroundStyle(store.settings.cameraQuality == option ? Tok.citrus : Tok.bone)
                        Spacer()
                    }
                    .padding(.vertical, 14)
                    .overlay(alignment: .bottom) { Rectangle().fill(Tok.line).frame(height: 1) }
                }
                .buttonStyle(.plain)
            }

            Text("The badge reports what the camera actually granted, not what was asked for.")
                .font(.body(TypeScale.nano))
                .foregroundStyle(Tok.bone3)
                .padding(.top, Tok.s4)

            Spacer()
        }
        .padding(.horizontal, Tok.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.turf800.ignoresSafeArea())
        .presentationDetents([.medium])
    }
}

// MARK: - Guide overlays

/*
  Face on. The camera is in front of the golfer, looking down the target line
  from the side of the ball.

  Three references, no more. A centre line for the sternum, a ball line the
  golfer stands their ball on, and a head box, because the single most useful
  thing a face on camera shows is whether the head stayed where it started.
*/
private struct FaceOnGuide: View {
    var mirrored: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let centreX = w * 0.5
            let ballY = h * 0.84
            let headTop = h * 0.16
            let headBottom = h * 0.30
            let headHalf = w * 0.11

            ZStack {
                // Sternum line, the axis the swing rotates around.
                Path { p in
                    p.move(to: CGPoint(x: centreX, y: headTop))
                    p.addLine(to: CGPoint(x: centreX, y: ballY))
                }
                .stroke(Tok.citrus.opacity(0.45), style: dashed)

                // Ball line, where the feet and the ball sit.
                Path { p in
                    p.move(to: CGPoint(x: w * 0.12, y: ballY))
                    p.addLine(to: CGPoint(x: w * 0.88, y: ballY))
                }
                .stroke(Tok.citrus.opacity(0.45), style: dashed)

                // Head box. Stay inside it and the low point stays put.
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Tok.citrus.opacity(0.35), style: dashed)
                    .frame(width: headHalf * 2, height: headBottom - headTop)
                    .position(x: centreX, y: (headTop + headBottom) / 2)

                Text("HEAD")
                    .font(.data(TypeScale.nano))
                    .tracking(1)
                    .foregroundStyle(Tok.citrus.opacity(0.6))
                    .position(x: centreX + (mirrored ? -1 : 1) * (headHalf + 26), y: (headTop + headBottom) / 2)

                Text("BALL")
                    .font(.data(TypeScale.nano))
                    .tracking(1)
                    .foregroundStyle(Tok.citrus.opacity(0.6))
                    .position(x: w * (mirrored ? 0.82 : 0.18), y: ballY - 14)
            }
        }
    }

    private var dashed: StrokeStyle {
        StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [6, 8])
    }
}

/*
  Down the line. The camera is behind the golfer, on the target line, looking
  at the ball.

  The plane line runs from the ball through the trail shoulder, which is the
  reference every down the line lesson is built on. It flips with handedness,
  because a right handed plane drawn for a left handed golfer is worse than no
  guide at all.
*/
private struct DownTheLineGuide: View {
    var mirrored: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let ball = CGPoint(x: w * (mirrored ? 0.62 : 0.38), y: h * 0.86)
            let shoulder = CGPoint(x: w * (mirrored ? 0.36 : 0.64), y: h * 0.30)
            // Extend the plane past the shoulder so it reads as a line and not
            // as a segment between two invented points.
            let dx = shoulder.x - ball.x
            let dy = shoulder.y - ball.y
            let far = CGPoint(x: ball.x + dx * 1.7, y: ball.y + dy * 1.7)

            ZStack {
                Path { p in
                    p.move(to: ball)
                    p.addLine(to: far)
                }
                .stroke(Tok.citrus.opacity(0.45), style: dashed)

                // Ball line across the ground.
                Path { p in
                    p.move(to: CGPoint(x: w * 0.08, y: ball.y))
                    p.addLine(to: CGPoint(x: w * 0.92, y: ball.y))
                }
                .stroke(Tok.citrus.opacity(0.35), style: dashed)

                // Spine reference, vertical from the ball line up.
                Path { p in
                    p.move(to: CGPoint(x: shoulder.x, y: ball.y))
                    p.addLine(to: CGPoint(x: shoulder.x, y: h * 0.22))
                }
                .stroke(Tok.citrus.opacity(0.25), style: dashed)

                Circle()
                    .strokeBorder(Tok.citrus.opacity(0.6), lineWidth: 1.5)
                    .frame(width: 14, height: 14)
                    .position(ball)

                Text("PLANE")
                    .font(.data(TypeScale.nano))
                    .tracking(1)
                    .foregroundStyle(Tok.citrus.opacity(0.6))
                    .position(x: (ball.x + far.x) / 2 + (mirrored ? -30 : 30), y: (ball.y + far.y) / 2)
            }
        }
    }

    private var dashed: StrokeStyle {
        StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [6, 8])
    }
}
