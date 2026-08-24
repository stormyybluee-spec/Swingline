//
//  SkeletonSettingsView.swift
//  Swingline
//
//  The "Skeleton and joints" sheet, reached from the pill above the video. It
//  edits a SkeletonSettings, which persists itself, so every change here is live
//  on the overlay and kept across restarts. Ported to match the reference sheet:
//  Reset all, a serif title, Done, two sliders, a two card colour mode picker,
//  and the per joint groups with expandable left and right rows.
//
//  The per joint gear popover reads "Coming with the native app" for line colour
//  and thickness, which is not my placeholder but the web build's own honest
//  note carried across for parity. Everything else on this sheet is wired to
//  real drawing state.
//
//  House rule: no em dashes anywhere.
//

import SwiftUI

struct SkeletonSettingsView: View {
    @Bindable var settings: SkeletonSettings
    let onDone: () -> Void

    // Which joint rows are expanded, and which gear hint is showing.
    @State private var expanded: Set<JointKey> = []
    // The angle style panel, opened by the gear on either angle row.
    @State private var angleStyleOpen = false
    // The joint whose summary rides in the header. Set to the last joint the
    // golfer opened, cleared when that same joint is closed, so the header always
    // names the row being worked on rather than guessing from an unordered set.
    @State private var activeJoint: JointKey?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Tok.s5) {
                    sliders
                    linesToggle
                    colourMode
                    jointsSection
                }
                .padding(.horizontal, Tok.s4)
                .padding(.top, Tok.s4)
                .padding(.bottom, 40)
            }
        }
        .background(Tok.turf900.ignoresSafeArea())
        .presentationDragIndicator(.visible)
    }

    // MARK: Header

    private var header: some View {
        ZStack {
            /*
              Title, with the open joint's live status underneath it. The status
              line names the joint and every toggle currently on, e.g.
              "Left shoulder · tracked · inner · outer", so the header always
              reflects the row being edited. It is held to one line and allowed to
              shrink rather than push the buttons around, which is the overflow the
              old fixed title could not handle.
            */
            VStack(spacing: 2) {
                Text("Skeleton")
                    .font(.serif(TypeScale.head))
                    .foregroundStyle(Tok.bone)
                if let summary = activeJointSummary {
                    Text(summary)
                        .font(.data(TypeScale.nano))
                        .foregroundStyle(Tok.bone3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: 190)
                        .transition(.opacity)
                }
            }

            HStack {
                Button("Reset all") {
                    settings.resetAll()
                    expanded = []
                    activeJoint = nil
                }
                .font(.body(TypeScale.small))
                .foregroundStyle(Tok.bone2)

                Spacer()

                Button("Done") { onDone() }
                    .font(.body(TypeScale.small, weight: .semibold))
                    .foregroundStyle(Tok.citrus)
            }
        }
        .padding(.horizontal, Tok.s4)
        .padding(.vertical, Tok.s4)
    }

    /*
      The header status line for the open joint, or nil when no joint is open.

      Built from the real JointSetting fields: `track`, `innerAngle`, `outerAngle`
      (the brief calls the first "tracked", but the stored property is `track`, so
      that is what is read here and the word "tracked" is shown for it). Reads
      straight off the settings model, so flipping a toggle updates the header at
      once. Returns just the joint name when nothing is on.
    */
    private var activeJointSummary: String? {
        guard let joint = activeJoint else { return nil }
        let s = settings.setting(for: joint)
        var parts: [String] = []
        if s.track { parts.append("tracked") }
        if s.innerAngle { parts.append("inner") }
        if s.outerAngle { parts.append("outer") }
        return ([joint.label] + parts).joined(separator: " \u{00b7} ")
    }

    /*
      The status suffix for a joint row, or nil when nothing is on.

      Same wording as the header line but without the joint name, since the row
      already carries it: "tracked \u{00b7} inner \u{00b7} outer". Reads the real
      JointSetting fields (`track`, `innerAngle`, `outerAngle`, `showLine`), so it
      updates the instant a toggle flips. A joint whose lines are hidden says so,
      because that is a change to the drawing a golfer will otherwise hunt for.
    */
    private func jointStatusText(_ joint: JointKey) -> String? {
        let s = settings.setting(for: joint)
        var parts: [String] = []
        if s.track { parts.append("tracked") }
        if s.innerAngle { parts.append("inner") }
        if s.outerAngle { parts.append("outer") }
        if !s.showLine { parts.append("no line") }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00b7} ")
    }

    // MARK: Connecting lines

    /*
      One switch for the bones. Off leaves the joint dots and their angle readouts
      but drops the connecting lines, so a golfer can read joint positions without
      the figure's limbs drawn over the video. Wired straight to the settings
      model, which persists it and pushes it live to both the 2D overlay and the
      3D rig.
    */
    private var linesToggle: some View {
        Toggle(isOn: $settings.showConnectingLines) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Show connecting lines")
                    .font(.body(TypeScale.body))
                    .foregroundStyle(Tok.bone)
                Text("Off leaves only the joint dots")
                    .font(.body(TypeScale.micro))
                    .foregroundStyle(Tok.bone3)
            }
        }
        .tint(Tok.citrus)
        .padding(Tok.s3)
        .background(RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous).fill(Tok.turf800.opacity(0.6)))
        .overlay {
            RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                .strokeBorder(Tok.line, lineWidth: 1)
        }
    }

    // MARK: Sliders

    private var sliders: some View {
        VStack(alignment: .leading, spacing: Tok.s5) {
            labelledSlider(
                title: "THICKNESS",
                value: $settings.thickness,
                range: SkeletonSettings.thicknessRange,
                display: String(format: "%.1f", settings.thickness)
            )
            labelledSlider(
                title: "JOINT SIZE",
                value: $settings.jointSize,
                range: SkeletonSettings.jointSizeRange,
                display: String(format: "%.1f", settings.jointSize)
            )
        }
    }

    private func labelledSlider(title: String, value: Binding<Double>, range: ClosedRange<Double>, display: String) -> some View {
        VStack(alignment: .leading, spacing: Tok.s2) {
            HStack {
                Text(title)
                    .font(.data(TypeScale.nano))
                    .tracking(1.5)
                    .foregroundStyle(Tok.bone3)
                Spacer()
                Text(display)
                    .font(.data(TypeScale.small))
                    .foregroundStyle(Tok.bone2)
            }
            Slider(value: value, in: range)
                .tint(Tok.citrus)
        }
    }

    // MARK: Colour mode

    private var colourMode: some View {
        VStack(alignment: .leading, spacing: Tok.s2) {
            Text("LEFT AND RIGHT")
                .font(.data(TypeScale.nano))
                .tracking(1.5)
                .foregroundStyle(Tok.bone3)

            colourCard(
                mode: .dual,
                title: "Blue and red",
                dots: [Color(red: 1, green: 59 / 255, blue: 48 / 255), Color(red: 77 / 255, green: 166 / 255, blue: 255 / 255)]
            )
            colourCard(
                mode: .single,
                title: "One colour",
                dots: [Tok.citrusDeep, Tok.citrusDeep]
            )

            // Custom colours. Dual mode uses lead and trail, single mode uses the
            // one tone, so only the relevant pickers are shown.
            VStack(spacing: Tok.s2) {
                if settings.colorMode == .dual {
                    colourPickerRow(title: "Lead side", hex: $settings.leadColorHex)
                    colourPickerRow(title: "Trail side", hex: $settings.trailColorHex)
                } else {
                    colourPickerRow(title: "Figure colour", hex: $settings.singleColorHex)
                }
            }
            .padding(.top, Tok.s2)
        }
    }

    /*
      One colour row: a swatch that opens the system picker, so any colour is
      reachable, plus quick swatches for the common ones.
    */
    private func colourPickerRow(title: String, hex: Binding<String>) -> some View {
        HStack(spacing: Tok.s3) {
            Text(title)
                .font(.body(TypeScale.small))
                .foregroundStyle(Tok.bone2)
            Spacer()
            ForEach(Self.quickColours, id: \.self) { swatch in
                Button {
                    hex.wrappedValue = swatch
                } label: {
                    Circle()
                        .fill(Color(hex: swatch))
                        .frame(width: 22, height: 22)
                        .overlay {
                            Circle().strokeBorder(
                                hex.wrappedValue.lowercased() == swatch.lowercased() ? Tok.bone : Tok.line,
                                lineWidth: hex.wrappedValue.lowercased() == swatch.lowercased() ? 2 : 1
                            )
                        }
                }
                .buttonStyle(PressScale())
            }
            ColorPicker("", selection: Binding(
                get: { Color(hex: hex.wrappedValue) },
                set: { hex.wrappedValue = $0.hexString }
            ))
            .labelsHidden()
            .frame(width: 28)
        }
        .padding(.vertical, 6)
    }

    private static let quickColours: [String] = ["#4da6ff", "#ff3b30", "#c8ff4d", "#f0eadc"]

    private func colourCard(mode: SkeletonColorMode, title: String, dots: [Color]) -> some View {
        let active = settings.colorMode == mode
        return Button {
            settings.colorMode = mode
        } label: {
            HStack(spacing: Tok.s3) {
                HStack(spacing: 6) {
                    ForEach(Array(dots.enumerated()), id: \.offset) { _, c in
                        Circle().fill(c).frame(width: 16, height: 16)
                    }
                }
                Text(title)
                    .font(.body(TypeScale.body))
                    .foregroundStyle(active ? Tok.citrus : Tok.bone)
                Spacer()
                Text("Custom colours soon")
                    .font(.body(TypeScale.micro))
                    .foregroundStyle(Tok.bone3)
            }
            .padding(Tok.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous).fill(Tok.turf800.opacity(0.6)))
            .overlay {
                RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                    .strokeBorder(active ? Tok.citrus : Tok.line, lineWidth: active ? 1.5 : 1)
            }
        }
        .buttonStyle(PressScale())
    }

    // MARK: Joints

    private var jointsSection: some View {
        VStack(alignment: .leading, spacing: Tok.s4) {
            VStack(alignment: .leading, spacing: 6) {
                Text("JOINTS")
                    .font(.data(TypeScale.nano))
                    .tracking(1.5)
                    .foregroundStyle(Tok.bone3)
                Text("Tap a joint to follow its path through the swing, or to read the angle at it.")
                    .font(.body(TypeScale.small))
                    .foregroundStyle(Tok.bone2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(JointGroup.allCases) { group in
                VStack(alignment: .leading, spacing: Tok.s2) {
                    Text(group.rawValue)
                        .font(.body(TypeScale.small))
                        .foregroundStyle(Tok.bone3)
                    ForEach(group.joints) { joint in
                        jointRow(joint)
                    }
                }
            }
        }
    }

    private func jointRow(_ joint: JointKey) -> some View {
        let isOpen = expanded.contains(joint)
        return VStack(spacing: Tok.s2) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    if isOpen {
                        expanded.remove(joint)
                        // Closing the joint that owns the header line clears it.
                        if activeJoint == joint { activeJoint = nil }
                    } else {
                        expanded.insert(joint)
                        // Opening a joint hands it the header status line.
                        activeJoint = joint
                    }
                }
            } label: {
                HStack(spacing: Tok.s2) {
                    Text(joint.label)
                        .font(.body(TypeScale.body))
                        .foregroundStyle(Tok.bone)
                        .layoutPriority(1)
                    Spacer(minLength: Tok.s2)
                    /*
                      The joint's live status, on the same line as its name and
                      visible whether the row is open or shut. That is the whole
                      point: a golfer scanning the list sees which joints are
                      tracked and which are printing angles without opening twelve
                      rows one at a time. Dimmer and smaller than the name so the
                      name still leads, and allowed to shrink rather than push the
                      chevron off the row.
                    */
                    if let status = jointStatusText(joint) {
                        Text(status)
                            .font(.body(TypeScale.micro))
                            .foregroundStyle(Tok.bone3)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Tok.bone3)
                }
                .padding(Tok.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous).fill(Tok.turf800.opacity(0.5)))
                .overlay {
                    RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                        .strokeBorder(Tok.line, lineWidth: 1)
                }
            }
            .buttonStyle(PressScale())

            if isOpen {
                let binding = settings.binding(for: joint)
                toggleRow(
                    title: "Track joint",
                    hint: "Draws its path through the swing",
                    isOn: binding.track
                )
                toggleRow(
                    title: "Show inner joint angle",
                    hint: nil,
                    isOn: binding.innerAngle,
                    showsStyleGear: true
                )
                toggleRow(
                    title: "Show outer joint angle",
                    hint: nil,
                    isOn: binding.outerAngle,
                    showsStyleGear: true
                )
                /*
                  The per joint line switch, last in the row's stack because it
                  governs the drawing rather than a readout. Kept as a fourth
                  toggleRow rather than a separate icon button so it reads and
                  behaves exactly like the three above it: same hit area, same
                  On/Off word, nothing new to learn. The global "Show connecting
                  lines" switch at the top of the sheet still wins when it is off,
                  which the hint says outright so a golfer is never left wondering
                  why this one did nothing.
                */
                toggleRow(
                    title: "Show connecting line",
                    hint: settings.showConnectingLines
                        ? "Draws the bones meeting at this joint"
                        : "Turn on Show connecting lines above first",
                    isOn: binding.showLine
                )

                if angleStyleOpen {
                    angleStylePanel
                }
            }
        }
    }

    private func toggleRow(
        title: String,
        hint: String?,
        isOn: Binding<Bool>,
        showsStyleGear: Bool = false
    ) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: Tok.s2) {
                Button {
                    isOn.wrappedValue.toggle()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.body(TypeScale.small))
                                .foregroundStyle(Tok.bone)
                            if let hint {
                                Text(hint)
                                    .font(.body(TypeScale.micro))
                                    .foregroundStyle(Tok.bone3)
                            }
                        }
                        Spacer()
                        Text(isOn.wrappedValue ? "On" : "Off")
                            .font(.data(TypeScale.small))
                            .foregroundStyle(isOn.wrappedValue ? Tok.citrus : Tok.bone3)
                    }
                    .padding(Tok.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous).fill(Tok.turf800.opacity(0.4)))
                }
                .buttonStyle(PressScale())

                if showsStyleGear {
                    Button {
                        withAnimation(.easeInOut(duration: 0.14)) { angleStyleOpen.toggle() }
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14))
                            .foregroundStyle(angleStyleOpen ? Tok.citrus : Tok.bone3)
                            .frame(width: 46, height: 46)
                            .background(RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous).fill(Tok.turf800.opacity(0.4)))
                            .overlay {
                                RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                                    .strokeBorder(angleStyleOpen ? Tok.citrus : Tok.line, lineWidth: 1)
                            }
                    }
                    .buttonStyle(PressScale())
                    .accessibilityLabel("Angle display settings")
                }
            }

        }
        .padding(.leading, Tok.s3)
    }

    /*
      How the angle readouts look. One shared style rather than a copy per joint:
      a golfer wants their angles to read the same everywhere, and per joint
      styling would be a lot of state for very little gain.
    */
    private var angleStylePanel: some View {
        VStack(alignment: .leading, spacing: Tok.s3) {
            Text("ANGLE DISPLAY")
                .font(.data(TypeScale.nano))
                .tracking(1.5)
                .foregroundStyle(Tok.bone3)

            Toggle(isOn: $settings.angle.showDegrees) {
                Text("Show the degree figure")
                    .font(.body(TypeScale.small))
                    .foregroundStyle(Tok.bone)
            }
            .tint(Tok.citrus)

            if settings.angle.showDegrees {
                sliderRow(
                    title: "Text size",
                    value: $settings.angle.fontSize,
                    range: AngleStyle.fontSizeRange,
                    format: "%.0f"
                )
                colourPickerRow(title: "Text colour", hex: $settings.angle.fontColorHex)
            }

            Divider().overlay(Tok.line)

            Toggle(isOn: $settings.angle.showArc) {
                Text("Show the arc between joints")
                    .font(.body(TypeScale.small))
                    .foregroundStyle(Tok.bone)
            }
            .tint(Tok.citrus)

            if settings.angle.showArc {
                sliderRow(
                    title: "Arc thickness",
                    value: $settings.angle.arcThickness,
                    range: AngleStyle.arcThicknessRange,
                    format: "%.1f"
                )
                sliderRow(
                    title: "Arc size",
                    value: $settings.angle.arcRadius,
                    range: AngleStyle.arcRadiusRange,
                    format: "%.0f"
                )
                colourPickerRow(title: "Arc colour", hex: $settings.angle.arcColorHex)
            }
        }
        .padding(Tok.s3)
        .background(RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous).fill(Tok.turf800.opacity(0.4)))
        .overlay {
            RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                .strokeBorder(Tok.line, lineWidth: 1)
        }
        .padding(.leading, Tok.s3)
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.body(TypeScale.micro))
                    .foregroundStyle(Tok.bone2)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.data(TypeScale.micro))
                    .foregroundStyle(Tok.bone3)
            }
            Slider(value: value, in: range)
                .tint(Tok.citrus)
        }
    }
}


