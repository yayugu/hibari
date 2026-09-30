import CoreGraphics
import CoreText
import Foundation

struct TimeLabelRequest: Hashable, Sendable {
    let text: String
    let fontSize: CGFloat
    let color: ColorRole
    let style: ThemeStyle
    let height: CGFloat
    let baseline: CGFloat
    let scale: CGFloat
}

enum TimeLabelRenderer {
    private static let cache = Locked<[TimeLabelRequest: ImageBox]>([:])
    private static let cacheLimit = 2000
    private static let queue = DispatchQueue(label: "hibari.timelabel", qos: .userInitiated)

    /// Cheap enough for the main thread.
    static func cachedImage(for request: TimeLabelRequest) -> CGImage? {
        cache.withLock { $0[request] }?.image
    }

    /// Draws in the background and calls back on the main thread.
    static func load(_ request: TimeLabelRequest, completion: @escaping @MainActor @Sendable (CGImage?) -> Void) {
        queue.async {
            let image = image(for: request).map(ImageBox.init)
            Task { @MainActor in completion(image?.image) }
        }
    }

    static func prefetch(_ requests: [TimeLabelRequest]) {
        guard !requests.isEmpty else { return }
        queue.async {
            for request in requests { _ = image(for: request) }
        }
    }

    /// Draws (and caches) on the calling thread. Keep off the main thread.
    static func image(for request: TimeLabelRequest) -> CGImage? {
        if let hit = cachedImage(for: request) { return hit }
        guard let image = draw(request) else { return nil }
        cache.withLock { cache in
            if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[request] = ImageBox(image)
        }
        return image
    }

    private static func draw(_ request: TimeLabelRequest) -> CGImage? {
        let string = NSAttributedString(string: request.text, attributes: [
            TextAttribute.font: TimeSlot.font(size: request.fontSize),
            TextAttribute.foregroundColor: Palette.palette(for: request.style)[request.color],
            TextAttribute.language: "ja",
        ])
        let line = CTLineCreateWithAttributedString(string)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let pixelWidth = Int((width * request.scale).rounded(.up))
        let pixelHeight = Int((request.height * request.scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0,
              let context = Bitmap.makeContext(width: pixelWidth, height: pixelHeight, opaque: false)
        else { return nil }
        context.scaleBy(x: request.scale, y: request.scale)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: 0, y: request.height - request.baseline)
        CTLineDraw(line, context)
        return context.makeImage()
    }
}
