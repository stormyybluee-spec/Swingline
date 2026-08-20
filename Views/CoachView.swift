//
//  CoachView.swift
//  Swingline
//
//  Port of the shell of src/screens/Coach.jsx.
//
//  The coach runs locally, with no backend and no API key. That is a
//  constraint, not a shortcut: the promise the product makes is that a golfer's
//  swings never leave their device, and that promise does not survive posting
//  swing data to somebody else's server to generate a sentence. What the web
//  app has is a retrieval and templating layer over the golfer's real history,
//  which for this job is most of the value, because the useful thing a coach
//  says is almost always a specific fact about you at the right moment.
//
//  TEMPORARILY BEHIND A MAINTENANCE SCREEN. The chat, drill and tempo panels
//  are parked while the retrieval layer is reworked. Rather than show a shell
//  that looks broken, the screen states plainly that the coach is coming back,
//  with a single way out. The old panels can be restored from version control
//  when the engine work lands.
//

import SwiftUI

struct CoachView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ZStack {
            // Same ambient backdrop as the rest of the app, so this reads as a
            // Swingline screen rather than a system error page.
            AmbientGround()
                .ignoresSafeArea()

            VStack(spacing: Tok.s4) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Tok.citrus)

                Text("UNDER MAINTENANCE")
                    .font(.data(TypeScale.small))
                    .tracking(2)
                    .foregroundStyle(Tok.bone2)

                Text("Coming back Soon!")
                    .font(.serif(TypeScale.title))
                    .foregroundStyle(Tok.bone)
                    .multilineTextAlignment(.center)

                Text("The coach is parked while we rebuild it. Your swings, scores and history are all untouched.")
                    .font(.body(TypeScale.small))
                    .foregroundStyle(Tok.bone3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Tok.s4)

                Button {
                    store.back()
                } label: {
                    Text("Back")
                        .font(.body(TypeScale.small, weight: .bold))
                        .padding(.vertical, 12)
                        .padding(.horizontal, 28)
                        .foregroundStyle(Tok.ink)
                        .background(Capsule().fill(Tok.citrus))
                }
                .buttonStyle(PressScale())
                .padding(.top, Tok.s2)
            }
            .padding(Tok.s6)
            .frame(maxWidth: 420)
            .background {
                RoundedRectangle(cornerRadius: Tok.rLg, style: .continuous)
                    .fill(Tok.turf800.opacity(0.92))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Tok.rLg, style: .continuous)
                    .strokeBorder(Tok.line, lineWidth: 1)
            }
            .padding(Tok.s5)
            .shadow(color: Color.black.opacity(0.35), radius: 30, y: 16)
        }
    }
}
