//
//  CourseAerial.swift
//  Swingline
//
//  Port of src/components/CourseAerial.jsx, path for path.
//
//  Drawn rather than photographed, and drawn as flat shapes rather than blurred
//  layers. The web version learned that the hard way: four elements carrying a
//  46px blur underneath the intro film is one of the most expensive things a
//  phone can be asked to composite. Softness here comes from gradients, which
//  cost nothing. Keep it that way, do not reach for .blur().
//
//  Original viewBox is 400 x 780 with preserveAspectRatio xMidYMin slice, which
//  is reproduced below as a scale-to-fill anchored to the top and centred
//  horizontally.
//

import SwiftUI

struct CourseAerial: View {
    var opacity: Double = 1

    private static let vbWidth: CGFloat = 400
    private static let vbHeight: CGFloat = 780

    private static let sand = Color(hex: "#efe3c8")
    private static let sandShade = Color(hex: "#d8c9a6")

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            // xMidYMin slice
            let scale = max(size.width / Self.vbWidth, size.height / Self.vbHeight)
            let dx = (size.width - Self.vbWidth * scale) / 2
            let dy: CGFloat = 0

            Canvas { context, _ in
                context.translateBy(x: dx, y: dy)
                context.scaleBy(x: scale, y: scale)
                draw(&context)
            }
            .opacity(opacity)
        }
        .allowsHitTesting(false)
    }

    private func draw(_ context: inout GraphicsContext) {
        let full = CGRect(x: 0, y: 0, width: Self.vbWidth, height: Self.vbHeight)

        // Rough, the darkest ground, behind everything.
        context.fill(
            Path(full),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(hex: "#1b3d27"), location: 0),
                    .init(color: Color(hex: "#16331f"), location: 0.55),
                    .init(color: Color(hex: "#0f2417"), location: 1),
                ]),
                startPoint: .zero,
                endPoint: CGPoint(x: Self.vbWidth, y: Self.vbHeight)
            )
        )

        // Fairway, sweeping from bottom left up through the frame.
        let fairway = fairwayPath()
        context.fill(
            fairway,
            with: .linearGradient(
                Gradient(colors: [Color(hex: "#3f8f4a"), Color(hex: "#4da045"), Color(hex: "#5cb04a")]),
                startPoint: CGPoint(x: 0.2 * Self.vbWidth, y: 0),
                endPoint: CGPoint(x: 0.8 * Self.vbWidth, y: Self.vbHeight)
            )
        )
        drawStripes(&context, clippedTo: fairway, opacityScale: 1)

        // Rough encroaching from the left, so the fairway edge does not read as
        // one clean curve.
        var encroach = Path()
        encroach.move(to: CGPoint(x: 0, y: 300))
        encroach.addCurve(
            to: CGPoint(x: 84, y: 452),
            control1: CGPoint(x: 60, y: 320),
            control2: CGPoint(x: 96, y: 386)
        )
        encroach.addCurve(
            to: CGPoint(x: 0, y: 600),
            control1: CGPoint(x: 74, y: 508),
            control2: CGPoint(x: 20, y: 540)
        )
        encroach.closeSubpath()
        context.fill(encroach, with: .color(Color(hex: "#173420").opacity(0.85)))

        // Bunkers. Peanut and kidney shapes, each with a shadow offset toward
        // the sun so every bunker on the hole agrees about where it is.
        for path in bunkerPaths() {
            let shadow = path.applying(CGAffineTransform(translationX: 6, y: 8))
            context.fill(shadow, with: .color(Color(hex: "#0f2417").opacity(0.4)))
            let bounds = path.boundingRect
            context.fill(
                path,
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: Self.sand, location: 0.6),
                        .init(color: Self.sandShade, location: 1),
                    ]),
                    center: CGPoint(x: bounds.midX, y: bounds.minY + bounds.height * 0.42),
                    startRadius: 0,
                    endRadius: max(bounds.width, bounds.height) * 0.7
                )
            )
        }

        // The green, the brightest thing on the hole.
        let greenRect = CGRect(x: 232 - 104, y: 612 - 86, width: 208, height: 172)
        let green = Path(ellipseIn: greenRect)
        context.fill(
            green,
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: Color(hex: "#93d63c"), location: 0),
                    .init(color: Color(hex: "#74c235"), location: 0.7),
                    .init(color: Color(hex: "#5aa62f"), location: 1),
                ]),
                center: CGPoint(x: greenRect.midX, y: greenRect.minY + greenRect.height * 0.45),
                startRadius: 0,
                endRadius: greenRect.width * 0.55
            )
        )
        drawStripes(&context, clippedTo: green, opacityScale: 0.6)
        context.stroke(green, with: .color(Color(hex: "#2f6b28").opacity(0.35)), lineWidth: 1.5)

        // Hole, pin and flag.
        context.fill(
            Path(ellipseIn: CGRect(x: 246 - 3.4, y: 596 - 3.4, width: 6.8, height: 6.8)),
            with: .color(Color(hex: "#1d3a1c").opacity(0.7))
        )
        var pin = Path()
        pin.move(to: CGPoint(x: 246, y: 596))
        pin.addLine(to: CGPoint(x: 246, y: 566))
        context.stroke(pin, with: .color(Color(hex: "#f5f2e8")), lineWidth: 1.6)

        var flag = Path()
        flag.move(to: CGPoint(x: 246, y: 566))
        flag.addLine(to: CGPoint(x: 262, y: 572))
        flag.addLine(to: CGPoint(x: 246, y: 578))
        flag.closeSubpath()
        context.fill(flag, with: .color(Tok.citrus))

        var pinShadow = Path()
        pinShadow.move(to: CGPoint(x: 246, y: 596))
        pinShadow.addLine(to: CGPoint(x: 258, y: 604))
        context.stroke(
            pinShadow,
            with: .color(Color(hex: "#1d3a1c").opacity(0.28)),
            style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
        )

        // Players, tiny, with the long shadows that make an aerial read as a
        // photograph taken late in the day.
        for figure in [CGPoint(x: 196, y: 470), CGPoint(x: 210, y: 480), CGPoint(x: 186, y: 486)] {
            var shadow = Path()
            shadow.move(to: figure)
            shadow.addLine(to: CGPoint(x: figure.x + 22, y: figure.y + 11))
            context.stroke(
                shadow,
                with: .color(Color(hex: "#0f2417").opacity(0.42)),
                style: StrokeStyle(lineWidth: 2.6, lineCap: .round)
            )
            context.fill(
                Path(ellipseIn: CGRect(x: figure.x - 2.6, y: figure.y - 2.6, width: 5.2, height: 5.2)),
                with: .color(Color(hex: "#f5f2e8"))
            )
        }

        // Side fade, then the dissolve into the app background before the
        // artwork reaches any content.
        context.fill(
            Path(full),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: Tok.ink.opacity(0.55), location: 0),
                    .init(color: Tok.ink.opacity(0), location: 0.26),
                    .init(color: Tok.ink.opacity(0), location: 0.74),
                    .init(color: Tok.ink.opacity(0.55), location: 1),
                ]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: Self.vbWidth, y: 0)
            )
        )
        context.fill(
            Path(full),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: Tok.ink.opacity(0.25), location: 0),
                    .init(color: Tok.ink.opacity(0.72), location: 0.42),
                    .init(color: Tok.ink.opacity(0.97), location: 0.72),
                    .init(color: Tok.ink.opacity(1), location: 1),
                ]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: Self.vbHeight)
            )
        )
    }

    // Mowing stripes, alternating light and dark bands at a slight angle. That
    // angle is what gives an aerial its texture.
    private func drawStripes(_ context: inout GraphicsContext, clippedTo shape: Path, opacityScale: Double) {
        context.drawLayer { layer in
            layer.clip(to: shape)
            layer.rotate(by: .degrees(-14))
            var x: CGFloat = -Self.vbHeight
            while x < Self.vbWidth + Self.vbHeight {
                let light = CGRect(x: x, y: -Self.vbHeight, width: 13, height: Self.vbHeight * 3)
                let dark = CGRect(x: x + 13, y: -Self.vbHeight, width: 13, height: Self.vbHeight * 3)
                layer.fill(Path(light), with: .color(.white.opacity(0.055 * opacityScale)))
                layer.fill(Path(dark), with: .color(.black.opacity(0.05 * opacityScale)))
                x += 26
            }
        }
    }

    private func fairwayPath() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 60, y: 780))
        p.addCurve(to: CGPoint(x: 150, y: 440), control1: CGPoint(x: 40, y: 620), control2: CGPoint(x: 120, y: 540))
        p.addCurve(to: CGPoint(x: 168, y: 176), control1: CGPoint(x: 178, y: 348), control2: CGPoint(x: 128, y: 262))
        p.addCurve(to: CGPoint(x: 300, y: 0), control1: CGPoint(x: 196, y: 114), control2: CGPoint(x: 268, y: 74))
        p.addLine(to: CGPoint(x: 400, y: 0))
        p.addLine(to: CGPoint(x: 400, y: 780))
        p.closeSubpath()
        return p
    }

    private func bunkerPaths() -> [Path] {
        var one = Path()
        one.move(to: CGPoint(x: 296, y: 96))
        one.addCurve(to: CGPoint(x: 372, y: 142), control1: CGPoint(x: 340, y: 78), control2: CGPoint(x: 378, y: 106))
        one.addCurve(to: CGPoint(x: 320, y: 208), control1: CGPoint(x: 366, y: 176), control2: CGPoint(x: 330, y: 182))
        one.addCurve(to: CGPoint(x: 252, y: 218), control1: CGPoint(x: 310, y: 236), control2: CGPoint(x: 268, y: 244))
        one.addCurve(to: CGPoint(x: 268, y: 148), control1: CGPoint(x: 236, y: 190), control2: CGPoint(x: 262, y: 168))
        one.addCurve(to: CGPoint(x: 296, y: 96), control1: CGPoint(x: 274, y: 126), control2: CGPoint(x: 272, y: 106))
        one.closeSubpath()

        var two = Path()
        two.move(to: CGPoint(x: 330, y: 236))
        two.addCurve(to: CGPoint(x: 386, y: 292), control1: CGPoint(x: 372, y: 226), control2: CGPoint(x: 398, y: 258))
        two.addCurve(to: CGPoint(x: 336, y: 348), control1: CGPoint(x: 376, y: 322), control2: CGPoint(x: 344, y: 322))
        two.addCurve(to: CGPoint(x: 282, y: 352), control1: CGPoint(x: 328, y: 374), control2: CGPoint(x: 292, y: 378))
        two.addCurve(to: CGPoint(x: 306, y: 286), control1: CGPoint(x: 272, y: 324), control2: CGPoint(x: 300, y: 306))
        two.addCurve(to: CGPoint(x: 330, y: 236), control1: CGPoint(x: 312, y: 264), control2: CGPoint(x: 310, y: 242))
        two.closeSubpath()

        var three = Path()
        three.move(to: CGPoint(x: 96, y: 512))
        three.addCurve(to: CGPoint(x: 164, y: 548), control1: CGPoint(x: 132, y: 496), control2: CGPoint(x: 168, y: 518))
        three.addCurve(to: CGPoint(x: 126, y: 598), control1: CGPoint(x: 160, y: 574), control2: CGPoint(x: 132, y: 578))
        three.addCurve(to: CGPoint(x: 78, y: 602), control1: CGPoint(x: 120, y: 620), control2: CGPoint(x: 88, y: 624))
        three.addCurve(to: CGPoint(x: 94, y: 548), control1: CGPoint(x: 68, y: 578), control2: CGPoint(x: 90, y: 564))
        three.addCurve(to: CGPoint(x: 96, y: 512), control1: CGPoint(x: 98, y: 530), control2: CGPoint(x: 80, y: 522))
        three.closeSubpath()

        return [one, two, three]
    }
}
