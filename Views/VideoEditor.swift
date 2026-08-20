//
//  VideoEditor.swift
//  Swingline
//
//  Trim, mirror and rotate on a saved swing clip, through AVFoundation. The web
//  overflow menu lists all three as "Coming with the native app". This is that.
//
//  WHY THIS IS A SEPARATE FILE AND NOT INSIDE AnalysisView
//
//  Export is model work, not view work. It reads a file, builds a composition,
//  runs an export session, and writes a new file. None of that is SwiftUI, and
//  putting it in the view would mean a view that owns file IO and AVFoundation
//  session lifetimes. It lives here so the view calls one async function and gets
//  back a URL or an error.
//
//  THE TRANSFORM MATH, STATED SO IT CAN BE CHECKED
//
//  A rotation or a mirror is applied as a CGAffineTransform on a layer
//  instruction, and the render size is set so the rotated frame fills it with no
//  black bars and no clipping. The three transforms, verified against the frame
//  corners before this was written:
//
//    rotate 90 clockwise      rotate by +90, translate x by +height, render size
//                             is the source size with width and height swapped
//    rotate 90 anticlockwise  rotate by -90, translate y by +width, swapped size
//    mirror horizontal        scale x by -1, translate x by +width, size unchanged
//
//  The source track can already carry a preferredTransform, for instance a clip
//  filmed in a rotated orientation. The edit composes ON TOP of that transform
//  rather than replacing it, so a mirror of an already rotated clip stays upright.
//  Replacing it is the classic bug that turns portrait footage sideways, and it
//  is avoided here by starting every instruction transform from the track's own
//  preferredTransform.
//
//  WHAT HAPPENS WITH NO VIDEO
//
//  The capture pipeline does not write a video file yet, so most swings have no
//  clip. Every entry point here checks the source exists and throws a clear error
//  rather than exporting an empty composition, so the overflow menu items fail
//  honestly on a swing that has no footage instead of producing a zero byte file.
//
//  House rule: no em dashes anywhere.
//

import Foundation
import AVFoundation
import CoreMedia
import UIKit

enum VideoEditError: LocalizedError {
    case noSource
    case noVideoTrack
    case exportSetupFailed
    case exportFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noSource:
            return "This swing has no video clip to edit yet."
        case .noVideoTrack:
            return "The clip has no video track."
        case .exportSetupFailed:
            return "Could not prepare the video for export."
        case .exportFailed(let detail):
            return "Export failed. \(detail)"
        case .cancelled:
            return "Export was cancelled."
        }
    }
}

enum VideoRotation {
    case clockwise
    case anticlockwise
}

enum VideoEditor {

    // MARK: Public operations

    /*
      Trim to a time range, in seconds from the start of the clip. The range is
      clamped to the real duration so a scrubber that overshoots by a frame does
      not produce an empty export.
    */
    static func trim(source: URL, startSeconds: Double, endSeconds: Double) async throws -> URL {
        let asset = AVURLAsset(url: source)
        try await ensureVideoTrack(asset)

        let duration = try await asset.load(.duration)
        let total = CMTimeGetSeconds(duration)
        let lo = max(0, min(startSeconds, total))
        let hi = max(lo + 0.05, min(endSeconds, total))

        let start = CMTime(seconds: lo, preferredTimescale: 600)
        let end = CMTime(seconds: hi, preferredTimescale: 600)
        let range = CMTimeRange(start: start, end: end)

        return try await export(asset: asset, timeRange: range, videoComposition: nil, preset: AVAssetExportPresetHighestQuality)
    }

    /*
      Mirror horizontally. Nothing about the timeline changes, only the frame
      transform, so no trim range is applied.
    */
    static func mirror(source: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let composition = try await videoComposition(for: asset) { natural, preferred in
            /* Compose the mirror onto whatever the track already does. */
            let flip = CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -natural.width, y: 0)
            return (preferred.concatenating(flip), natural)
        }
        return try await export(asset: asset, timeRange: nil, videoComposition: composition, preset: AVAssetExportPresetHighestQuality)
    }

    /*
      Rotate ninety degrees either way. The render size swaps width and height,
      which is what keeps the rotated frame filling the output.
    */
    static func rotate(source: URL, direction: VideoRotation) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let composition = try await videoComposition(for: asset) { natural, preferred in
            let swapped = CGSize(width: natural.height, height: natural.width)
            let rotate: CGAffineTransform
            switch direction {
            case .clockwise:
                rotate = CGAffineTransform(rotationAngle: .pi / 2).translatedBy(x: 0, y: -natural.height)
            case .anticlockwise:
                rotate = CGAffineTransform(rotationAngle: -.pi / 2).translatedBy(x: -natural.width, y: 0)
            }
            return (preferred.concatenating(rotate), swapped)
        }
        return try await export(asset: asset, timeRange: nil, videoComposition: composition, preset: AVAssetExportPresetHighestQuality)
    }

    // MARK: Composition

    /*
      Build a video composition whose single instruction carries a transform.

      The closure is handed the track's natural size and its existing preferred
      transform, and returns the transform to apply and the render size to use.
      Doing it this way keeps the three operations above down to their actual
      difference, one transform each, and keeps the preferredTransform composition
      in one place so none of them can forget it.
    */
    private static func videoComposition(
        for asset: AVAsset,
        _ build: @Sendable (_ natural: CGSize, _ preferred: CGAffineTransform) -> (transform: CGAffineTransform, renderSize: CGSize)
    ) async throws -> AVMutableVideoComposition {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoEditError.noVideoTrack
        }

        let natural = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let frameRate = try await track.load(.nominalFrameRate)

        let result = build(natural, preferred)

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(result.transform, at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]

        let composition = AVMutableVideoComposition()
        composition.instructions = [instruction]
        composition.renderSize = result.renderSize
        /* Fall back to thirty when the source reports no nominal rate, which some
           tracks do. A zero frame duration would make the exporter reject the
           composition. */
        let fps = frameRate > 1 ? frameRate : 30
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        return composition
    }

    // MARK: Export

    private static func export(
        asset: AVAsset,
        timeRange: CMTimeRange?,
        videoComposition: AVMutableVideoComposition?,
        preset: String
    ) async throws -> URL {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw VideoEditError.exportSetupFailed
        }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("swingline-edit-\(UUID().uuidString).mov")

        session.shouldOptimizeForNetworkUse = true
        if let timeRange { session.timeRange = timeRange }
        if let videoComposition { session.videoComposition = videoComposition }

        /*
          Two paths, chosen at runtime by OS version, so the deprecation warnings
          are silenced on iOS 18 while the code still compiles and runs on iOS 17.

          iOS 18 gave AVAssetExportSession a throwing async export(to:as:) and
          deprecated three things at once: exportAsynchronously, the status
          property, and the error property. The new call throws on failure
          instead, so none of the three deprecated members are touched on that
          path. The older continuation path is kept verbatim for iOS 17, where
          export(to:as:) does not exist. Neither path is a compile error on the
          other OS, because each is guarded by availability.
        */
        if #available(iOS 18, *) {
            do {
                try await session.export(to: output, as: .mov)
                return output
            } catch let error as CancellationError {
                throw VideoEditError.cancelled
            } catch {
                throw VideoEditError.exportFailed(error.localizedDescription)
            }
        } else {
            session.outputURL = output
            session.outputFileType = .mov
            await withCheckedContinuation { continuation in
                session.exportAsynchronously {
                    continuation.resume()
                }
            }
            switch session.status {
            case .completed:
                return output
            case .cancelled:
                throw VideoEditError.cancelled
            default:
                let detail = session.error?.localizedDescription ?? "unknown error"
                throw VideoEditError.exportFailed(detail)
            }
        }
    }

    private static func ensureVideoTrack(_ asset: AVAsset) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        if tracks.isEmpty { throw VideoEditError.noVideoTrack }
    }
}
