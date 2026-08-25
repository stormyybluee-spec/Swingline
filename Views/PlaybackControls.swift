//
//  PlaybackControls.swift
//  Swingline
//
//  The transport bar under the video: a scrubber, play and pause, single frame
//  step either way, a speed selector, and a loop toggle. Every control mutates
//  PlaybackState and nothing else, so the video and both overlays follow because
//  they are all functions of the same frameIndex.
//
//  Transport glyphs use SF Symbols. The hand drawn icon set in Components.swift
//  covers navigation and capture but has no play, pause, step or loop, and SF
//  Symbols are the natural, consistent choice for a media control bar. They can
//  be swapped for custom IconShapes later if the design calls for it.
//
//  House rule: no em dashes anywhere.
//

import SwiftUI
import UIKit

struct PlaybackControls: View {
    let playback: PlaybackState
    /*
      Phase positions drawn as ticks under the scrubber, so impact and the top
      are findable without scrubbing blind. Empty by default, which draws nothing.
    */
    var phaseMarks: [PhaseMark] = []

    /*
      Feedback for the scrubber.

      A selection generator rather than an impact one: stepping the play head
      through frames is a discrete pick along a track, which is exactly what
      selectionChanged is for, and it stays light enough to fire many times a
      second without the buzz turning into a rumble. Held as a property so the
      Taptic Engine is not re-armed on every frame, and prepared when a drag
      begins so the first tick is not late.
    */
    @State private var haptics = UISelectionFeedbackGenerator()

    var body: some View {
        /*
          One row for the whole transport, play first.

          The old layout stacked a 56 point circle between two spacers, which set
          the row's height on its own and pushed the metrics and the diagnostic
          report down the screen. Everything now sits on a single line reading
          left to right: play, the two frame steps beside it, then loop and speed
          pushed to the trailing edge. Same controls, one row, and the play button
          lands where a thumb already rests.
        */
        VStack(spacing: Tok.s2) {
            scrubber
            HStack(spacing: Tok.s2) {
                playButton
                stepButton(system: "backward.frame.fill") { playback.stepBackward() }
                stepButton(system: "forward.frame.fill") { playback.stepForward() }
                Spacer(minLength: Tok.s2)
                loopButton
                speedSelector
            }
        }
        .padding(.vertical, Tok.s2)
        .padding(.horizontal, Tok.s3)
    }

    // MARK: Phase ticks

    /*
      A tick per coaching position, placed at its fraction of the clip. Impact is
      rust and the top is citrus, because those are the two a golfer looks for;
      everything else is a quiet grey. The legend below names them once rather
      than labelling every tick, which would not fit.
    */
    @ViewBuilder
    private var phaseTicks: some View {
        if !phaseMarks.isEmpty, playback.frameCount > 1 {
            let last = Double(playback.frameCount - 1)
            VStack(spacing: 2) {
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        ForEach(phaseMarks) { mark in
                            let f = min(max(Double(mark.index) / last, 0), 1)
                            Rectangle()
                                .fill(tickColour(mark.label))
                                .frame(width: 2, height: tickHeight(mark.label))
                                .offset(x: f * max(0, geo.size.width - 2))
                        }
                    }
                }
                .frame(height: 7)

                HStack(spacing: Tok.s3) {
                    legendDot(colour: Tok.rust, text: "Impact")
                    legendDot(colour: Tok.citrus, text: "Top")
                    legendDot(colour: Tok.bone3, text: "Other positions")
                    Spacer()
                }
            }
        }
    }

    private func tickColour(_ label: String) -> Color {
        let l = label.lowercased()
        if l.contains("impact") || l == "p7" { return Tok.rust }
        if l.contains("top") || l == "p4" { return Tok.citrus }
        return Tok.bone3.opacity(0.75)
    }

    private func tickHeight(_ label: String) -> CGFloat {
        let l = label.lowercased()
        return (l.contains("impact") || l == "p7" || l.contains("top") || l == "p4") ? 7 : 4
    }

    private func legendDot(colour: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Rectangle().fill(colour).frame(width: 2, height: 7)
            Text(text)
                .font(.data(TypeScale.nano))
                .foregroundStyle(Tok.bone3)
        }
    }

    // MARK: Scrubber

    private var scrubber: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { Double(playback.frameIndex) },
                    set: { playback.seek(toFrame: Int($0.rounded())) }
                ),
                in: 0...Double(max(1, playback.frameCount - 1)),
                step: 1
            ) { editing in
                // Grabbing the scrubber pauses, so the play head sits where the
                // golfer puts it rather than running out from under them.
                if editing {
                    playback.pause()
                    // Warm the Taptic Engine so the first tick of the drag lands
                    // with the finger rather than a beat behind it.
                    haptics.prepare()
                }
            }
            .tint(Tok.citrus)
            /*
              One tick per frame crossed while dragging. Driven off the frame
              index rather than the gesture, so a tick fires exactly when the
              picture changes, and a scrub that moves within one frame stays
              silent. Playback moves the same index, so this is gated on the drag
              having paused it: a clip playing back does not buzz.
            */
            .onChange(of: playback.frameIndex) { _, _ in
                guard !playback.isPlaying else { return }
                haptics.selectionChanged()
            }

            phaseTicks

            HStack {
                Text(timeLabel(playback.frameIndex))
                    .font(.data(TypeScale.nano))
                    .foregroundStyle(Tok.bone2)
                Spacer()
                Text("\(playback.frameCount == 0 ? 0 : playback.frameIndex + 1) / \(playback.frameCount)")
                    .font(.data(TypeScale.nano))
                    .foregroundStyle(Tok.bone3)
            }
        }
    }

    private func timeLabel(_ index: Int) -> String {
        guard playback.frameTimes.indices.contains(index), let first = playback.frameTimes.first else {
            return "0.00s"
        }
        let seconds = (playback.frameTimes[index] - first) / 1000
        return String(format: "%.2fs", seconds)
    }

    // MARK: Buttons

    private var playButton: some View {
        Button {
            playback.togglePlay()
        } label: {
            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Tok.ink)
                // 44 is the smallest comfortable tap target, and it lets the whole
                // transport sit on one row without the circle setting its height.
                .frame(width: 44, height: 44)
                .background(
                    Circle().fill(
                        LinearGradient(
                            colors: [Tok.citrusLit, Tok.citrus, Tok.citrusDeep],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )
        }
        .buttonStyle(PressScale())
    }

    private func stepButton(system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Tok.bone)
                .frame(width: 40, height: 40)
                .glass(radius: 20)
        }
        .buttonStyle(PressScale())
    }

    private var loopButton: some View {
        Button {
            playback.toggleLoop()
        } label: {
            Image(systemName: "repeat")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(playback.loop ? Tok.citrus : Tok.bone2)
                .frame(width: 40, height: 40)
                .glass(radius: 20)
        }
        .buttonStyle(PressScale())
    }

    // MARK: Speed

    private var speedSelector: some View {
        Menu {
            ForEach(PlaybackState.speeds, id: \.self) { value in
                Button {
                    playback.setSpeed(value)
                } label: {
                    if playback.speed == value {
                        Label(speedLabel(value), systemImage: "checkmark")
                    } else {
                        Text(speedLabel(value))
                    }
                }
            }
        } label: {
            Text(speedLabel(playback.speed))
                .font(.data(TypeScale.nano))
                .foregroundStyle(Tok.bone)
                .frame(minWidth: 44)
                .padding(.vertical, 9)
                .padding(.horizontal, 10)
                .glass(radius: 999)
        }
    }

    private func speedLabel(_ value: Double) -> String {
        if value == value.rounded() {
            return "\(Int(value))x"
        }
        // 0.25 and 0.5 read better without a trailing zero.
        return "\(String(format: "%g", value))x"
    }
}

