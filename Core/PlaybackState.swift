//
//  PlaybackState.swift
//  Swingline
//
//  The playback clock, and the single source of truth every overlay reads from.
//
//  The web build learned this the hard way, and the lesson is carried here.
//  Overlays must not run their own animation clocks. Every visual is a pure
//  function of one integer:
//
//      frameIndex  ->  lookup  ->  what you see
//
//  When everything obeys that, scrubbing forwards, scrubbing backwards,
//  pausing, single stepping, slow motion, and keeping the skeleton and traces
//  locked together all fall out of the architecture for free. Built any other
//  way, each has to be written separately and each can break separately, which
//  is what happened to the web app before trackingLayers.js was written.
//
//  So there is exactly one clock, and it lives here. It advances frameIndex over
//  real time when playing, honouring speed and loop, by walking the play head
//  along the stored frame timestamps. Nothing else animates. VideoPlayerView,
//  the skeleton and the traces are all lookups against frameIndex.
//
//  There is no recorded video yet in this build, so this clock is what actually
//  drives playback. When video capture lands, the same frameIndex can either
//  keep driving a seek, or be driven by the player's own time observer. Either
//  way the overlays do not change, because they only ever read frameIndex.
//
//  House rule: no em dashes anywhere.
//

import Foundation

@MainActor
@Observable
final class PlaybackState {

    var frameIndex: Int = 0
    var isPlaying: Bool = false
    var speed: Double = 1.0
    var loop: Bool = false

    // Timestamps of the stored frames, in milliseconds, ascending. The clock
    // this whole thing derives from.
    private(set) var frameTimes: [Double] = []

    var frameCount: Int { frameTimes.count }
    var durationMs: Double { (frameTimes.last ?? 0) - (frameTimes.first ?? 0) }
    var progress: Double {
        guard frameCount > 1 else { return 0 }
        return Double(frameIndex) / Double(frameCount - 1)
    }

    // The selectable playback rates, in the order the control shows them.
    static let speeds: [Double] = [0.25, 0.5, 1, 2]

    // The play head in milliseconds on the frame clock. frameIndex is derived
    // from this, never the other way around, so slow motion stays smooth
    // between frames instead of quantising to frame boundaries.
    private var playHeadMs: Double = 0
    private var clock: Task<Void, Never>?

    // Load a swing's frame timestamps and reset to the first frame. Called when
    // the analysis screen opens a swing.
    func load(frameTimes times: [Double]) {
        stopClock()
        frameTimes = times
        isPlaying = false
        frameIndex = 0
        playHeadMs = times.first ?? 0
    }

    // MARK: Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard frameCount > 1 else { return }
        // Pressing play at the very end, with loop off, rewinds to the start
        // rather than sitting still.
        if !loop && frameIndex >= frameCount - 1 {
            frameIndex = 0
            playHeadMs = frameTimes.first ?? 0
        }
        isPlaying = true
        startClock()
    }

    func pause() {
        isPlaying = false
        stopClock()
    }

    func stepForward() {
        pause()
        seek(toFrame: frameIndex + 1)
    }

    func stepBackward() {
        pause()
        seek(toFrame: frameIndex - 1)
    }

    func setSpeed(_ value: Double) {
        speed = value
    }

    func toggleLoop() {
        loop.toggle()
    }

    // Jump to an exact frame. Scrubbing, stepping and tapping the timeline all
    // route through here so the play head and the index never disagree.
    func seek(toFrame index: Int) {
        guard frameCount > 0 else {
            frameIndex = 0
            return
        }
        let clamped = min(max(index, 0), frameCount - 1)
        frameIndex = clamped
        playHeadMs = frameTimes[clamped]
    }

    // Jump to a fraction of the way through, for the scrubber bar.
    func seek(toFraction fraction: Double) {
        guard frameCount > 1 else { return }
        let clamped = min(max(fraction, 0), 1)
        seek(toFrame: Int((Double(frameCount - 1) * clamped).rounded()))
    }

    // MARK: Clock

    private func startClock() {
        stopClock()
        guard frameCount > 1 else { return }
        clock = Task { @MainActor [weak self] in
            guard let self else { return }
            var last = Date()
            while !Task.isCancelled && self.isPlaying {
                try? await Task.sleep(nanoseconds: 16_000_000)  // roughly 60 ticks a second
                if Task.isCancelled || !self.isPlaying { break }
                let now = Date()
                let dtMs = now.timeIntervalSince(last) * 1000
                last = now
                self.advance(byMs: dtMs * self.speed)
            }
        }
    }

    private func stopClock() {
        clock?.cancel()
        clock = nil
    }

    private func advance(byMs delta: Double) {
        guard frameCount > 1 else { return }
        let startT = frameTimes.first ?? 0
        let endT = frameTimes.last ?? 0
        let span = max(1, endT - startT)

        playHeadMs += delta
        if playHeadMs >= endT {
            if loop {
                // Keep the overshoot so slow motion does not stutter at the wrap.
                playHeadMs = startT + (playHeadMs - endT).truncatingRemainder(dividingBy: span)
            } else {
                playHeadMs = endT
                frameIndex = frameCount - 1
                pause()
                return
            }
        }
        frameIndex = indexAt(ms: playHeadMs)
    }

    // The last frame whose timestamp is at or before a given millisecond. Binary
    // search, since frameTimes is ascending and this runs every tick.
    private func indexAt(ms: Double) -> Int {
        guard !frameTimes.isEmpty else { return 0 }
        if ms <= frameTimes[0] { return 0 }
        if ms >= frameTimes[frameCount - 1] { return frameCount - 1 }
        var lo = 0
        var hi = frameCount - 1
        var answer = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if frameTimes[mid] <= ms {
                answer = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return answer
    }
}
