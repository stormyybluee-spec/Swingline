//
//  Theme.swift
//  Swingline
//
//  Direct translation of src/styles/tokens.css and src/styles/global.css.
//  Every value here is copied from the web source, not invented. Screens
//  reference these, never a raw literal.
//
//  House rule: no em dashes anywhere.
//

import SwiftUI
import UIKit

// MARK: - Colour

extension Color {
    init(hex: String, opacity: Double = 1) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r = Double((value & 0xFF0000) >> 16) / 255
        let g = Double((value & 0x00FF00) >> 8) / 255
        let b = Double(value & 0x0000FF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }

    /*
      The colour back out as a hex string, so a picked colour can be persisted as
      plain text. Falls back to white if the components cannot be read, which
      keeps a stored value valid rather than empty.
    */
    var hexString: String {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return "#ffffff" }
        let ri = Int((r * 255).rounded())
        let gi = Int((g * 255).rounded())
        let bi = Int((b * 255).rounded())
        return String(format: "#%02x%02x%02x", ri, gi, bi)
    }
}

enum Tok {

    // Surfaces, deepest to most raised
    static let ink = Color(hex: "#080d0a")
    static let turf900 = Color(hex: "#0c140f")
    static let turf800 = Color(hex: "#111c15")
    static let turf700 = Color(hex: "#17281d")
    static let turf600 = Color(hex: "#1e3325")

    // Brand
    static let fairway = Color(hex: "#1e7a4c")
    static let fairwayLit = Color(hex: "#3fd98c")
    static let fairwayDim = Color(hex: "#3fd98c", opacity: 0.14)
    static let citrus = Color(hex: "#c8ff4d")
    static let citrusLit = Color(hex: "#e6ffa8")
    static let citrusDim = Color(hex: "#c8ff4d", opacity: 0.16)
    static let citrusDeep = Color(hex: "#8fd11f")

    // Matcha, home glass and intro wash
    static let matcha = Color(hex: "#a8c98a")
    static let matchaLit = Color(hex: "#cfe6b4")
    static let matchaGlass = Color(hex: "#a8c98a", opacity: 0.16)
    static let algae = Color(hex: "#7eb06c", opacity: 0.22)

    // Type colours
    static let bone = Color(hex: "#f0eadc")
    static let bone2 = Color(hex: "#a3aba0")
    static let bone3 = Color(hex: "#6d766b")

    // Semantic. Rust is the fault marker, warm, never alarming red.
    static let rust = Color(hex: "#c4593a")
    static let rustDim = Color(hex: "#c4593a", opacity: 0.15)
    static let slate = Color(hex: "#6cc9e0")

    // Category colours, used consistently on every chart and dial
    static let catSequencing = Color(hex: "#3fd98c")
    static let catRotation = Color(hex: "#c8ff4d")
    static let catBalance = Color(hex: "#6cc9e0")
    static let catFinish = Color(hex: "#d98cc4")

    // Hairlines and glass
    static let line = Color(hex: "#f0eadc", opacity: 0.09)
    static let lineStrong = Color(hex: "#f0eadc", opacity: 0.18)
    static let glassFill = Color(hex: "#17281d", opacity: 0.55)
    static let glassEdge = Color(hex: "#f0eadc", opacity: 0.12)

    // Spacing, 4px base
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 24
    static let s6: CGFloat = 32
    static let s7: CGFloat = 48
    static let s8: CGFloat = 64
    static let s9: CGFloat = 96

    // Radii
    static let rSm: CGFloat = 8
    static let rMd: CGFloat = 14
    static let rLg: CGFloat = 22
    static let rXl: CGFloat = 32

    static let navHeight: CGFloat = 68
    static let maxWidth: CGFloat = 720
}

// MARK: - Type

// The three families. Bundle Newsreader, Inter Tight and IBM Plex Mono in the
// target for parity. Font.custom falls back to the system face if a family is
// missing, so the app still builds and runs before the fonts are added.
enum Face {
    static let display = "Newsreader-Regular"
    static let displayMedium = "Newsreader-Medium"
    static let body = "InterTight-Regular"
    static let bodyMedium = "InterTight-Medium"
    static let bodySemibold = "InterTight-SemiBold"
    static let data = "IBMPlexMono-Regular"
}

extension Font {
    static func serif(_ size: CGFloat) -> Font { .custom(Face.display, size: size) }
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .semibold, .bold: name = Face.bodySemibold
        case .medium: name = Face.bodyMedium
        default: name = Face.body
        }
        return .custom(name, size: size)
    }
    static func data(_ size: CGFloat) -> Font { .custom(Face.data, size: size) }
}

// Type scale, 1.25 minor third off a 16pt base. The two clamped web sizes are
// resolved against the screen width the same way the CSS clamp did.
enum TypeScale {
    static func hero(_ width: CGFloat) -> CGFloat { min(max(41.6, width * 0.08), 73.6) }
    static func display(_ width: CGFloat) -> CGFloat { min(max(32, width * 0.055), 48) }
    static let title: CGFloat = 24
    static let head: CGFloat = 19
    static let body: CGFloat = 16
    static let small: CGFloat = 14
    static let micro: CGFloat = 12
    static let nano: CGFloat = 11
}

// MARK: - Surface styles

// The web `.glass` class. On iOS the blur is a material. Reduce Transparency
// drops it to a solid raised surface, which is the same trade the web version
// makes on a low performance device.
struct GlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var radius: CGFloat = Tok.rLg
    var borderColor: Color = Tok.glassEdge

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Tok.turf700.opacity(0.88))
                } else {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .fill(Tok.glassFill)
                        }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// The web `.card` class.
struct CardSurface: ViewModifier {
    var radius: CGFloat = Tok.rLg
    var borderColor: Color = Tok.line
    var padding: CGFloat = Tok.s5

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Tok.turf800))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            }
    }
}

extension View {
    func glass(radius: CGFloat = Tok.rLg, border: Color = Tok.glassEdge) -> some View {
        modifier(GlassSurface(radius: radius, borderColor: border))
    }
    func card(radius: CGFloat = Tok.rLg, border: Color = Tok.line, padding: CGFloat = Tok.s5) -> some View {
        modifier(CardSurface(radius: radius, borderColor: border, padding: padding))
    }
}

// The web `.eyebrow` type role.
struct Eyebrow: View {
    let text: String
    var color: Color = Tok.bone3
    var body: some View {
        Text(text.uppercased())
            .font(.data(TypeScale.nano))
            .tracking(TypeScale.nano * 0.18)
            .foregroundStyle(color)
    }
}

// The ambient ground wash from body::before. Sits behind everything.
struct AmbientGround: View {
    var body: some View {
        ZStack {
            Tok.ink
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                RadialGradient(
                    colors: [Tok.fairway.opacity(0.18), .clear],
                    center: UnitPoint(x: 0.5, y: -0.1),
                    startRadius: 0,
                    endRadius: max(w, h) * 1.0
                )
                RadialGradient(
                    colors: [Tok.citrus.opacity(0.07), .clear],
                    center: UnitPoint(x: 1.0, y: 1.0),
                    startRadius: 0,
                    endRadius: max(w, h) * 0.7
                )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// The `.screen` layout primitive: centred, capped at 720, padded, with room
// left at the bottom for the tab bar.
struct ScreenContainer<Content: View>: View {
    var topPadding: CGFloat = Tok.s5
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: Tok.maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Tok.s5)
            .padding(.top, topPadding)
            .padding(.bottom, Tok.navHeight + Tok.s8)
        }
        .scrollIndicators(.hidden)
    }
}

