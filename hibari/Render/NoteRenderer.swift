import CoreGraphics
import Foundation
import os

final class RenderedNote: @unchecked Sendable {
    /// `NoteLayout.serial` of the layout that was drawn.
    let serial: UInt64
    /// One per `NoteLayout.blocks` entry (nil if the block could not be drawn).
    let blockImages: [CGImage?]
    /// Custom emojis that were not available when this was drawn.
    let missingEmojis: [ImageRequest]

    init(serial: UInt64, blockImages: [CGImage?], missingEmojis: [ImageRequest]) {
        self.serial = serial
        self.blockImages = blockImages
        self.missingEmojis = missingEmojis
    }

    var cost: Int { blockImages.reduce(0) { $0 + ($1.map { $0.bytesPerRow * $0.height } ?? 0) } }
}

/// Custom emojis are drawn from what the image pipeline can produce without waiting for
/// the network. Missing ones are loaded afterwards and the note is drawn once more; the
/// new bitmaps are announced with `didRedraw` (`userInfo["note"]` is the `RenderedNote`).
final class NoteRenderer: @unchecked Sendable {
    static let didRedraw = Notification.Name("NoteRenderer.didRedraw")

    struct Stats: Sendable {
        var renders = 0
        var renderSeconds: Double = 0
    }

    static let shared = NoteRenderer(imagePipeline: .shared)

    let imagePipeline: ImagePipeline
    let stats = Locked(Stats())

    private let cache = NSCache<NSNumber, RenderedNote>()
    private let queue = OperationQueue()

    private struct Pending {
        let operation: Operation
        var completions: [@MainActor @Sendable (RenderedNote) -> Void]
    }

    private let pending = Locked<[UInt64: Pending]>([:])

    init(imagePipeline: ImagePipeline) {
        self.imagePipeline = imagePipeline
        cache.totalCostLimit = 96 * 1024 * 1024
        queue.name = "hibari.render"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
    }

    func cached(_ layout: NoteLayout) -> RenderedNote? {
        cache.object(forKey: NSNumber(value: layout.serial))
    }

    /// Renders on the calling thread (and caches).
    @discardableResult
    func renderSynchronously(_ layout: NoteLayout) -> RenderedNote {
        if let hit = cached(layout) { return hit }
        let rendered = draw(layout)
        if !rendered.missingEmojis.isEmpty {
            redrawWhenLoaded(layout, missing: rendered.missingEmojis)
        }
        return rendered
    }

    /// Renders in the background; `completion` runs on the main thread.
    func render(_ layout: NoteLayout, completion: @escaping @MainActor @Sendable (RenderedNote) -> Void) {
        enqueue(layout, priority: .high, completion: completion)
    }

    func prefetch(_ layouts: [NoteLayout]) {
        for layout in layouts where cached(layout) == nil {
            enqueue(layout, priority: .low, completion: nil)
        }
    }

    private func draw(_ layout: NoteLayout) -> RenderedNote {
        let start = CFAbsoluteTimeGetCurrent()
        let signpost = Signposts.render.beginInterval("note", id: Signposts.render.makeSignpostID())
        let context = layout.key.context
        let palette = context.palette
        var missing: [ImageRequest] = []
        let bitmaps = layout.blocks.map { block in
            Rasterizer.render(block, palette: palette, scale: context.displayScale) { request in
                if let image = imagePipeline.imageSynchronously(for: request) { return image }
                missing.append(request)
                return nil
            }
        }
        Signposts.render.endInterval("note", signpost)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        stats.withLock {
            $0.renders += 1
            $0.renderSeconds += elapsed
        }
        let rendered = RenderedNote(serial: layout.serial, blockImages: bitmaps, missingEmojis: missing)
        cache.setObject(rendered, forKey: NSNumber(value: layout.serial), cost: rendered.cost)
        return rendered
    }

    private func redrawWhenLoaded(_ layout: NoteLayout, missing: [ImageRequest]) {
        let imagePipeline = self.imagePipeline
        Task { @MainActor [weak self] in
            let countdown = Countdown(missing.count)
            for request in missing {
                imagePipeline.load(request, priority: .low) { [weak self] _ in
                    guard countdown.tick(), let self,
                          missing.contains(where: { imagePipeline.cachedImage(for: $0) != nil })
                    else { return }
                    self.enqueueRedraw(layout)
                }
            }
        }
    }

    private func enqueueRedraw(_ layout: NoteLayout) {
        let operation = BlockOperation { [weak self] in
            guard let self else { return }
            let rendered = self.draw(layout)
            Task { @MainActor in
                NotificationCenter.default.post(name: Self.didRedraw, object: self, userInfo: ["note": rendered])
            }
        }
        queue.addOperation(operation)
    }

    private func enqueue(
        _ layout: NoteLayout,
        priority: Operation.QueuePriority,
        completion: (@MainActor @Sendable (RenderedNote) -> Void)?
    ) {
        let serial = layout.serial
        let operation: Operation? = pending.withLock { pending in
            if var existing = pending[serial] {
                if let completion { existing.completions.append(completion) }
                if priority.rawValue > existing.operation.queuePriority.rawValue {
                    existing.operation.queuePriority = priority
                }
                pending[serial] = existing
                return nil
            }
            let operation = BlockOperation { [weak self] in
                guard let self else { return }
                let rendered = self.renderSynchronously(layout)
                let callbacks = self.pending.withLock { $0.removeValue(forKey: serial)?.completions ?? [] }
                guard !callbacks.isEmpty else { return }
                Task { @MainActor in
                    for callback in callbacks { callback(rendered) }
                }
            }
            operation.queuePriority = priority
            pending[serial] = Pending(operation: operation, completions: completion.map { [$0] } ?? [])
            return operation
        }
        if let operation { queue.addOperation(operation) }
    }
}

@MainActor
private final class Countdown {
    private var remaining: Int

    init(_ count: Int) {
        remaining = count
    }

    func tick() -> Bool {
        remaining -= 1
        return remaining == 0
    }
}
