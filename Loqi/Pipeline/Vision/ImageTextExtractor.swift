import Vision

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// On-device OCR for attached photos (slides, whiteboards, documents) via
/// the Vision framework — no model download, no MLX contention. CJK-first:
/// language detection on, with the app's languages seeded for accuracy.
enum ImageTextExtractor {
    /// Long edge of stored attachment JPEGs. OCR runs on the original
    /// image before downscaling.
    static let storedMaxDimension: CGFloat = 2048

    /// Recognized text lines top-to-bottom, or nil when the image has no
    /// legible text.
    static func recognizeText(in image: UIImage) async -> String? {
        guard let cgImage = image.cgImage else { return nil }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = [
            Locale.Language(identifier: "zh-Hans"),
            Locale.Language(identifier: "zh-Hant"),
            Locale.Language(identifier: "ja"),
            Locale.Language(identifier: "ko"),
            Locale.Language(identifier: "en"),
        ]
        request.usesLanguageCorrection = true
        guard let observations = try? await request.perform(
            on: cgImage, orientation: orientation(of: image)) else { return nil }
        let lines = observations.compactMap {
            $0.topCandidates(1).first?.string
                .trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// JPEG for storage: long edge capped so a session full of photos
    /// stays a few MB.
    static func jpegData(for image: UIImage) -> Data? {
        let size = image.size
        let longEdge = max(size.width, size.height)
        guard longEdge > storedMaxDimension else {
            return image.jpegData(compressionQuality: 0.8)
        }
        let scale = storedMaxDimension / longEdge
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        #if os(iOS)
        let renderer = UIGraphicsImageRenderer(
            size: target, format: UIGraphicsImageRendererFormat.default())
        let scaled = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return scaled.jpegData(compressionQuality: 0.8)
        #else
        // CoreGraphics, not NSImage.lockFocus(): the encode runs off the
        // main actor (attachImage moved it there), and AppKit's focus-lock
        // drawing is main-thread-only.
        guard let cgImage = image.cgImage(
            forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(
                data: nil,
                width: Int(target.width), height: Int(target.height),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(origin: .zero, size: target))
        guard let scaledCG = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: scaledCG)
        return rep.representation(
            using: .jpeg, properties: [.compressionFactor: 0.8])
        #endif
    }

    private static func orientation(of image: UIImage) -> CGImagePropertyOrientation {
        #if os(iOS)
        switch image.imageOrientation {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
        #else
        .up
        #endif
    }
}
