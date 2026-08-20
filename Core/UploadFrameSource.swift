//
//  UploadFrameSource.swift
//  Swingline
//
//  Sequential frame delivery for the upload pipeline.
//
//  The old upload path stepped an AVAssetImageGenerator to fixed timestamps at
//  fifteen frames a second. Seeking is the slowest possible way to read every
//  frame of a clip, and fifteen frames a second undersamples the downswing so
//  badly that no filter downstream can recover what was never captured (a
//  250 ms downswing at 15 fps is three to four frames). This replaces it with
//  the tool built for the job: AVAssetReader sequential decode, the same
//  pattern OverlayExporter already uses for burn-in, reading every frame at
//  native cadence with an effective cap of 60 fps for very high frame rate
//  slow motion clips.
//
//  DELIVERY MODEL
//
//  Pull based, deliberately. Detection is the slow half of the streaming pass,
//  and a push based stream would let the decoder race ahead and stack up pixel
//  buffers until memory gives out. Here, nothing is decoded until the caller
//  asks for the next frame, so exactly one sample buffer is in flight at a
//  time. `for try await frame in source.frames()` reads naturally and the
//  decoder can never outrun the consumer.
//
//  ORIENTATION
//
//  AVAssetReader does not apply the track's preferredTransform, so a portrait
//  phone clip decodes as sideways buffers. Rather than rotating pixels here,
//  the transform is translated once into a UIImage.Orientation and exposed, so
//  MediaPipePoseProvider can hand it to MPImage and let MediaPipe rotate
//  internally. The Vision fallback gets the CGImagePropertyOrientation
//  equivalent for the same purpose. Landmarks come back in upright normalised
//  space either way, which is the space every overlay draws in.
//
//  TIMESTAMPS
//
//  Emitted timestamps are milliseconds relative to the first video frame,
//  strictly increasing, which is exactly the contract PoseProvider documents
//  and MediaPipe's video mode enforces. Presentation timestamps from a reader
//  can arrive out of presentation order on B-frame content; any sample that
//  would step backwards is dropped rather than allowed to poison the tracker.
//
//  PHASE 2+ ADDITION: firstSamplePtsMs(), the absolute presentation
//  timestamp the relative clock starts at. The crop refinement pass runs its
//  own short-lived reader over the P4 to P8 timeRange, and a timeRange is
//  expressed in the clip's absolute clock, so it needs the offset between
//  the two clocks. One accessor, read on the reader queue so it cannot race
//  decode. Nothing else in this file changed.
//
//  House rule: no em dashes anywhere.
//

import Foundation
import AVFoundation
import CoreMedia
import UIKit
import ImageIO

final class UploadFrameSource {

    /// One delivered frame: the decoded sample buffer, its timestamp in
    /// milliseconds relative to the first frame, and how far through the clip
    /// it sits, for driving a progress bar.
    struct SourcedFrame {
        let buffer: CMSampleBuffer
        let timestampMs: Double
        let fraction: Double
    }

    let asset: AVURLAsset
    let durationSeconds: Double
    /// The track's reported nominal frame rate, before the cap.
    let nominalFps: Double
    /// How the decoded pixel data is rotated relative to upright. Pass to
    /// MPImage. .up for the common landscape-recorded case.
    let orientation: UIImage.Orientation
    /// Same rotation for CoreImage / Vision consumers (the fallback path).
    let cgOrientation: CGImagePropertyOrientation

    /// The clip's video track, exposed so the crop refinement pass can build
    /// its own reader against the same track rather than re-resolving it.
    private(set) var track: AVAssetTrack
    private let maxFps: Double
    /// Anything closer than this to the previously emitted frame is decimation
    /// fodder. Half a step of slack so 59.94 fps content is not halved by a
    /// strict 60 fps comparison.
    private let minStepMs: Double

    /// All reader access is serialised here. copyNextSampleBuffer blocks, and
    /// it must never block a cooperative-pool thread, so each pull hops onto
    /// this queue and resumes an async continuation with the result.
    private let readerQueue = DispatchQueue(label: "swingline.upload.frame-source", qos: .userInitiated)

    // Mutable state, touched only on readerQueue after init.
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var firstPtsMs: Double?
    private var lastEmittedMs: Double = -1
    private var finished = false

    /*
      Load and validate the asset. Throws UploadError so the caller's error
      surface stays exactly what the Upload screen already renders.

      maxSeconds defaults to the upload processor's limit; the source enforces
      it too so nobody can construct a source that will decode for minutes.
    */
    init(url: URL, maxFps: Double = 60, maxSeconds: Int = UploadProcessor.maxSeconds) async throws {
        self.asset = AVURLAsset(url: url)
        self.maxFps = maxFps
        self.minStepMs = 1000.0 / maxFps - 0.5

        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw UploadError.notReadable
        }
        let totalSeconds = CMTimeGetSeconds(duration)
        guard totalSeconds.isFinite, totalSeconds > 0 else { throw UploadError.notReadable }
        if Int(totalSeconds.rounded()) > maxSeconds {
            throw UploadError.tooLong(seconds: Int(totalSeconds.rounded()))
        }
        self.durationSeconds = totalSeconds

        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            throw UploadError.notReadable
        }
        self.track = videoTrack

        let fps = (try? await videoTrack.load(.nominalFrameRate)) ?? 0
        self.nominalFps = Double(fps)

        let transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
        let mapped = Self.orientation(from: transform)
        self.orientation = mapped.ui
        self.cgOrientation = mapped.cg
    }

    /// The effective delivery rate after the cap, for QC reporting. Zero when
    /// the track did not report a rate; the timeline measures the real value
    /// from delivered timestamps regardless.
    var effectiveFps: Double {
        nominalFps > 0 ? min(nominalFps, maxFps) : 0
    }

    /*
      The absolute presentation timestamp, in milliseconds, of the first
      emitted frame: the zero point of every relative timestamp this source
      delivered. Nil until at least one frame has been pulled. Hops onto the
      reader queue because firstPtsMs is reader-queue state, and this is read
      after the streaming pass, from an async context, so a continuation is
      the cheap correct bridge.
    */
    func firstSamplePtsMs() async -> Double? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Double?, Never>) in
            readerQueue.async { [self] in
                continuation.resume(returning: firstPtsMs)
            }
        }
    }

    // MARK: - Frame delivery

    /// The sequential frame stream. Iterate with `for try await`. Pull based:
    /// each `next()` decodes exactly as far as the next emitted frame.
    func frames() -> Frames {
        Frames(source: self)
    }

    struct Frames: AsyncSequence {
        typealias Element = SourcedFrame
        let source: UploadFrameSource

        struct AsyncIterator: AsyncIteratorProtocol {
            let source: UploadFrameSource
            mutating func next() async throws -> SourcedFrame? {
                try Task.checkCancellation()
                return try await source.pullNextFrame()
            }
        }

        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(source: source)
        }
    }

    private func pullNextFrame() async throws -> SourcedFrame? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SourcedFrame?, Error>) in
            readerQueue.async { [self] in
                do {
                    continuation.resume(returning: try nextFrameOnQueue())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Runs on readerQueue only. Decodes forward until a frame worth emitting
    /// appears, then returns it; nil at end of clip.
    private func nextFrameOnQueue() throws -> SourcedFrame? {
        if finished { return nil }
        if reader == nil { try startReadingOnQueue() }
        guard let reader, let output else { return nil }

        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard pts.isValid, CMSampleBufferGetImageBuffer(sample) != nil else { continue }

            let absMs = pts.seconds * 1000
            if firstPtsMs == nil { firstPtsMs = absMs }
            let relMs = absMs - (firstPtsMs ?? absMs)

            // Timestamps must strictly increase for the tracker. A sample that
            // would step backwards (B-frame reordering) is dropped.
            guard relMs > lastEmittedMs else { continue }
            // Decimation: cap the effective rate at maxFps for 120/240 fps
            // slow motion clips. Native-or-slower content passes untouched.
            if lastEmittedMs >= 0, relMs - lastEmittedMs < minStepMs { continue }

            lastEmittedMs = relMs
            let fraction = durationSeconds > 0.001 ? min(1, pts.seconds / durationSeconds) : 0
            return SourcedFrame(buffer: sample, timestampMs: relMs, fraction: fraction)
        }

        finished = true
        if reader.status == .failed {
            throw reader.error ?? UploadError.notReadable
        }
        return nil
    }

    /// Runs on readerQueue only.
    private func startReadingOnQueue() throws {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw UploadError.notReadable
        }

        // BGRA: the one format both MPImage and CoreImage take without a
        // conversion step, so MediaPipe and the Vision fallback share a source.
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        // The buffer is consumed before the next pull, so no defensive copy.
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else { throw UploadError.notReadable }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? UploadError.notReadable
        }
        self.reader = reader
        self.output = output
    }

    /// Stop decoding early. Safe to call from anywhere, more than once.
    func cancel() {
        readerQueue.async { [self] in
            finished = true
            reader?.cancelReading()
        }
    }

    // MARK: - Orientation mapping

    /*
      preferredTransform to orientation, the standard AVFoundation mapping.
      atan2(b, a) recovers the rotation the transform encodes:
          0 degrees      landscape as recorded, .up
          90 degrees     portrait, home button down, .right
          minus 90       portrait upside down grip, .left
          180 degrees    landscape the other way, .down
      Worth a one-time check against a portrait clip on device: if a portrait
      upload tracks as if the golfer were lying down, .right and .left are
      swapped for your SDK version, and this function is the single point to
      flip them.
    */
    private static func orientation(from t: CGAffineTransform)
        -> (ui: UIImage.Orientation, cg: CGImagePropertyOrientation)
    {
        let degrees = (atan2(t.b, t.a) * 180 / .pi).rounded()
        switch degrees {
        case 90: return (.right, .right)
        case -90, 270: return (.left, .left)
        case 180, -180: return (.down, .down)
        default: return (.up, .up)
        }
    }
}
