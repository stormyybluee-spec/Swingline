//
//  ImagePreprocessing.swift
//  Swingline
//
//  Invisible contrast enhancement for the POSE DETECTOR INPUT ONLY.
//
//  WHY THIS EXISTS
//
//  MediaPipe and Vision both fail on the same three inputs: a golfer in dark
//  clothing against a dark background (no local contrast at the silhouette),
//  a backlit clip where auto exposure metered the bright background and
//  crushed the golfer to black, and a same luminance confusion (a white glove
//  against a white wall, both clipped near the top of the range). None of
//  these is a model problem. They are input problems: the edges the detector
//  needs are present in the sensor data but compressed into a luminance band
//  too narrow for the network to read. Widening that band back out, locally
//  and before detection, is the whole job of this file.
//
//  WHY CORE IMAGE, NOT vImage
//
//  Three of the four detection surfaces already run a CIContext render over
//  the pixels on their way to the detector: the ROI crop in
//  MediaPipePoseProvider.croppedImage, the downswing crop in
//  CropRefinement.refineFrame, and the Vision fallback in
//  UploadProcessor.visionDetections. Expressing the enhancement as a CIImage
//  transform lets Core Image FUSE it into those renders, so on those paths it
//  costs one extra sampler read, not one extra pass. Only the full frame
//  MediaPipe path (MPImage(sampleBuffer:)) hands the raw buffer over with no
//  render, and that is the one place enhancedBuffer(from:) adds a dedicated
//  pass. A vImage build would instead force a SECOND full sweep over pixels
//  the CIContext has already read, on the very paths that hurt most (the 4K
//  full frame and the upscaled crop). The apply pass of any local operator at
//  4K also only fits a 60 fps budget on the GPU, so Core Image is both the
//  cheaper and the only-fast-enough option here.
//
//  WHY THIS IS NOT LITERAL CLAHE, AND WHY THAT IS CORRECT
//
//  CLAHE is three ideas stacked: adaptive (per tile), histogram equalization
//  (flatten each tile's histogram), and contrast limited (clip the histogram
//  so flat regions do not amplify noise). The pose landmark network sees a
//  256x256 crop and was trained on natural sRGB images. The histogram
//  equalization step is the one part of CLAHE built for a human viewer, not a
//  CNN: it quantizes tone into bands and, in a dark noisy shirt, turns sensor
//  grain into structured banding that moves the input OFF the training
//  distribution. The parts that actually recover a silhouette for a detector
//  are the other two: adaptivity and contrast limiting. This file keeps those
//  exactly and drops the equalization. The local operator is a contrast
//  limited local contrast stretch: push each pixel's luma away from its local
//  mean by a gain, then clip that push (the CL of CLAHE) so noise in flat
//  regions cannot blow up. It is adaptive (the local mean is per pixel), it is
//  contrast limited (the clip), and it is continuous rather than banded, which
//  is what a CNN wants. A literal tiled histogram CLAHE is available as an
//  extension point (see the note at the foot of the file) but is deliberately
//  not the default: it is more cost and worse detector input for this use.
//
//  THE ONE INVARIANT THAT KEEPS PLAYBACK UNTOUCHED
//
//  Every method here is geometry preserving (tone and contrast only, no pixel
//  is moved) and never writes back into the input buffer. The full frame path
//  renders into a FRESH pooled buffer and hands only that to the detector; the
//  original sample buffer, which is what the preview layer and the overlay
//  read, is never modified. So landmark coordinates, the ROI remap math, and
//  the on screen image are all identical with the filter on or off. The filter
//  can only change the pixel intensities the detector reads, which is the
//  entire and only intent.
//
//  House rule: no em dashes anywhere.
//

import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CoreVideo
import Metal
import UIKit

// MARK: - Config

/// Every knob is here, so the layer is tuned and toggled from one place. All
/// stages are independently switchable by setting their strength to the inert
/// value (gain 1.0, gamma 1.0, shadowLift 0.0), so a single clip can be A/B
/// diffed stage by stage without touching call sites.
public struct PoseEnhancementConfig {

    /// Master switch. When false, enhanced(_:) returns the input untouched and
    /// enhancedBuffer(from:) returns nil, so callers fall straight back to the
    /// original buffer. Nothing downstream can tell the layer is compiled in.
    public var enabled: Bool = true

    // Global tone, for the backlit and blown highlight cases.

    /// Raise crushed shadows. CIHighlightShadowAdjust inputShadowAmount, 0...1,
    /// higher lifts more. This is the single highest value knob for backlit
    /// clips, where the golfer is a black shape in front of a bright sky.
    public var shadowLift: Double = 0.55

    /// Pull compressed highlights back down, 0...1, higher darkens more. Opens
    /// separation in the white glove against white wall case, where both sit
    /// clipped at the top of the range. Applied as CIHighlightShadowAdjust
    /// inputHighlightAmount = 1 - highlightPull.
    public var highlightPull: Double = 0.25

    /// Midtone gamma. CIGammaAdjust inputPower: below 1 brightens midtones,
    /// above 1 darkens. Mild by default; the shadow lift does the heavy work.
    public var gamma: Double = 0.9

    // Adaptive local contrast, the contrast limited CLAHE substitute.

    /// Local detail gain. Each pixel's luma is pushed away from its local mean
    /// by this factor. 1.0 is inert. This is the adaptive part: it acts on the
    /// difference from the neighbourhood, so a dark shirt on a dark background,
    /// which has near zero GLOBAL contrast but real LOCAL edges, gets those
    /// edges amplified while an already contrasty scene barely changes.
    public var localContrastGain: Double = 1.7

    /// The contrast limit, in luma units 0...1. The amplified local detail is
    /// clipped to plus or minus this before being added back, so a flat noisy
    /// shadow cannot have its grain multiplied into false structure. This is
    /// the CL of CLAHE and the reason the gain can be set aggressively.
    public var localContrastLimit: Double = 0.18

    /// Gaussian sigma, in pixels, defining the local neighbourhood ("tile
    /// size"). Larger means the local mean is smoother and the operator acts
    /// on coarser structure. Scaled per surface: the full frame uses this, the
    /// upscaled crops effectively see a tighter neighbourhood, which is what
    /// their sharper wrists want.
    public var localMeanSigma: Double = 12.0

    // ROI luminance normalization, optional, extreme cases only.

    /// Normalise the mean luma of the processed region toward targetLuma before
    /// the tone and contrast stages. Off by default because it needs a small
    /// GPU readback of the region average per frame, a real cost, and the
    /// shadow lift already covers ordinary backlight. Turn on for clips whose
    /// exposure is so far off that a fixed curve cannot reach it. Wired only on
    /// the crop paths, where the region being normalised is the golfer's box
    /// rather than the whole scene.
    public var roiLumaNormalization: Bool = false
    public var targetLuma: Double = 0.5

    public init() {}

    /// Upload path default: full strength, since uploads are offline and the
    /// budget is generous.
    public static var upload: PoseEnhancementConfig { PoseEnhancementConfig() }

    /// Live path default: conservative. Real time capture is usually already
    /// well exposed (the operator points a camera at a lit range), so the live
    /// preset leans on shadow lift and a gentle local gain, and leaves ROI
    /// normalization off. Kept OFF at the provider unless a caller opts in, so
    /// existing capture behaviour is byte for byte unchanged until asked.
    public static var live: PoseEnhancementConfig {
        var c = PoseEnhancementConfig()
        c.shadowLift = 0.4
        c.highlightPull = 0.15
        c.gamma = 0.95
        c.localContrastGain = 1.4
        c.localContrastLimit = 0.15
        c.localMeanSigma = 10.0
        return c
    }
}

// MARK: - Enhancer

/// Stateless with respect to frames (holds only a context, a pooled buffer and
/// a compiled kernel), so one instance is safely reused across a whole clip on
/// the sequential upload loop, or across a capture session on its queue.
/// CIContext render is thread safe; the buffer pool is only touched from the
/// same serial detect path that owns the instance.
public final class PoseImageEnhancer {

    public var config: PoseEnhancementConfig

    /// Metal backed context. cacheIntermediates off: every frame is new, so a
    /// cache only costs memory. Working colour space linear would be more
    /// correct tonally but the detector was trained on non linear sRGB frames,
    /// so matching the pipeline's existing deviceRGB renders is the right call.
    private let context: CIContext

    /// The one custom kernel: contrast limited local contrast. Compiled once at
    /// init. If compilation ever fails the local stage is skipped and the tone
    /// stages still run, so the layer degrades instead of throwing.
    private let localContrastKernel: CIColorKernel?

    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    public init(config: PoseEnhancementConfig = .upload) {
        self.config = config
        if let device = MTLCreateSystemDefaultDevice() {
            self.context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            self.context = CIContext(options: [.cacheIntermediates: false])
        }
        self.localContrastKernel = Self.makeLocalContrastKernel()
    }

    // MARK: Fusible transform (crop and Vision paths)

    /*
      Return a lazily evaluated CIImage with the enhancement applied, so the
      caller's existing render evaluates the whole chain in one pass. This is
      the entry point for every surface that already renders: the ROI crop, the
      downswing crop, and the Vision fallback. roiNormalize is honoured only
      when the passed image IS the region of interest (a crop), which is where
      normalising the mean luma toward a target is meaningful.
    */
    public func enhanced(_ input: CIImage, roiNormalize: Bool = false) -> CIImage {
        guard config.enabled else { return input }
        let extent = input.extent
        // CGRect.isFinite is package protected in the SDK and cannot be
        // called from here, so the finiteness test is spelled out on the
        // components. Null and infinite are checked first because
        // CIImage.extent returns CGRect.infinite for an unbounded
        // generator, whose origin and size are sentinel values rather than
        // merely large ones; a filter chain fed an infinite extent renders
        // nothing and would strand the detector on an empty buffer.
        guard extent.width > 1, extent.height > 1, isFiniteRect(extent) else { return input }

        var img = input

        if roiNormalize, config.roiLumaNormalization {
            img = normalizeExposure(img, extent: extent)
        }

        // Global tone: shadow lift and highlight pull in one stock filter.
        if config.shadowLift != 0 || config.highlightPull != 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = img
            f.shadowAmount = Float(clamp(config.shadowLift, -1, 1))
            f.highlightAmount = Float(clamp(1.0 - config.highlightPull, 0, 1))
            if let o = f.outputImage { img = o }
        }

        // Midtone gamma.
        if config.gamma != 1.0 {
            let f = CIFilter.gammaAdjust()
            f.inputImage = img
            f.power = Float(max(0.1, config.gamma))
            if let o = f.outputImage { img = o }
        }

        // Adaptive, contrast limited local contrast.
        if config.localContrastGain > 1.0, let kernel = localContrastKernel {
            let mean = img
                .clampedToExtent()
                .applyingGaussianBlur(sigma: max(1.0, config.localMeanSigma))
                .cropped(to: extent)
            if let o = kernel.apply(
                extent: extent,
                arguments: [img, mean,
                            Float(config.localContrastGain),
                            Float(clamp(config.localContrastLimit, 0.0, 1.0))]
            ) {
                img = o
            }
        }

        return img.cropped(to: extent)
    }

    // MARK: Dedicated render (full frame MediaPipe path)

    /*
      The one path that has no render of its own. Enhance the full frame in the
      buffer's own pixel space (no orientation applied: the caller passes the
      same orientation to MPImage, exactly as croppedImage does, so the ROI and
      remap math is unchanged) and render into a fresh pooled BGRA buffer.
      Returns nil on any failure so the caller falls back to MPImage(sampleBuffer:)
      and never loses a frame.
    */
    public func enhancedBuffer(from sample: CMSampleBuffer) -> CVPixelBuffer? {
        guard config.enabled, let src = CMSampleBufferGetImageBuffer(sample) else { return nil }
        let w = CVPixelBufferGetWidth(src)
        let h = CVPixelBufferGetHeight(src)
        guard w > 1, h > 1 else { return nil }

        let extent = CGRect(x: 0, y: 0, width: w, height: h)
        let input = CIImage(cvPixelBuffer: src)
        let out = enhanced(input, roiNormalize: false).cropped(to: extent)

        guard let buffer = dequeueBuffer(width: w, height: h) else { return nil }
        context.render(
            out, to: buffer, bounds: extent,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return buffer
    }

    // MARK: - ROI luminance normalization

    /*
      Measure the region's mean luma with a one pixel area average, then scale
      exposure to bring it toward targetLuma. The readback is a small
      synchronous render of a 1x1 image, the reason this stage is opt in. The
      gain is bounded so a nearly black region cannot be multiplied into noise.
    */
    private func normalizeExposure(_ image: CIImage, extent: CGRect) -> CIImage {
        let avg = CIFilter.areaAverage()
        avg.inputImage = image
        avg.extent = extent
        guard let out = avg.outputImage else { return image }

        var px: [UInt8] = [0, 0, 0, 0]
        context.render(
            out, toBitmap: &px, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let mean = (0.299 * Double(px[0]) + 0.587 * Double(px[1]) + 0.114 * Double(px[2])) / 255.0
        guard mean > 0.01 else { return image }

        // Exposure as a linear gain reads better than brightness (an additive
        // offset), so use exposureAdjust with EV = log2(gain). The gain is
        // bounded so a nearly black region cannot be multiplied into noise.
        let gain = clamp(config.targetLuma / mean, 0.5, 3.0)
        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = image
        exposure.ev = Float(log2(gain))
        return exposure.outputImage ?? image
    }

    // MARK: - Buffer pool

    private func dequeueBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolWidth != width || poolHeight != height {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferCGImageCompatibilityKey as String: true,
            ]
            var created: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(
                kCFAllocatorDefault, nil, attrs as CFDictionary, &created
            )
            guard status == kCVReturnSuccess, let p = created else { return nil }
            pool = p
            poolWidth = width
            poolHeight = height
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess else {
            return nil
        }
        return out
    }

    // MARK: - The kernel

    /*
      Contrast limited local contrast, on luma, preserving chroma. Two per pixel
      aligned inputs: the working image and its blurred local mean. The push is
      the luma difference from the local mean, gained and then CLIPPED to the
      limit (the contrast limiting), added back onto the local mean. Chroma is
      preserved by scaling rgb by the ratio of new to old luma rather than
      writing a grey, so the detector still sees a coloured frame on the correct
      training distribution.

      Written in the Core Image Kernel Language and compiled at runtime, so no
      .metal file and no -fcikernel build setting are needed: the layer drops
      into the project as one Swift file. For a production build the same kernel
      can be moved to a compiled CIKernel (see the foot of the file); the string
      form is used here so deployment is a single file add with zero build
      configuration.
    */
    private static func makeLocalContrastKernel() -> CIColorKernel? {
        let source = """
        kernel vec4 clLocalContrast(__sample img, __sample mean, float gain, float limit) {
            vec3 w = vec3(0.299, 0.587, 0.114);
            float y = dot(img.rgb, w);
            float m = dot(mean.rgb, w);
            float d = clamp((y - m) * gain, -limit, limit);
            float yo = clamp(m + d, 0.0, 1.0);
            float r = (y > 0.001) ? (yo / y) : 1.0;
            return vec4(clamp(img.rgb * r, 0.0, 1.0), img.a);
        }
        """
        return CIColorKernel(source: source)
    }
}

// MARK: - Small helpers

@inline(__always)
private func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T {
    min(max(v, lo), hi)
}

/*
  EXTENSION POINT: literal tiled CLAHE.

  If a future clip proves the smooth local operator above is not aggressive
  enough (a case where genuine per tile histogram flattening beats a local
  contrast stretch), the drop in is a two stage Metal pass, NOT a vImage one,
  for the 60 fps reason in the header:

    1. A reduction pass builds a per tile clipped luma histogram and its CDF
       into a small texture (for an NxN tile grid this is N*N*256 values, tiny).
       Compute the histograms on a luma plane capped to about 960 px long side;
       CDFs are low frequency, so computing them at reduced resolution and
       applying at full resolution is exact enough and keeps the reduction
       cheap.
    2. A per pixel CIColorKernel apply pass reads the four surrounding tile CDFs
       and bilinearly interpolates the mapped luma, exactly as CLAHE specifies,
       then recolours by the luma ratio as the kernel above does.

  Both stages stay on the GPU and fuse the apply pass into the same render the
  crop paths already do. The reason it is not shipped is stated in the header:
  for a 256x256 pose CNN the equalization step is a net negative, so paying for
  it by default would be slower AND worse. This note exists so the escalation
  path is known, not so it is taken lightly.
*/


// MARK: - Small helpers (round five)

/// CGRect.isFinite is package protected in the SDK, so finiteness is
/// tested on the components. Null and infinite are checked first because
/// CIImage.extent returns CGRect.infinite for an unbounded generator,
/// whose origin and size are not merely large but sentinel values.
@inline(__always)
private func isFiniteRect(_ r: CGRect) -> Bool {
    !r.isNull && !r.isInfinite
        && r.origin.x.isFinite && r.origin.y.isFinite
        && r.size.width.isFinite && r.size.height.isFinite
}
