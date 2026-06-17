import SwiftUI

#if os(iOS)
import UIKit

typealias PlatformImage = UIImage

extension Color {
    static var loqiSecondarySystemBackground: Color {
        Color(.secondarySystemBackground)
    }

    static var loqiTertiarySystemFill: Color {
        Color(.tertiarySystemFill)
    }
}
#elseif os(macOS)
import AppKit

typealias PlatformImage = NSImage
typealias UIImage = NSImage

extension Image {
    init(uiImage image: NSImage) {
        self.init(nsImage: image)
    }
}

extension NSImage {
    var cgImage: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    func preparingForDisplay() -> NSImage? {
        self
    }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let cgImage else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: compressionQuality])
    }
}

extension Color {
    static var loqiSecondarySystemBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static var loqiTertiarySystemFill: Color {
        Color(nsColor: .quaternaryLabelColor)
    }
}
#endif
