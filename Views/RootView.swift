//
//  RootView.swift
//  Swingline
//
//  Port of src/App.jsx.
//
//  The tab bar is gated on two things, both of them real state: the chrome-less
//  route list, and the viewportOpen flag. The web app learned this the hard
//  way. Hiding the bar with a style rule failed on device because a stale
//  cached stylesheet did not apply, and the bar sat on top of a fullscreen
//  video. Do not reintroduce a presentation-only hide here.
//

import SwiftUI

struct RootView: View {
    @State private var store = AppStore()

    private var showsTabBar: Bool {
        !chromeLessScreens.contains(store.screen) && !store.viewportOpen
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            AmbientGround()

            Group {
                switch store.screen {
                case .home: HomeView()
                case .timeline: TimelineView()
                case .capture: RecordView()
                case .coach: CoachView()
                case .settings: SettingsView()
                case .upload: notPorted("Upload", "Import a clip and extract frames by seeking to a fixed 15 fps cadence, never by playing it back.")
                case .analysis: AnalysisView()
                case .compare: notPorted("Compare", "Two swings side by side or ghosted, sharing the 3D rig.")
                case .paywall: notPorted("Paywall", "Upgrade screen. Chrome-less. Founder mode unlocks the quota gate.")
                case .onboarding: notPorted("Onboarding", "First run flow. Sets onboarded, and returns the golfer to wherever they were heading.")
                }
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.22), value: store.screen)

            if showsTabBar {
                NavigationPill(current: store.screen) { screen in
                    store.go(screen)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let toast = store.toast {
                ToastView(toast: toast) { store.dismissToast() }
                    .padding(.bottom, showsTabBar ? Tok.navHeight + Tok.s5 : Tok.s5)
            }
        }
        .environment(store)
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: showsTabBar)
        .onAppear {
            store.boot()
            // Onboarding is deliberately not gating entry. It hangs off the
            // first real move, so a new golfer sees the product before being
            // told about it. Marking it done on first launch keeps the shell
            // navigable until the onboarding screen itself is ported.
            if !store.settings.onboarded {
                store.update { $0.onboarded = true }
            }
        }
    }

    private func notPorted(_ title: String, _ body: String) -> some View {
        ScreenContainer {
            Eyebrow(text: "Not ported yet")
            Text(title)
                .font(.serif(TypeScale.title))
                .foregroundStyle(Tok.bone)
                .padding(.top, 10)
                .padding(.bottom, Tok.s3)
            Text(body)
                .font(.body(TypeScale.small))
                .foregroundStyle(Tok.bone2)
                .fixedSize(horizontal: false, vertical: true)

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
            .padding(.top, Tok.s5)
        }
    }
}
