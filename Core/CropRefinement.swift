//
//  CropRefinement.swift
//  Swingline
//
//  Vector D, the optional Phase 4 accuracy tier: a second detection pass
//  over the downswing window only, on a cropped and upscaled region, so the
//  wrists and elbows get several times the pixels they get in the full
//  frame. The downswing is where the arms move fastest, blur hardest and
//  matter most, and it is around fifteen percent of a clip, which is what
//  keeps this pass at roughly 2x cost on that slice rather than 2x on
//  everything (the reasoning that killed Vector G in triage).
//
//  THE THREE RULES THIS PASS LIVES BY
//
//  1. ITS OWN LANDMARKER, IN IMAGE MODE. Video mode is stateful with
//     strictly increasing timestamps; feeding the primary tracker a shifted,
//     cropped frame stream would corrupt its state (conflict C6). Image mode
//     treats each crop as an independent detection, which is exactly what a
//     crop-and-remap pass is.
//
//  2. ITS OWN SHORT-LIVED READER, OVER THE WINDOW ONLY. The main streaming
//     pass has already run; this re-decodes just the P4 to P8 timeRange with
//     a second AVAssetReader, the pattern UploadFrameSource proved out,
//     rather than seeking or re-reading the whole clip.
//
//  3. A MEASUREMENT CAN ONLY REPLACE A MEASUREMENT NEARBY. The crop result
//     is merged confidence-weighted, arm joints preferring the crop, and a
//     crop landmark that lands far from the cleaned full-frame track is
//     discarded rather than trusted: the most likely explanation for a big
//     disagreement is that the crop found a different person or a phantom,
//     and this pass runs after outlier rejection, so nothing downstream
//     would catch the injection.
//
//  The crop box covers shoulders, elbows, wrists and hips, not the arms
//  alone. Including the hips is what keeps the crop detection's world
//  landmarks meaningful (world space is hip-origin metric; a crop with no
//  hips in it has no origin), which is what lets the merge move norm and
//  world together instead of letting the drawn skeleton and the printed
//  numbers drift apart.
//
//  House rule: no em dashes anywhere.
//

import Foundation
import AVFoundation
import CoreMedia
import CoreImage
import UIKit
import MediaPipeTasksVision

public struct CropRefinementConfig {
    /// Upscale applied to the cropped region before detection (the brief's
    /// 2x zoom), capped by maxOutputDimension so a large crop from a 4K
    /// frame cannot balloon.
    public var zoom: Double = 2.0
    public var maxOutputDimension: Double = 1280
    /// Margin added around the joint bounding box, as a fraction of the box.
    public var margin: Double = 0.2
    /// A crop landmark below this visibility does not participate in the merge.
    public var minCropVisibility: Double = 0.5
    /// Crop landmarks further than this from the cleaned full-frame value
    /// (normalised image units / metres) are discarded as disagreements.
    public var maxNormDelta: Double = 0.08
    public var maxWorldDelta: Double = 0.15
    /// Preference multiplier for the crop pass on the merged arm joints.
    public var armWeightBoost: Double = 1.5
    /// A candidate whose remapped wrist mid sits further than this from the
    /// full-frame wrist mid is a different person, not a refinement.
    public var maxCandidateWristDistance: Double = 0.15

    public init() {}
}

final class CropRefinementPass {

    /// Elbows, wrists and hand points: the joints the crop pass exists to
    /// sharpen, and the only ones it is allowed to write.
    private static let mergedJoints: [Int] = [
        Landmarks.LEFT_ELBOW, Landmarks.RIGHT_ELBOW,
        Landmarks.LEFT_WRIST, Landmarks.RIGHT_WRIST,
        Landmarks.LEFT_PINKY, Landmarks.RIGHT_PINKY,
        Landmarks.LEFT_INDEX, Landmarks.RIGHT_INDEX,
        Landmarks.LEFT_THUMB, Landmarks.RIGHT_THUMB,
    ]

    /// The joints that define the crop box. Shoulders and hips anchor the
    /// box (and give the crop detection its world origin); elbows and wrists
    /// stretch it to wherever the arms actually are this frame.
    private static let boxJoints: [Int] = [
        Landmarks.LEFT_SHOULDER, Landmarks.RIGHT_SHOULDER,
        Landmarks.LEFT_ELBOW, Landmarks.RIGHT_ELBOW,
        Landmarks.LEFT_WRIST, Landmarks.RIGHT_WRIST,
        Landmarks.LEFT_HIP, Landmarks.RIGHT_HIP,
    ]

    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let cgOrientation: CGImagePropertyOrientation
    private let landmarker: PoseLandmarker
    private let config: CropRefinementConfig
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    // MARK: - Device gate

    /*
      The brief gates this tier at iPhone 14 Pro and newer (A16) plus the
      A17 Pro class. Device identifiers are the only honest signal available
      at runtime, so this is a maintained heuristic, not a law: iPhone 14
      Pro and Pro Max are iPhone15,2 and iPhone15,3, and every later iPhone
      major is at least their silicon. iPads from the M1 generation
      (iPad13,x) up qualify comfortably. Simulators pass so the tier is
      testable in development, and non-phone platforms (Catalyst) pass
      because they are desktops.
    */
    static func isDeviceCapable() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        let identifier = deviceModelIdentifier()
        func versions(_ prefix: String) -> (major: Int, minor: Int)? {
            guard identifier.hasPrefix(prefix) else { return nil }
            let digits = identifier.dropFirst(prefix.count).split(separator: ",")
            guard digits.count == 2,
                  let major = Int(digits[0]), let minor = Int(digits[1]) else { return nil }
            return (major, minor)
        }
        if let v = versions("iPhone") {
            return v.major > 15 || (v.major == 15 && v.minor >= 2)
        }
        if let v = versions("iPad") {
            return v.major >= 13
        }
        return true
        #endif
    }

    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    // MARK: - Construction

    /*
      Fails soft on purpose: nil when the model is not in the bundle or the
      asset has no video track, and the caller simply skips the tier. An
      optional accuracy pass must never be able to fail an upload.
    */
    init?(
        asset: AVURLAsset,
        track: AVAssetTrack?,
        cgOrientation: CGImagePropertyOrientation,
        settingsModel: String,
        config: CropRefinementConfig = CropRefinementConfig()
    ) {
        guard let track else { return nil }
        guard let landmarker = MediaPipePoseProvider.makeImageLandmarker(settingsModel: settingsModel) else {
            return nil
        }
        self.asset = asset
        self.track = track
        self.cgOrientation = cgOrientation
        self.landmarker = landmarker
        self.config = config
    }

    /// Convenience that loads the video track itself.
    convenience init?(
        asset: AVURLAsset,
        cgOrientation: CGImagePropertyOrientation,
        settingsModel: String,
        config: CropRefinementConfig = CropRefinementConfig()
    ) async {
        let track = try? await asset.loadTracks(withMediaType: .video).first
        self.init(
            asset: asset, track: track, cgOrientation: cgOrientation,
            settingsModel: settingsModel, config: config
        )
    }

    // MARK: - Entry point

    /*
      Refine the timeline over one window of the grid. windowMs is in the
      grid's clock (milliseconds from the first delivered frame);
      clipStartPtsMs is the absolute presentation timestamp that clock zero
      corresponds to, which UploadFrameSource exposes, so this pass can seek
      its own reader onto the same clock. Best effort throughout: any frame
      that cannot be refined is left exactly as the main pipeline made it.
    */
    func run(
        _ timeline: inout PoseTimeline,
        qc: inout TrackingQC,
        windowMs: ClosedRange<Double>,
        clipStartPtsMs: Double,
        progress: (Double) -> Void = { _ in }
    ) {
        guard timeline.frameCount > 4, timeline.gridHz > 0 else { return }
        let gridStepMs = 1000.0 / timeline.gridHz

        // The reader, over the window only, padded half a step each side so
        // the boundary grid frames have a decoded neighbour.
        let padMs = gridStepMs
        let startSec = max(0, (clipStartPtsMs + windowMs.lowerBound - padMs) / 1000)
        let durationSec = (windowMs.upperBound - windowMs.lowerBound + 2 * padMs) / 1000
        guard durationSec > 0 else { return }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            print("[CropRefinement] reader init failed: \(error)")
            return
        }
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return }
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: startSec, preferredTimescale: 600),
            duration: CMTime(seconds: durationSec, preferredTimescale: 600)
        )
        guard reader.startReading() else {
            print("[CropRefinement] startReading failed: \(String(describing: reader.error))")
            return
        }
        defer { reader.cancelReading() }

        var refinedGridIndices = Set<Int>()
        let windowSpan = max(windowMs.upperBound - windowMs.lowerBound, 1)

        while let sample = output.copyNextSampleBuffer() {
            autoreleasepool {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                guard pts.isValid, let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
                let relMs = pts.seconds * 1000 - clipStartPtsMs
                guard relMs >= windowMs.lowerBound - 0.5 * gridStepMs,
                      relMs <= windowMs.upperBound + 0.5 * gridStepMs else { return }

                // Nearest grid frame, once each: the reader may deliver more
                // frames than the grid holds (a 120 fps clip decimated to 60),
                // and refining the same grid frame twice buys nothing.
                let gi = nearestGridIndex(times: timeline.times, ms: relMs)
                guard abs(timeline.times[gi] - relMs) <= 0.6 * gridStepMs,
                      !refinedGridIndices.contains(gi) else { return }
                refinedGridIndices.insert(gi)

                qc.cropFramesAttempted += 1
                let merged = refineFrame(gridIndex: gi, pixelBuffer: pixelBuffer, timeline: &timeline)
                if merged > 0 {
                    qc.cropFramesRefined += 1
                    qc.cropJointSamplesMerged += merged
                }
                progress(Geometry.clamp((relMs - windowMs.lowerBound) / windowSpan, 0, 1))
            }
        }
    }

    // MARK: - One frame

    /// Returns how many joint samples were merged into the timeline.
    private func refineFrame(gridIndex i: Int, pixelBuffer: CVPixelBuffer, timeline: inout PoseTimeline) -> Int {
        // 1. The crop box, in upright normalised space, from the cleaned
        //    full-frame landmarks at this grid frame.
        guard let box = cropBox(timeline: timeline, i: i) else { return 0 }

        // 2. Orient upright, crop, upscale, render. Cropping AFTER orienting
        //    keeps the box math in the same upright space the landmarks live
        //    in; CoreImage evaluates lazily, so the orientation costs one
        //    combined render, not two.
        let upright = CIImage(cvPixelBuffer: pixelBuffer).oriented(cgOrientation)
        let e = upright.extent
        guard e.width > 8, e.height > 8 else { return 0 }

        // Normalised y runs down; CoreImage y runs up.
        let pixelRect = CGRect(
            x: e.minX + box.minX * e.width,
            y: e.minY + (1 - box.maxY) * e.height,
            width: box.width * e.width,
            height: box.height * e.height
        ).integral.intersection(e)
        guard pixelRect.width > 8, pixelRect.height > 8 else { return 0 }

        let scale = min(
            config.zoom,
            config.maxOutputDimension / max(pixelRect.width, pixelRect.height)
        )
        guard scale > 0.1 else { return 0 }

        let cropped = upright
            .cropped(to: pixelRect)
            .transformed(by: CGAffineTransform(translationX: -pixelRect.minX, y: -pixelRect.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let outW = Int(cropped.extent.width.rounded())
        let outH = Int(cropped.extent.height.rounded())
        guard outW > 8, outH > 8, let outBuffer = makePixelBuffer(width: outW, height: outH) else { return 0 }
        ciContext.render(cropped, to: outBuffer)

        // 3. Detect, image mode, on the crop.
        guard let mpImage = try? MPImage(pixelBuffer: outBuffer),
              let result = try? landmarker.detect(image: mpImage),
              !result.landmarks.isEmpty else { return 0 }

        // 4. The candidate whose remapped wrists sit on the golfer's wrists.
        guard let candidate = pickCandidate(result: result, box: box, timeline: timeline, i: i) else { return 0 }
        let cropNorm = result.landmarks[candidate]
        let cropWorld = candidate < result.worldLandmarks.count ? result.worldLandmarks[candidate] : nil

        // 5. Confidence-weighted merge, arm joints preferring the crop.
        var merged = 0
        for j in Self.mergedJoints where j < timeline.jointCount && j < cropNorm.count {
            let lm = cropNorm[j]
            let cropVis = lm.visibility?.doubleValue ?? 0
            guard cropVis >= config.minCropVisibility else { continue }

            // Remap crop-space normalised coordinates to full-frame space.
            let fx = box.minX + Double(lm.x) * box.width
            let fy = box.minY + Double(lm.y) * box.height
            guard fx.isFinite, fy.isFinite,
                  timeline.norm.x[j][i].isFinite, timeline.norm.y[j][i].isFinite else { continue }

            let dx = fx - timeline.norm.x[j][i]
            let dy = fy - timeline.norm.y[j][i]
            guard (dx * dx + dy * dy).squareRoot() <= config.maxNormDelta else { continue }

            let fullVis = timeline.norm.visibility[j][i].isFinite ? timeline.norm.visibility[j][i] : 0.5
            let wCrop = cropVis * config.armWeightBoost
            let w = wCrop / (wCrop + max(fullVis, 0.05))

            timeline.norm.x[j][i] += w * dx
            timeline.norm.y[j][i] += w * dy
            timeline.norm.visibility[j][i] = max(fullVis, cropVis)

            // World, same weight, same joint, delta-capped. The crop box
            // includes both hips, so the crop detection's hip-origin world
            // space is real; a crop that lost the hips reports them at low
            // visibility and its world deltas fail the cap.
            if let cw = cropWorld, j < cw.count,
               timeline.world.x[j][i].isFinite, timeline.world.y[j][i].isFinite {
                let wx = Double(cw[j].x), wy = Double(cw[j].y), wz = Double(cw[j].z)
                let wdx = wx - timeline.world.x[j][i]
                let wdy = wy - timeline.world.y[j][i]
                if wdx.isFinite, wdy.isFinite,
                   (wdx * wdx + wdy * wdy).squareRoot() <= config.maxWorldDelta {
                    timeline.world.x[j][i] += w * wdx
                    timeline.world.y[j][i] += w * wdy
                    if timeline.world.z[j][i].isFinite, wz.isFinite,
                       abs(wz - timeline.world.z[j][i]) <= config.maxWorldDelta {
                        timeline.world.z[j][i] += w * (wz - timeline.world.z[j][i])
                    }
                    timeline.world.visibility[j][i] = max(
                        timeline.world.visibility[j][i].isFinite ? timeline.world.visibility[j][i] : 0,
                        cropVis
                    )
                }
            }
            merged += 1
        }
        return merged
    }

    // MARK: - Helpers

    /// The crop box in upright normalised space, expanded by the margin,
    /// clamped into the frame, with a minimum size so a degenerate box (all
    /// joints in a heap) cannot produce a sliver crop.
    private func cropBox(timeline: PoseTimeline, i: Int) -> CGRect? {
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        var count = 0
        for j in Self.boxJoints where j < timeline.jointCount {
            let x = timeline.norm.x[j][i], y = timeline.norm.y[j][i]
            guard x.isFinite, y.isFinite else { continue }
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            count += 1
        }
        guard count >= 5, maxX > minX, maxY > minY else { return nil }

        let mx = (maxX - minX) * config.margin
        let my = (maxY - minY) * config.margin
        var rect = CGRect(
            x: minX - mx, y: minY - my,
            width: (maxX - minX) + 2 * mx, height: (maxY - minY) + 2 * my
        )
        // Never smaller than a fifth of the frame in either axis: below that
        // the crop stops containing enough body context to detect at all.
        if rect.width < 0.2 { rect = rect.insetBy(dx: (rect.width - 0.2) / 2, dy: 0) }
        if rect.height < 0.2 { rect = rect.insetBy(dx: 0, dy: (rect.height - 0.2) / 2) }
        rect = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard rect.width > 0.05, rect.height > 0.05 else { return nil }
        return rect
    }

    /// The candidate detection whose remapped wrist midpoint is nearest the
    /// full-frame golfer's wrist midpoint, within the acceptance radius.
    /// Somebody else standing inside the crop cannot pass this test.
    private func pickCandidate(
        result: PoseLandmarkerResult, box: CGRect, timeline: PoseTimeline, i: Int
    ) -> Int? {
        let lw = Landmarks.LEFT_WRIST, rw = Landmarks.RIGHT_WRIST
        guard timeline.norm.x[lw][i].isFinite || timeline.norm.x[rw][i].isFinite else { return nil }
        let fullX: Double
        let fullY: Double
        if timeline.norm.x[lw][i].isFinite, timeline.norm.x[rw][i].isFinite {
            fullX = (timeline.norm.x[lw][i] + timeline.norm.x[rw][i]) / 2
            fullY = (timeline.norm.y[lw][i] + timeline.norm.y[rw][i]) / 2
        } else if timeline.norm.x[lw][i].isFinite {
            fullX = timeline.norm.x[lw][i]; fullY = timeline.norm.y[lw][i]
        } else {
            fullX = timeline.norm.x[rw][i]; fullY = timeline.norm.y[rw][i]
        }

        var best: Int? = nil
        var bestDist = config.maxCandidateWristDistance
        for (k, landmarks) in result.landmarks.enumerated() {
            guard landmarks.count > rw else { continue }
            let cx = box.minX + (Double(landmarks[lw].x) + Double(landmarks[rw].x)) / 2 * box.width
            let cy = box.minY + (Double(landmarks[lw].y) + Double(landmarks[rw].y)) / 2 * box.height
            let d = ((cx - fullX) * (cx - fullX) + (cy - fullY) * (cy - fullY)).squareRoot()
            if d < bestDist {
                bestDist = d
                best = k
            }
        }
        return best
    }

    private func nearestGridIndex(times: [Double], ms: Double) -> Int {
        var lo = 0, hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < ms { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(times[lo - 1] - ms) <= abs(times[lo] - ms) { return lo - 1 }
        return lo
    }

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer
        )
        return status == kCVReturnSuccess ? buffer : nil
    }
}
