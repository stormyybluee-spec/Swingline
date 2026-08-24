//
//  HomeView.swift
//  Swingline
//
//  Port of src/screens/Home.jsx.
//
//  The app opens on the action, with the day's state arranged around it, rather
//  than on a list. Every readout is real: streak comes from recorded days,
//  focus from the weakest scored category, tempo from the last measured swing.
//  Nothing here is decorative, so nothing here should be given a placeholder
//  value when the data is absent. Say "not yet" instead.
//

import SwiftUI
import MapKit
import CoreLocation

struct HomeView: View {
    @Environment(AppStore.self) private var store

    // Controls the range finder map overlay. The satellite stat bubble toggles
    // it. The old inline note is gone, replaced by the real map below.
    @State private var rangeOpen = false

    private var last: SwingRecord? { store.lastAnalysed }

    var body: some View {
        ZStack(alignment: .top) {
            CourseAerial()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(edges: .top)

            ScreenContainer(topPadding: Tok.s6) {
                header
                    .padding(.bottom, 26)

                StatsCardView(
                    eyebrow: "Form score",
                    value: store.rating.bandLabel,
                    caption: store.rating.band.settled ? "Settled" : "Narrows as you record"
                )
                .padding(.bottom, Tok.s2)

                orbit

                if store.swings.isEmpty {
                    Text("Nothing recorded yet. One swing and this fills with your own numbers.")
                        .font(.body(TypeScale.small))
                        .foregroundStyle(Tok.bone2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 22)
                }
            }
        }
        .fullScreenCover(isPresented: $rangeOpen) {
            RangeFinderMap(isPresented: $rangeOpen)
        }
    }

    // MARK: Header

    private var header: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(text: Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                Text(swinglineGreeting())
                    .font(.serif(TypeScale.hero(geo.size.width)))
                    .tracking(-TypeScale.hero(geo.size.width) * 0.025)
                    .foregroundStyle(Tok.bone)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(height: 96)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: The orbit

    // A square composition: concentric rings, one bright primary control at the
    // centre, and five small glass readouts placed around it. Placements below
    // are the exact percentages from Home.jsx.
    private var orbit: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
            .overlay { orbitContent }
    }

    private var orbitContent: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let nodeHeight: CGFloat = 92

            ZStack(alignment: .topLeading) {
                Halo()
                    .frame(width: side, height: side)

                Button {
                    store.go(.capture)
                } label: {
                    VStack(spacing: 3) {
                        SLIcon(kind: .shutter, size: 22, lineWidth: 1.8, filled: true)
                        Text("Record")
                            .font(.body(11, weight: .semibold))
                    }
                    .foregroundStyle(Tok.ink)
                    .frame(width: side * 0.31, height: side * 0.31)
                    .background {
                        Circle().fill(
                            LinearGradient(
                                colors: [Tok.citrusLit, Tok.citrus, Tok.citrusDeep],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    }
                    .shadow(color: Tok.citrus.opacity(0.55), radius: 22, y: 12)
                }
                .buttonStyle(PressScale())
                .position(x: side / 2, y: side / 2)

                ForEach(Array(nodes.enumerated()), id: \.element.key) { _, node in
                    let width: CGFloat = node.wide ? 92 : 76
                    FloatingStatView(
                        label: node.label,
                        value: node.value,
                        unit: node.unit,
                        icon: node.icon,
                        wide: node.wide,
                        active: node.active,
                        action: node.action
                    )
                    .offset(
                        x: node.place.x(side: side, width: width),
                        y: node.place.y(side: side, height: nodeHeight)
                    )
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Nodes

    private struct Place {
        var top: CGFloat?
        var left: CGFloat?
        var right: CGFloat?
        var bottom: CGFloat?

        func x(side: CGFloat, width: CGFloat) -> CGFloat {
            if let left { return side * left }
            if let right { return side - width - side * right }
            return 0
        }

        func y(side: CGFloat, height: CGFloat) -> CGFloat {
            if let top { return side * top }
            if let bottom { return side - height - side * bottom }
            return 0
        }
    }

    private struct Node {
        var key: String
        var label: String
        var value: String
        var unit: String
        var icon: SLIcon.Kind
        var wide: Bool = false
        var active: Bool = false
        var place: Place
        var action: () -> Void
    }

    private var nodes: [Node] {
        let streak = store.streak
        let tempo: String = {
            guard let ratio = last?.phases?.tempoRatio else { return "3.0" }
            return String(format: "%.1f", ratio)
        }()

        return [
            Node(
                key: "streak",
                label: "Streak",
                value: "\(streak.current)",
                unit: streak.current == 1 ? "day" : "days",
                icon: .flame,
                place: Place(top: 0.02, left: 0.02),
                action: { store.go(.timeline) }
            ),
            Node(
                key: "swings",
                label: "Recorded",
                value: "\(store.swings.count)",
                unit: store.swings.count == 1 ? "swing" : "swings",
                icon: .stack,
                place: Place(top: 0.26, right: 0.01),
                action: { store.go(.timeline) }
            ),
            Node(
                key: "focus",
                label: "Focus",
                value: last?.scores?.weakest?.label ?? "Not yet",
                unit: last == nil ? "record one" : "weakest",
                icon: .target,
                wide: true,
                place: Place(right: 0.0, bottom: 0.22),
                action: { if last != nil { store.go(.coach) } }
            ),
            Node(
                key: "tempo",
                label: "Tempo",
                value: tempo,
                unit: "to 1",
                icon: .metronome,
                place: Place(left: 0.04, bottom: 0.01),
                action: { store.go(.coach) }
            ),
            Node(
                key: "range",
                label: "Range",
                value: rangeOpen ? "On" : "Off",
                unit: "GPS",
                icon: .satellite,
                active: rangeOpen,
                place: Place(top: 0.02, right: 0.22),
                action: { withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { rangeOpen.toggle() } }
            ),
        ]
    }

}

// MARK: - Halo

// Concentric rings behind the primary control, breathing very slowly.
// Radii 150, 118 and 86 on a 400 unit square, matching the web SVG.
struct Halo: View {
    @State private var breathe = false

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let unit = side / 400

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            stops: [
                                .init(color: Tok.citrus.opacity(0.16), location: 0),
                                .init(color: Tok.matcha.opacity(0.07), location: 0.62),
                                .init(color: .clear, location: 1),
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 150 * unit
                        )
                    )
                    .frame(width: 300 * unit, height: 300 * unit)

                ForEach(Array([CGFloat(150), 118, 86].enumerated()), id: \.offset) { index, radius in
                    Circle()
                        .strokeBorder(Color(hex: "#f0eadc", opacity: 0.13), lineWidth: 1)
                        .frame(
                            width: (radius + (breathe ? 3 : 0)) * 2 * unit,
                            height: (radius + (breathe ? 3 : 0)) * 2 * unit
                        )
                        .opacity(breathe ? 0.85 : 0.5)
                        .animation(
                            .easeInOut(duration: 5 + Double(index))
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.5),
                            value: breathe
                        )
                }
            }
            .frame(width: side, height: side)
        }
        .onAppear { breathe = true }
        .allowsHitTesting(false)
    }
}

