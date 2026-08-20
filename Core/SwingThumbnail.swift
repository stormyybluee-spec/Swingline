//
//  SwingThumbnail.swift
//  Swingline
//
//  One box, one crop rule, one writer.
//
//  Before this file the thumbnail size lived in two places that disagreed: the
//  video grab asked AVAssetImageGenerator for a 640x640 cap and kept whatever
//  aspect the source happened to have, and the skeleton fallback drew 360x480.
//  A grid of cards fed by both looked ragged, and an uploaded portrait clip
//  looked nothing like an uploaded landscape one.
//
//  Every thumbnail in the app now comes through here and comes out at exactly
//  SwingThumbnail.size, 4:3, centre cropped. Never stretched, never letterboxed.
//
//  This is CoreGraphics and ImageIO only, no UIKit, so both the Core upload
//  pipeline and the App layer store can call it without either one importing
//  the other's dependencies.
//
//  House rule: no em dashes anywhere.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum SwingThumbnail {

    // The one box. 4:3, landscape. Both producers and the card layout agree on
    // this, so a grid never has to reason about a source aspect again.
    static let size = CGSize(width: 640, height: 480)

    // Width over height, for the SwiftUI side to clamp its frame with.
    static let aspect: CGFloat = 4.0 / 3.0

    // Matches the compression the skeleton fallback already used.
    static let compression: CGFloat = 0.72

    /*
      The largest centred 4:3 rectangle that fits the source, scaled to the target.

      Crop first, then scale, so nothing is distorted. A source that is already
      4:3 crops to itself. A portrait clip loses top and bottom, a wide clip
      loses left and right, which is what a centre crop means and what keeps the
      golfer in the middle of the tile.

      A source smaller than the target is upscaled to fill. That is deliberate:
      this is a tile in a grid, not a frame for analysis, and a small tile in a
      row of large ones is worse than a slightly soft one.
    */
    static func centreCropped(_ source: CGImage, to target: CGSize = size) -> CGImage? {
        let sourceW = CGFloat(source.width)
        let sourceH = CGFloat(source.height)
        guard sourceW > 0, sourceH > 0, target.width > 0, target.height > 0 else { return nil }

        let targetAspect = target.width / target.height

        // Fit the widest 4:3 rectangle inside the source.
        var cropW = sourceW
        var cropH = sourceW / targetAspect
        if cropH > sourceH {
            cropH = sourceH
            cropW = sourceH * targetAspect
        }

        // cropping(to:) works in integral pixels, so round before asking.
        let cropRect = CGRect(
            x: ((sourceW - cropW) / 2).rounded(.down),
            y: ((sourceH - cropH) / 2).rounded(.down),
            width: cropW.rounded(.down),
            height: cropH.rounded(.down)
        ).intersection(CGRect(x: 0, y: 0, width: sourceW, height: sourceH))

        guard cropRect.width >= 1, cropRect.height >= 1,
              let cropped = source.cropping(to: cropRect) else { return nil }

        guard let context = CGContext(
            data: nil,
            width: Int(target.width),
            height: Int(target.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(origin: .zero, size: target))
        return context.makeImage()
    }

    /*
      Write a JPEG to a temporary file and hand back the URL.

      The store moves the file into the swing's slot, so the caller does not own
      it for long. Nil on any failure, which lets the caller fall through to the
      skeleton fallback rather than shipping a broken tile.
    */
    static func writeJPEG(_ image: CGImage, quality: CGFloat = compression) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jpg")

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }

        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    // Crop and write in one step. The whole public path for a video frame.
    static func makeFile(from source: CGImage) -> URL? {
        guard let cropped = centreCropped(source) else { return nil }
        return writeJPEG(cropped)
    }
}
