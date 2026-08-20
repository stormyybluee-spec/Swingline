//
//  VideoPlayerView.swift
//  Swingline
//
//  The video surface the overlays sit on. It wraps an AVPlayer when a swing has
//  a recorded clip, and shows a plain backdrop when it does not.
//
//  A note on the clock. PlaybackState owns the one clock in the playback stack,
//  and everything here is a lookup against its frameIndex, never a second clock.
//  When a video exists this view seeks the player to the timestamp of the
//  current frame, so the picture always agrees with the skeleton and the traces
//  drawn on top of it. That is deliberately the same discipline the web build
//  arrived at: one clock, everything else a function of frame index.
//
//  Why there is usually no video today. The capture pipeline produces pose
//  frames but does not yet write a video file (that is AVAssetWriter, a later
//  step). So videoURL is nil for now and the backdrop is what renders. The
//  player path is written and correct for the moment a real clip is passed in,
//  which is a one line change at the call site.
//
//  One alignment note for when video does land. Pose landmarks are normalised
//  to the original frame, so the overlays map [0,1] onto this view's bounds. For
//  them to line up with the picture, the player must be shown at the frame's
//  aspect ratio with aspect fit rather than fill, or the crop and the overlay
//  will disagree. The host sizes the panel to the clip's aspect for that reason.
//
//  House rule: no em dashes anywhere.
//

import SwiftUI
import AVFoundation
import CoreMedia

struct VideoPlayerView: View {
    let videoURL: URL?
    let playback: PlaybackState

    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if let player {
                PlayerSurface(player: player)
                    .onChange(of: playback.frameIndex) { _, index in
                        seek(player, to: index)
                    }
            } else {
                backdrop
            }
        }
        .onAppear(perform: setupPlayer)
    }

    private var backdrop: some View {
        ZStack {
            Tok.turf900
            VStack(spacing: Tok.s3) {
                Image(systemName: "figure.golf")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Tok.bone3)
                Text("No video for this swing")
                    .font(.body(TypeScale.nano))
                    .foregroundStyle(Tok.bone3)
            }
        }
    }

    private func setupPlayer() {
        guard
            let videoURL,
            FileManager.default.fileExists(atPath: videoURL.path)
        else { return }
        let avPlayer = AVPlayer(url: videoURL)
        avPlayer.isMuted = true
        // The frame clock drives the picture, so the player itself never plays
        // on its own. It is seeked to match frameIndex.
        avPlayer.actionAtItemEnd = .pause
        player = avPlayer
        seek(avPlayer, to: playback.frameIndex)
    }

    private func seek(_ player: AVPlayer, to index: Int) {
        let times = playback.frameTimes
        guard times.indices.contains(index) else { return }
        let seconds = (times[index] - (times.first ?? 0)) / 1000
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }
}

// The AVPlayerLayer host. A thin UIViewRepresentable so the video fills the
// panel behind the overlays.
private struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        uiView.playerLayer.player = player
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
