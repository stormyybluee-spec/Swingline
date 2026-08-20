//
//  Components.swift
//  Swingline
//
//  The reusable pieces, plus the icon set.
//
//  Icons are hand converted from the inline SVGs in src/components/Nav.jsx and
//  src/screens/Home.jsx. Arcs in the originals are approximated with curves so
//  there is no SVG sweep flag ambiguity to get wrong. They are close, not
//  traced. Eyeball them against the web app and adjust before release.
//

import SwiftUI

// MARK: - Icon scaffold

// Every icon in the web app is drawn on a fixed viewBox and stroked with
// currentColor. This scales any viewBox to the requested point size and keeps
// the stroke weight proportional, exactly as the SVGs do.
struct IconShape: Shape {
    let viewBox: CGFloat
    // Shape inherits Sendable, so a stored closure has to be Sendable too or
    // the whole struct stops conforming under Swift 6. Every builder passed in
    // captures nothing beyond the icon's own value fields, so this costs
    // nothing at the call sites.
    let build: @Sendable (inout Path, CGFloat) -> Void

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let scale = min(rect.width, rect.height) / viewBox
        build(&p, scale)
        return p
    }
}

struct SLIcon: View {
    enum Kind {
        case home, timeline, record, coach, settings
        case flame, stack, target, metronome, satellite, shutter
        case close, gear, flip
    }

    let kind: Kind
    var size: CGFloat = 18
    var lineWidth: CGFloat = 1.6
    var filled: Bool = false

    // Some icons render as SF Symbols rather than hand drawn paths, so they need
    // no bundled asset and no custom geometry. satellite is one: the antenna
    // symbol reads correctly and removes the only icon that was pulling a
    // resource lookup. Returns nil for kinds that stay vector drawn.
    private var systemSymbol: String? {
        switch kind {
        case .satellite: return "antenna.radiowaves.left.and.right"
        default: return nil
        }
    }

    var body: some View {
        Group {
            if let symbol = systemSymbol {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.82, weight: .regular))
                    // Match the stroke tint the vector icons take from
                    // foregroundStyle, so satellite looks like the rest.
                    .symbolRenderingMode(.monochrome)
            } else {
                ZStack {
                    strokeLayer
                    if filled { fillLayer }
                }
            }
        }
        .frame(width: size, height: size)
    }

    private var strokeLayer: some View {
        // kind and viewBox are plain value types, so capturing them in the
        // @Sendable path builder is free and crosses no isolation boundary.
        let kind = self.kind
        return IconShape(viewBox: viewBox) { p, s in SLIcon.draw(kind, &p, s) }
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }

    @ViewBuilder private var fillLayer: some View {
        switch kind {
        case .record, .shutter:
            let isRecord = kind == .record
            let box = viewBox
            IconShape(viewBox: viewBox) { p, s in
                let c = CGPoint(x: box / 2 * s, y: box / 2 * s)
                let r = (isRecord ? 2.8 : 3.4) * s
                p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            }
        case .target:
            IconShape(viewBox: 24) { p, s in
                p.addEllipse(in: CGRect(x: 11 * s, y: 11 * s, width: 2 * s, height: 2 * s))
            }
        default:
            EmptyView()
        }
    }

    private var viewBox: CGFloat {
        switch kind {
        case .home, .timeline, .record, .coach, .settings: return 18
        default: return 24
        }
    }

    // nonisolated and takes kind by value, so it can be called from inside the
    // @Sendable path builder IconShape stores without crossing main actor
    // isolation. The drawing is pure geometry and never needs the view's actor.
    private nonisolated static func draw(_ kind: Kind, _ p: inout Path, _ s: CGFloat) {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }

        switch kind {

        case .home:
            // M3 7.6 9 2.8l6 4.8V15.8H3.8V7.6Z, corner radii dropped.
            p.move(to: pt(3, 7.6))
            p.addLine(to: pt(9, 2.8))
            p.addLine(to: pt(15, 7.6))
            p.addLine(to: pt(15, 15.8))
            p.addLine(to: pt(3, 15.8))
            p.closeSubpath()

        case .timeline:
            // M3 4.5h12 M3 9h12 M3 13.5h8
            p.move(to: pt(3, 4.5)); p.addLine(to: pt(15, 4.5))
            p.move(to: pt(3, 9)); p.addLine(to: pt(15, 9))
            p.move(to: pt(3, 13.5)); p.addLine(to: pt(11, 13.5))

        case .record:
            p.addEllipse(in: CGRect(x: (9 - 6.4) * s, y: (9 - 6.4) * s, width: 12.8 * s, height: 12.8 * s))

        case .coach:
            // Rounded speech bubble with a tail down to the lower left.
            p.move(to: pt(5, 3.5))
            p.addLine(to: pt(13, 3.5))
            p.addQuadCurve(to: pt(15, 5.5), control: pt(15, 3.5))
            p.addLine(to: pt(15, 10.5))
            p.addQuadCurve(to: pt(13, 12.5), control: pt(15, 12.5))
            p.addLine(to: pt(7, 12.5))
            p.addLine(to: pt(3, 15.5))
            p.addLine(to: pt(3, 5.5))
            p.addQuadCurve(to: pt(5, 3.5), control: pt(3, 3.5))
            p.closeSubpath()

        case .settings, .gear:
            let box: CGFloat = kind == .gear ? 24 : 18
            let c = box / 2
            let r: CGFloat = kind == .gear ? 3.4 : 2.6
            p.addEllipse(in: CGRect(x: (c - r) * s, y: (c - r) * s, width: r * 2 * s, height: r * 2 * s))
            let inner: CGFloat = kind == .gear ? 5.6 : 4.2
            let outer: CGFloat = kind == .gear ? 9.6 : 7.2
            for i in 0..<8 {
                let a = Double(i) * .pi / 4
                let cosA = CGFloat(cos(a) as Double)
                let sinA = CGFloat(sin(a) as Double)
                p.move(to: CGPoint(x: (c + cosA * inner) * s, y: (c + sinA * inner) * s))
                p.addLine(to: CGPoint(x: (c + cosA * outer) * s, y: (c + sinA * outer) * s))
            }

        case .flame:
            // Home streak node.
            p.move(to: pt(12, 3))
            p.addCurve(to: pt(11, 9.4), control1: pt(13.6, 6.4), control2: pt(12.4, 8))
            p.addCurve(to: pt(8, 15), control1: pt(9.3, 11.2), control2: pt(8, 12.7))
            p.addQuadCurve(to: pt(16, 15), control: pt(12, 20.4))
            p.addCurve(to: pt(14.4, 11.1), control1: pt(16, 13.4), control2: pt(15.3, 12.2))
            p.addCurve(to: pt(16.7, 12.7), control1: pt(15.3, 11.3), control2: pt(16.1, 11.9))
            p.addCurve(to: pt(12, 3), control1: pt(17.4, 9.3), control2: pt(15.5, 5.1))
            p.closeSubpath()

        case .stack:
            // Recorded swings node.
            p.move(to: pt(12, 3)); p.addLine(to: pt(3, 7.5)); p.addLine(to: pt(12, 12))
            p.addLine(to: pt(21, 7.5)); p.closeSubpath()
            p.move(to: pt(3, 12.5)); p.addLine(to: pt(12, 17)); p.addLine(to: pt(21, 12.5))
            p.move(to: pt(3, 17)); p.addLine(to: pt(12, 21.5)); p.addLine(to: pt(21, 17))

        case .target:
            p.addEllipse(in: CGRect(x: 3.5 * s, y: 3.5 * s, width: 17 * s, height: 17 * s))
            p.addEllipse(in: CGRect(x: 7.5 * s, y: 7.5 * s, width: 9 * s, height: 9 * s))

        case .metronome:
            p.move(to: pt(9.5, 3)); p.addLine(to: pt(14.5, 3))
            p.addLine(to: pt(18, 21)); p.addLine(to: pt(6, 21)); p.closeSubpath()
            p.move(to: pt(7, 15)); p.addLine(to: pt(17, 15))
            p.move(to: pt(15.5, 6)); p.addLine(to: pt(9, 17))

        case .satellite:
            p.addEllipse(in: CGRect(x: 9.4 * s, y: 9.4 * s, width: 5.2 * s, height: 5.2 * s))
            arcRing(&p, s, radius: 7.8, from: -90, to: 0)
            arcRing(&p, s, radius: 5.1, from: -90, to: 0)
            arcRing(&p, s, radius: 7.8, from: 90, to: 180)
            arcRing(&p, s, radius: 5.1, from: 90, to: 180)

        case .shutter:
            p.addEllipse(in: CGRect(x: 3.5 * s, y: 3.5 * s, width: 17 * s, height: 17 * s))

        case .close:
            p.move(to: pt(7, 7)); p.addLine(to: pt(17, 17))
            p.move(to: pt(17, 7)); p.addLine(to: pt(7, 17))

        case .flip:
            p.move(to: pt(4, 9)); p.addLine(to: pt(20, 9))
            p.addLine(to: pt(16, 5))
            p.move(to: pt(20, 15)); p.addLine(to: pt(4, 15))
            p.addLine(to: pt(8, 19))
        }
    }

    // Quarter ring segments for the satellite icon, sampled rather than arced.
    // nonisolated static to match draw, which calls it. It uses only its
    // parameters and local constants, no instance state, so this is a safe
    // conversion and is what lets the static draw call it.
    private nonisolated static func arcRing(_ p: inout Path, _ s: CGFloat, radius: CGFloat, from: Double, to: Double) {
        let centre = CGPoint(x: 12 * s, y: 12 * s)
        let steps = 14
        for i in 0...steps {
            let deg = from + (to - from) * Double(i) / Double(steps)
            let a = deg * .pi / 180
            let cosA = CGFloat(cos(a) as Double)
            let sinA = CGFloat(sin(a) as Double)
            let point = CGPoint(x: centre.x + cosA * radius * s, y: centre.y + sinA * radius * s)
            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
    }
}

// MARK: - Navigation pill

// src/components/Nav.jsx. Fixed to the bottom, a glass pill capped at 420
// wide, with the active tab marked by a moving turf700 lozenge.
struct NavigationPill: View {
    let current: Screen
    let onGo: (Screen) -> Void

    @Namespace private var pill

    private struct Tab: Identifiable {
        var screen: Screen
        var label: String
        var icon: SLIcon.Kind
        var id: String { screen.rawValue }
    }

    private let tabs: [Tab] = [
        Tab(screen: .home, label: "Home", icon: .home),
        Tab(screen: .timeline, label: "Timeline", icon: .timeline),
        Tab(screen: .capture, label: "Record", icon: .record),
        Tab(screen: .coach, label: "Coach", icon: .coach),
        Tab(screen: .settings, label: "Settings", icon: .settings),
    ]

    var body: some View {
        HStack(spacing: Tok.s1) {
            ForEach(tabs) { tab in
                let active = current == tab.screen
                Button {
                    onGo(tab.screen)
                } label: {
                    VStack(spacing: 3) {
                        SLIcon(kind: tab.icon, size: 18, filled: active && tab.screen == .capture)
                        Text(tab.label)
                            .font(.body(10))
                            .tracking(0.4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .padding(.horizontal, Tok.s1)
                    .foregroundStyle(active ? Tok.bone : Tok.bone3)
                    .background {
                        if active {
                            Capsule()
                                .fill(Tok.turf700)
                                .matchedGeometryEffect(id: "nav-pill", in: pill)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .glass(radius: 999)
        .frame(maxWidth: 420)
        .padding(.horizontal, Tok.s4)
        .padding(.vertical, Tok.s2)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(
                colors: [.clear, Tok.ink],
                startPoint: .top,
                endPoint: .init(x: 0.5, y: 0.55)
            )
            .ignoresSafeArea(edges: .bottom)
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: current)
    }
}

// MARK: - Floating stat, the home orbit node

// src/screens/Home.jsx OrbitNode. A glass disc with a three line caption under
// it, the whole thing tappable.
struct FloatingStatView: View {
    let label: String
    let value: String
    let unit: String
    let icon: SLIcon.Kind
    var wide: Bool = false
    var active: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                SLIcon(kind: icon, size: 19)
                    .foregroundStyle(active ? Tok.citrus : Tok.bone2)
                    .frame(width: 46, height: 46)
                    .glass(radius: 23, border: active ? Tok.citrus : Tok.glassEdge)
                    .shadow(color: active ? Tok.citrus.opacity(0.5) : .clear, radius: 12)

                VStack(spacing: 0) {
                    Text(label.uppercased())
                        .font(.body(9))
                        .tracking(0.9)
                        .foregroundStyle(Tok.bone3)
                    Text(value)
                        .font(.body(TypeScale.small, weight: .medium))
                        .foregroundStyle(Tok.bone)
                    Text(unit)
                        .font(.body(9))
                        .foregroundStyle(Tok.bone3)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            .frame(width: wide ? 92 : 76)
        }
        .buttonStyle(PressScale())
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Stats card

// The single large figure on Home, the role the yardage card plays in the
// reference. Also reused for any small glass readout block.
struct StatsCardView: View {
    let eyebrow: String
    let value: String
    let caption: String
    var dotColor: Color? = Tok.rust

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Tok.s2) {
                if let dotColor {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
                }
                Eyebrow(text: eyebrow)
            }
            Text(value)
                .font(.serif(42))
                .foregroundStyle(Tok.bone)
                .lineSpacing(0)
            Text(caption)
                .font(.body(TypeScale.nano))
                .foregroundStyle(Tok.bone3)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
        .glass(radius: Tok.rMd)
    }
}

// MARK: - Settings controls

// A row of pill options. src/screens/Settings.jsx Choice.
struct ChoiceRow: View {
    let label: String
    let options: [Option]
    let selection: String
    var joinNote: Bool = false
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.s2) {
            Text(label)
                .font(.body(TypeScale.small))
                .foregroundStyle(Tok.bone)

            FlowRow(spacing: 6) {
                ForEach(options) { option in
                    let selected = option.value == selection
                    Button {
                        onSelect(option.value)
                    } label: {
                        Text(joinNote ? SettingsOptions.joined(option) : option.label)
                            .font(.body(TypeScale.micro))
                            .padding(.vertical, 8)
                            .padding(.horizontal, 13)
                            .foregroundStyle(selected ? Tok.fairwayLit : Tok.bone3)
                            .overlay {
                                Capsule().strokeBorder(selected ? Tok.fairwayLit : Tok.line, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Tok.line).frame(height: 1) }
    }
}

// Colour swatch pills for the ball trace colour.
struct ColorChoiceRow: View {
    let label: String
    let options: [Option]
    let selection: String
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.s2) {
            Text(label)
                .font(.body(TypeScale.small))
                .foregroundStyle(Tok.bone)

            FlowRow(spacing: Tok.s2) {
                ForEach(options) { option in
                    let selected = option.value == selection
                    Button {
                        onSelect(option.value)
                    } label: {
                        HStack(spacing: Tok.s2) {
                            Circle()
                                .fill(Color(hex: option.value))
                                .frame(width: 12, height: 12)
                                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                            Text(option.label)
                                .font(.body(TypeScale.micro))
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 12)
                        .foregroundStyle(selected ? Tok.bone : Tok.bone3)
                        .overlay {
                            Capsule().strokeBorder(selected ? Tok.bone : Tok.line, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Tok.line).frame(height: 1) }
    }
}

// src/screens/Settings.jsx Switch. Custom rather than a system Toggle so the
// track and knob colours match the web app.
struct SwitchRow: View {
    let label: String
    var note: String? = nil
    let isOn: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        Button {
            onChange(!isOn)
        } label: {
            HStack(alignment: .center, spacing: Tok.s4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.body(TypeScale.small))
                        .foregroundStyle(Tok.bone)
                    if let note {
                        Text(note)
                            .font(.body(TypeScale.micro))
                            .foregroundStyle(Tok.bone3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? Tok.fairwayLit : Tok.turf600)
                    Circle().fill(isOn ? Tok.ink : Tok.bone3).frame(width: 21, height: 21)
                }
                .frame(width: 46, height: 27)
                .padding(3)
                .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isOn)
            }
            .multilineTextAlignment(.leading)
            .padding(.vertical, 15)
            .overlay(alignment: .bottom) { Rectangle().fill(Tok.line).frame(height: 1) }
        }
        .buttonStyle(.plain)
    }
}

// src/screens/Settings.jsx Row. A label and an action button.
struct ActionRow: View {
    let label: String
    var note: String? = nil
    let action: String
    var danger: Bool = false
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: Tok.s4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.body(TypeScale.small))
                    .foregroundStyle(Tok.bone)
                if let note {
                    Text(note)
                        .font(.body(TypeScale.micro))
                        .foregroundStyle(Tok.bone3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onAction) {
                Text(action)
                    .font(.body(TypeScale.micro))
                    .lineLimit(1)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 15)
                    .foregroundStyle(danger ? Tok.rust : Tok.bone)
                    .overlay {
                        Capsule().strokeBorder(danger ? Tok.rust : Tok.lineStrong, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 15)
        .overlay(alignment: .bottom) { Rectangle().fill(Tok.line).frame(height: 1) }
    }
}

// src/screens/Settings.jsx Dropdown. A Menu rather than a wheel picker, since
// the web app deliberately uses the platform's own picker for ten languages.
struct DropdownRow: View {
    let label: String
    let options: [Option]
    let selection: String
    let onSelect: (String) -> Void

    private var currentLabel: String {
        options.first { $0.value == selection }?.label ?? selection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.s2) {
            Text(label)
                .font(.body(TypeScale.small))
                .foregroundStyle(Tok.bone)

            Menu {
                ForEach(options) { option in
                    Button(option.label) { onSelect(option.value) }
                }
            } label: {
                HStack {
                    Text(currentLabel)
                        .font(.body(TypeScale.small))
                        .foregroundStyle(Tok.bone)
                    Spacer()
                    Text("\u{25BE}")
                        .font(.body(12))
                        .foregroundStyle(Tok.bone3)
                }
                .padding(.vertical, 12)
                .padding(.leading, 14)
                .padding(.trailing, 14)
                .background(RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous).fill(Tok.turf800))
                .overlay {
                    RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                        .strokeBorder(Tok.lineStrong, lineWidth: 1)
                }
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Tok.line).frame(height: 1) }
    }
}

// src/screens/Settings.jsx Slider.
struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.s2) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.body(TypeScale.small))
                    .foregroundStyle(Tok.bone)
                Spacer()
                Text(format(value))
                    .font(.data(TypeScale.micro))
                    .foregroundStyle(Tok.bone3)
            }
            Slider(value: $value, in: range, step: step)
                .tint(Tok.citrus)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Tok.line).frame(height: 1) }
    }
}

// A settings group: an eyebrow heading and its rows.
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: title)
                .padding(.bottom, 14)
            VStack(alignment: .leading, spacing: Tok.s1) {
                content()
            }
        }
    }
}

// MARK: - Flow layout

// Wraps pills onto new lines the way CSS flex-wrap does. Used by every choice
// row, since the option labels are long enough to wrap on a phone.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Toast

struct ToastView: View {
    let toast: AppStore.Toast
    let onDismiss: () -> Void

    private var accent: Color {
        switch toast.tone {
        case .good: return Tok.fairwayLit
        case .warn: return Tok.rust
        case .info: return Tok.lineStrong
        }
    }

    var body: some View {
        Text(toast.message)
            .font(.body(TypeScale.small))
            .foregroundStyle(Tok.bone)
            .multilineTextAlignment(.center)
            .padding(.vertical, 14)
            .padding(.horizontal, 20)
            .glass(radius: 999, border: accent)
            .padding(.horizontal, Tok.s5)
            .onTapGesture(perform: onDismiss)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
