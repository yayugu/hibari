import Foundation
import ImageIO

enum MediaSize: Equatable, Sendable {
    /// Pixel size, EXIF orientation applied.
    case known(CGSize)
    /// It cannot be loaded (deleted, not federated, broken).
    case unavailable
    /// Not loaded yet.
    case unknown
}

protocol MediaSizeProvider: Sendable {
    /// Used by layout for custom emoji widths; must not block on the network.
    func mediaSize(for url: String) -> MediaSize
}

/// Only `prepare` may wait for the network. The synchronous methods answer from what is
/// local, so the layout and rendering threads that call them never stall on I/O.
protocol MediaSource: MediaSizeProvider {
    /// An ImageIO source for the raw bytes, or nil if the media is not local.
    func imageSource(for url: String) -> CGImageSource?

    /// Makes the media local (downloads it), so the other methods can answer. Returns
    /// false if it is unavailable.
    func prepare(_ url: String) async -> Bool

    /// The raw file, if it is local (sharing the original, playing animated images).
    func localFile(for url: String) -> URL?
}

extension MediaSource {
    func localFile(for url: String) -> URL? { nil }
}

enum ImageMetadata {
    /// Reads only the header.
    static func pixelSize(of source: CGImageSource) -> CGSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat, w > 0, h > 0
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }
}
