//
//  OverlayExporter.swift
//  Swingline
//
//  Burn the overlays into a copy of the clip, so what gets shared is what the
//  golfer was looking at. Skeleton, hand path, club head, spine and ball flight,
//  baked into the pixels, then handed to the system share sheet.
//
//  WHY THIS IS A SEPARATE FILE AND NOT INSIDE FullscreenSwingView
//
//  Same argument VideoEditor.swift makes at the top of itself. Export is model
//  work. It reads a file, decodes frames, composites, encodes and writes a new
//  file. None of that is SwiftUI, and putting it in the view would give the view
//  ownership of AVAssetReader and AVAssetWriter lifetimes. The view passes in one
//  closure that draws an overlay for a given moment, and gets back a URL.
//
//  It is not in VideoEditor.swift either, because everything in there is a pure
//  AVFoundation transform of an existing clip. This needs a picture drawn by the
//  view layer for every single frame, which is a different kind of operation with
//  a different failure mode, and mixing them would mean VideoEditor could no
//  longer be reasoned about without knowing what the view is drawing.
//
//  HOW IT WORKS, AND WHY IT IS NOT AVVideoCompositionCoreAnimationTool
//
//  The obvious route is a CALayer tree and the Core Animation tool. It is the
//  wrong tool here. The overlays are not an animation, they are a lookup: frame
//  index in, drawing out. Expressing that as keyframed layer opacities means
//  building every frame's drawing up front and holding all of them in memory at
//  once, which on a 240fps ten second clip is thousands of full size images.
//
//  So this streams instead. Read one frame, ask the view layer to draw the
//  overlay for the moment that frame happens at, composite the two through Core
//  Image, encode, move on. Two frames of memory at any time, whatever the clip
//  length or the frame rate.
//
//  THE MAIN ACTOR DECISION, STATED SO IT IS NOT MISTAKEN FOR AN OVERSIGHT
//
//  This whole type is @MainActor. That is deliberate and it is a trade.
//
//  The overlay drawing has to happen on the main actor, because it is SwiftUI
//  going through ImageRenderer, and the state it draws from (the skeleton
//  settings object, the observable playback) is main actor isolated too. Running
//  the encode loop on a background actor would mean hopping to main and back for
//  every frame while passing CGImage across an isolation boundary, which under
//  strict concurrency needs a pile of unchecked Sendable wrappers to say nothing
//  the compiler can actually verify.
//
//  The cost of staying on main is that encoding competes with the UI. That is
//  paid for by the export being modal: there is a progress panel over the stage
//  and nothing else to interact with, and there is an explicit yield after every
//  frame so the progress bar and the cancel button stay live. If this ever needs
//  to run in the background while the golfer keeps scrubbing, the render closure
//  is the only piece that must stay here, and the loop can move off.
//
//  WHAT IT DOES NOT DO
//
//  Freehand ink is not burned in. PencilKit annotation lives on its own canvas
//  above these overlays and is not part of the drawing this exporter is handed.
//  It is a small addition later: render the drawing to an image and composite it
//  as a second layer, constant across all frames.
//
//  House rule: no em dashes anywhere.
//

import Foundation
import AVFoundation
import CoreImage
import CoreGraphics
import CoreMedia

enum OverlayExportError: LocalizedError {
    case noVideoTrack
    case readerFailed(String)
    case writerFailed(String)
    case noPixelBufferPool

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "The clip has no video track."
        case .readerFailed(let detail):
            return "Could not read the clip. \(detail)"
        case .writerFailed(let detail):
            return "Could not write the shared video. \(detail)"
        case .noPixelBufferPool:
            return "Could not prepare the video for export."
        }
    }
}

@MainActor
enum OverlayExporter {

    /*
      Burn the overlays into a copy of source and return the new file.

      renderOverlay is handed the presentation time of the frame being written
      and the output size, and returns a transparent drawing for that moment, or
      nil to leave the frame alone. It is called once per video frame, in order,
      so it can cache on frame index cheaply.

      onProgress runs from 0 to 1. The caller drives a progress bar with it and
      cancels by cancelling the surrounding Task, which is checked every frame.
    */
    static func burn(
        source: URL,
        renderOverlay: (_ seconds: Double, _ size: CGSize) -> CGImage?,
        onProgress: (Double) -> Void
    ) async throws -> URL {

        let asset = AVURLAsset(url: source)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw OverlayExportError.noVideoTrack }

        /*
          The composition is doing one job here: applying the track's preferred
          transform, so frames arrive upright. Without it a portrait clip filmed
          sideways decodes sideways, the overlay is drawn upright over it, and
          the export is the one place the mismatch would not be caught by eye
          until it had already been posted somewhere.
        */
        let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        var renderSize = composition.renderSize
        if renderSize.width < 2 || renderSize.height < 2 {
            // Some tracks report nothing usable. Fall back to the natural size
            // with the transform applied, which is the same measurement the
            // fullscreen fit box makes.
            let natural = try await videoTracks[0].load(.naturalSize)
            let transform = try await videoTracks[0].load(.preferredTransform)
            let resolved = natural.applying(transform)
            renderSize = CGSize(width: abs(resolved.width), height: abs(resolved.height))
        }
        // H.264 wants even dimensions. An odd one is rejected at writer setup,
        // which would fail the whole share for the sake of a single pixel.
        renderSize = CGSize(
            width: max(2, (renderSize.width / 2).rounded() * 2),
            height: max(2, (renderSize.height / 2).rounded() * 2)
        )
        composition.renderSize = renderSize

        let duration = try await asset.load(.duration)
        let total = max(0.05, CMTimeGetSeconds(duration))

        // MARK: Reader

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw OverlayExportError.readerFailed("the video output was refused")
        }
        reader.add(videoOutput)

        /*
          Audio rides in a second reader rather than a second output on the first
          one. One reader with two outputs has to be drained in step, or the one
          that is not being pulled stalls the one that is. Two readers means the
          video pass and the audio pass are simply two loops, in that order.
        */
        var audioReader: AVAssetReader?
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
           let second = try? AVAssetReader(asset: asset) {
            let out = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            )
            if second.canAdd(out) {
                second.add(out)
                audioReader = second
                audioOutput = out
            }
        }

        // MARK: Writer

        /*
          mp4, not mov. VideoEditor writes mov because its output goes back into
          the app. This one goes out to Instagram, WhatsApp and Messages, and mp4
          is the format none of them argue with.
        */
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("swingline-share-\(UUID().uuidString).mp4")

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let pixels = renderSize.width * renderSize.height
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(renderSize.width),
                AVVideoHeightKey: Int(renderSize.height),
                AVVideoCompressionPropertiesKey: [
                    // Roughly six bits per pixel per frame at 30fps, which keeps
                    // a thin bright trace over grass from turning to mush.
                    AVVideoAverageBitRateKey: Int(pixels * 6),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ]
        )
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw OverlayExportError.writerFailed("the video input was refused")
        }
        writer.add(videoInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(renderSize.width),
                kCVPixelBufferHeightKey as String: Int(renderSize.height),
            ]
        )

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: 2,
                    AVSampleRateKey: 44100,
                    AVEncoderBitRateKey: 128000,
                ]
            )
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard writer.startWriting() else {
            throw OverlayExportError.writerFailed(writer.error?.localizedDescription ?? "unknown error")
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw OverlayExportError.readerFailed(reader.error?.localizedDescription ?? "unknown error")
        }

        let context = CIContext()

        // MARK: Video pass

        do {
            while true {
                try Task.checkCancellation()

                guard let sample = videoOutput.copyNextSampleBuffer() else { break }
                guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }

                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                let seconds = CMTimeGetSeconds(time)

                var image = CIImage(cvPixelBuffer: sourceBuffer)
                if let drawing = renderOverlay(seconds, renderSize) {
                    var top = CIImage(cgImage: drawing)
                    /* The renderer is asked for the output size and normally
                       lands on it exactly. This absorbs a rounding pixel rather
                       than letting one shift the whole overlay. */
                    let sx = renderSize.width / max(1, top.extent.width)
                    let sy = renderSize.height / max(1, top.extent.height)
                    if abs(sx - 1) > 0.001 || abs(sy - 1) > 0.001 {
                        top = top.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                    }
                    image = top.composited(over: image)
                }
                image = image.cropped(to: CGRect(origin: .zero, size: renderSize))

                while !videoInput.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 4_000_000)
                    try Task.checkCancellation()
                }

                guard let pool = adaptor.pixelBufferPool, let destination = buffer(from: pool) else {
                    throw OverlayExportError.noPixelBufferPool
                }
                context.render(image, to: destination)
                adaptor.append(destination, withPresentationTime: time)

                onProgress(min(0.98, seconds / total))
                // Hand the runloop back, so the progress bar moves and cancel
                // stays tappable while this is on the main actor.
                await Task.yield()
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw error
        }

        videoInput.markAsFinished()

        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw OverlayExportError.readerFailed(reader.error?.localizedDescription ?? "unknown error")
        }

        // MARK: Audio pass

        /*
          Best effort. A clip whose audio will not decode still shares, silent,
          rather than failing the whole export over a track nobody asked for.
        */
        if let audioReader, let audioOutput, let audioInput, audioReader.startReading() {
            while let sample = audioOutput.copyNextSampleBuffer() {
                if Task.isCancelled { break }
                while !audioInput.isReadyForMoreMediaData {
                    try? await Task.sleep(nanoseconds: 4_000_000)
                }
                audioInput.append(sample)
            }
            audioInput.markAsFinished()
        } else {
            audioInput?.markAsFinished()
        }

        // MARK: Finish

        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw OverlayExportError.writerFailed(writer.error?.localizedDescription ?? "unknown error")
        }

        onProgress(1)
        return output
    }

    // MARK: Helpers

    private static func buffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return status == kCVReturnSuccess ? buffer : nil
    }
}
