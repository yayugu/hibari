import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

struct ImageRequest: Hashable, Sendable {
    enum Mode: UInt8, Hashable, Sendable {
        /// Crop to fill the box (media, avatars).
        case aspectFill
        /// Fit inside the box (custom emojis).
        case aspectFit
        /// Fit inside the box, at the fitted size: the result keeps the image's own aspect
        /// ratio and tells it (the emoji picker, which learns emoji widths as they load).
        case fitted
    }

    enum Shape: UInt8, Hashable, Sendable {
        case rect
        case circle
    }

    let url: String
    let pixelWidth: Int
    let pixelHeight: Int
    let mode: Mode
    let shape: Shape

    init(url: String, size: CGSize, scale: CGFloat, mode: Mode = .aspectFill, shape: Shape = .rect) {
        self.url = url
        pixelWidth = max(1, Int((size.width * scale).rounded()))
        pixelHeight = max(1, Int((size.height * scale).rounded()))
        self.mode = mode
        self.shape = shape
    }

    var cacheKey: String { "\(url)#\(pixelWidth)x\(pixelHeight)#\(mode.rawValue)\(shape.rawValue)" }

    var isEmoji: Bool { mode != .aspectFill }
}

/// Handle for a pending `load`. Cancelling detaches the callback and, when nobody else
/// waits for the image, moves it behind visible work. It still finishes and is cached,
/// since it is likely to be needed again soon.
final class ImageTask: Sendable {
    fileprivate let key: String
    fileprivate let id: UInt64
    fileprivate weak let pipeline: ImagePipeline?

    fileprivate init(key: String, id: UInt64, pipeline: ImagePipeline) {
        self.key = key
        self.id = id
        self.pipeline = pipeline
    }

    func cancel() {
        pipeline?.detach(key: key, id: id)
    }
}

final class ImagePipeline: MediaSizeProvider, @unchecked Sendable {
    static let mediaSizesDidChange = Notification.Name("ImagePipeline.mediaSizesDidChange")

    struct Stats: Sendable {
        var memoryHits = 0
        var diskHits = 0
        var sourceDecodes = 0
        var failures = 0
        var processingSeconds: Double = 0
    }

    #if PERF
    static let shared = ImagePipeline(source: FixtureStore.shared.map { FixtureMediaSource(store: $0) } ?? EmptyMediaSource())
    #else
    static let shared = ImagePipeline(source: NetworkMediaSource.shared, emojiSource: NetworkMediaSource.emojis)
    #endif

    let source: any MediaSource
    let emojiSource: any MediaSource
    let stats = Locked(Stats())

    private let memory = NSCache<NSString, ImageBox>()
    private let disk: ProcessedImageDiskCache
    private let queue = OperationQueue()

    private struct Waiter {
        let id: UInt64
        let completion: @MainActor @Sendable (CGImage?) -> Void
    }

    private struct Pending {
        var operation: Operation
        var waiters: [Waiter]
    }

    private let pending = Locked<[String: Pending]>([:])
    private let nextID = Locked<UInt64>(0)

    private struct Sizes {
        var missed: Set<String> = []
        var learned: [String: MediaSize] = [:]
    }

    private let sizes = Locked(Sizes())

    /// `emojiSource`: `source` if nil.
    init(source: any MediaSource, emojiSource: (any MediaSource)? = nil, diskDirectory: URL? = nil) {
        self.source = source
        self.emojiSource = emojiSource ?? source
        disk = ProcessedImageDiskCache(directory: diskDirectory)
        memory.totalCostLimit = 160 * 1024 * 1024
        queue.name = "hibari.image"
        queue.maxConcurrentOperationCount = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount - 2))
        queue.qualityOfService = .userInitiated
    }

    /// Memory cache only; cheap enough for the main thread.
    func cachedImage(for request: ImageRequest) -> CGImage? {
        memory.object(forKey: request.cacheKey as NSString)?.image
    }

    /// Processes on the calling thread if needed. For background callers (text rasterizer).
    func imageSynchronously(for request: ImageRequest) -> CGImage? {
        if let hit = cachedImage(for: request) {
            stats.withLock { $0.memoryHits += 1 }
            return hit
        }
        return produce(request)
    }

    /// Loads asynchronously and calls back on the main thread (with nil if the image cannot
    /// be produced). Always asynchronous; check `cachedImage` first to skip a round trip.
    @discardableResult
    func load(
        _ request: ImageRequest,
        priority: Operation.QueuePriority = .high,
        completion: @escaping @MainActor @Sendable (CGImage?) -> Void
    ) -> ImageTask {
        let key = request.cacheKey
        let id = nextID.withLock { $0 += 1; return $0 }
        enqueue(request, priority: priority, waiter: Waiter(id: id, completion: completion))
        return ImageTask(key: key, id: id, pipeline: self)
    }

    func prefetch(_ requests: [ImageRequest]) {
        for request in requests where cachedImage(for: request) == nil {
            enqueue(request, priority: .low, waiter: nil)
        }
    }

    func removeAllCaches() {
        memory.removeAllObjects()
        disk.removeAll()
    }

    /// Blocks until pending disk writes have finished (tests).
    func waitForPendingWrites() {
        disk.waitForPendingWrites()
    }

    private func enqueue(_ request: ImageRequest, priority: Operation.QueuePriority, waiter: Waiter?) {
        let key = request.cacheKey
        let operation: Operation? = pending.withLock { pending in
            if var existing = pending[key] {
                if let waiter { existing.waiters.append(waiter) }
                if priority.rawValue > existing.operation.queuePriority.rawValue {
                    existing.operation.queuePriority = priority
                }
                pending[key] = existing
                return nil
            }
            let op = BlockOperation { [weak self] in
                self?.run(request, mayDownload: true)
            }
            op.queuePriority = priority
            pending[key] = Pending(operation: op, waiters: waiter.map { [$0] } ?? [])
            return op
        }
        if let operation { queue.addOperation(operation) }
    }

    private func run(_ request: ImageRequest, mayDownload: Bool) {
        let key = request.cacheKey
        if let hit = cachedImage(for: request) {
            finish(key: key, image: ImageBox(hit))
            return
        }
        switch produceLocally(request) {
        case .image(let image):
            finish(key: key, image: ImageBox(image))
        case .failed:
            finish(key: key, image: nil)
        case .notLocal where mayDownload:
            Task {
                let isLocal = request.isEmoji ? await self.prepareSize(of: request.url)
                    : await self.source.prepare(request.url)
                guard isLocal else {
                    self.stats.withLock { $0.failures += 1 }
                    self.finish(key: key, image: nil)
                    return
                }
                let op = BlockOperation {
                    self.run(request, mayDownload: false)
                }
                let isPending = self.pending.withLock { pending in
                    guard var entry = pending[key] else { return false }
                    op.queuePriority = entry.operation.queuePriority
                    entry.operation = op
                    pending[key] = entry
                    return true
                }
                if isPending { self.queue.addOperation(op) }
            }
        case .notLocal:
            stats.withLock { $0.failures += 1 }
            finish(key: key, image: nil)
        }
    }

    private func finish(key: String, image: ImageBox?) {
        let waiters = pending.withLock { $0.removeValue(forKey: key)?.waiters ?? [] }
        guard !waiters.isEmpty else { return }
        Task { @MainActor in
            for waiter in waiters { waiter.completion(image?.image) }
        }
    }

    fileprivate func detach(key: String, id: UInt64) {
        pending.withLock { pending in
            guard var entry = pending[key] else { return }
            entry.waiters.removeAll { $0.id == id }
            if entry.waiters.isEmpty {
                entry.operation.queuePriority = .veryLow
            }
            pending[key] = entry
        }
    }

    func mediaSize(for url: String) -> MediaSize {
        if let learned = sizes.withLock({ $0.learned[url] }) { return learned }
        let size = emojiSource.mediaSize(for: url)
        if size == .unknown {
            sizes.withLock { _ = $0.missed.insert(url) }
        }
        return size
    }

    /// Loads the media behind `urls` until their sizes are known (or known to be
    /// unavailable), waiting at most `timeout`. Loads still running then go on, and
    /// `mediaSizesDidChange` tells layout when they finish.
    func prepareSizes(of urls: some Sequence<String>, timeout: Duration) async {
        let unknown = Set(urls).filter { mediaSize(for: $0) == .unknown }
        guard !unknown.isEmpty else { return }
        let loads = Task {
            await withTaskGroup(of: Void.self) { group in
                for url in unknown {
                    group.addTask { await self.prepareSize(of: url) }
                }
            }
        }
        await waitForCompletion(of: loads, timeout: timeout)
    }

    private func prepareSize(of url: String) async -> Bool {
        let size: MediaSize
        if await emojiSource.prepare(url),
           let pixels = emojiSource.imageSource(for: url).flatMap(ImageMetadata.pixelSize(of:)) {
            size = .known(pixels)
        } else {
            size = .unavailable
        }
        let wasMissed = sizes.withLock { sizes in
            sizes.learned[url] = size
            return sizes.missed.remove(url) != nil
        }
        if wasMissed {
            Task { @MainActor in
                NotificationCenter.default.post(name: Self.mediaSizesDidChange, object: self)
            }
        }
        return size != .unavailable
    }

    private enum Produced {
        case image(CGImage)
        case notLocal
        case failed
    }

    private func produce(_ request: ImageRequest) -> CGImage? {
        switch produceLocally(request) {
        case .image(let image): return image
        case .notLocal, .failed: return nil
        }
    }

    private func produceLocally(_ request: ImageRequest) -> Produced {
        let key = request.cacheKey
        if !request.isEmoji, let fromDisk = disk.read(key: key) {
            store(fromDisk, key: key)
            stats.withLock { $0.diskHits += 1 }
            return .image(fromDisk)
        }
        let source = request.isEmoji ? emojiSource : source
        guard let src = source.imageSource(for: request.url) else { return .notLocal }
        let start = CFAbsoluteTimeGetCurrent()
        let state = Signposts.image.beginInterval("process", id: Signposts.image.makeSignpostID())
        defer { Signposts.image.endInterval("process", state) }
        guard let original = ImageMetadata.pixelSize(of: src),
              let image = Self.process(src, original: original, request: request)
        else {
            stats.withLock { $0.failures += 1 }
            return .failed
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        stats.withLock {
            $0.sourceDecodes += 1
            $0.processingSeconds += elapsed
        }
        store(image, key: key)
        if !request.isEmoji { disk.write(image, key: key) }
        return .image(image)
    }

    private func store(_ image: CGImage, key: String) {
        memory.setObject(ImageBox(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }

    /// Decodes a downsampled copy with ImageIO (never the full-resolution bitmap), then
    /// draws it into a bitmap of exactly the requested pixel size (for `.fitted`, the size
    /// it fits at).
    static func process(_ source: CGImageSource, original: CGSize, request: ImageRequest) -> CGImage? {
        let target = CGSize(width: request.pixelWidth, height: request.pixelHeight)
        let sx = target.width / original.width
        let sy = target.height / original.height
        let scale = min(1, request.mode == .aspectFill ? max(sx, sy) : min(sx, sy))
        let maxPixel = max(1, Int((max(original.width, original.height) * scale).rounded(.up)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        var size = target
        if request.mode == .fitted {
            let fit = min(sx, sy)
            size = CGSize(width: max(1, (original.width * fit).rounded()), height: max(1, (original.height * fit).rounded()))
        }
        let opaque = request.shape == .rect && request.mode == .aspectFill && !decoded.hasAlpha
        guard let context = Bitmap.makeContext(width: Int(size.width), height: Int(size.height), opaque: opaque)
        else { return nil }
        context.interpolationQuality = .high
        let bounds = CGRect(origin: .zero, size: size)
        if request.shape == .circle {
            context.addEllipse(in: bounds)
            context.clip()
        }
        let decodedSize = CGSize(width: decoded.width, height: decoded.height)
        context.draw(decoded, in: request.mode == .fitted ? bounds : Self.placement(of: decodedSize, in: bounds, mode: request.mode))
        return context.makeImage()
    }

    static func placement(of size: CGSize, in bounds: CGRect, mode: ImageRequest.Mode) -> CGRect {
        let sx = bounds.width / size.width
        let sy = bounds.height / size.height
        let s = mode == .aspectFill ? max(sx, sy) : min(sx, sy)
        let w = size.width * s
        let h = size.height * s
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }
}

final class ProcessedImageDiskCache: Sendable {
    private let directory: URL
    private let byteLimit: Int
    private let writeQueue = DispatchQueue(label: "hibari.image.disk", qos: .utility)
    nonisolated(unsafe) private var bytesSinceTrim = 0

    init(directory: URL?, byteLimit: Int = 512 * 1024 * 1024) {
        self.directory = directory ?? URL.cachesDirectory.appending(path: "ProcessedImages", directoryHint: .isDirectory)
        self.byteLimit = byteLimit
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        writeQueue.async { self.trim() }
    }

    private func fileURL(for key: String) -> URL {
        directory.appending(path: DiskCacheName.hashed(key))
    }

    func read(key: String) -> CGImage? {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(
                  source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        writeQueue.async {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path(percentEncoded: false))
        }
        return Bitmap.normalized(image)
    }

    func write(_ image: CGImage, key: String) {
        let url = fileURL(for: key)
        let box = ImageBox(image)
        writeQueue.async {
            let type = box.image.hasAlpha ? UTType.png : UTType.jpeg
            let tmp = url.appendingPathExtension("tmp")
            guard let destination = CGImageDestinationCreateWithURL(tmp as CFURL, type.identifier as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(
                destination, box.image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            if CGImageDestinationFinalize(destination) {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.moveItem(at: tmp, to: url)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                self.bytesSinceTrim += size
                if self.bytesSinceTrim > self.byteLimit / 8 { self.trim() }
            }
        }
    }

    func removeAll() {
        writeQueue.sync {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            bytesSinceTrim = 0
        }
    }

    /// Blocks until pending writes and trims have finished (tests).
    func waitForPendingWrites() {
        writeQueue.sync {}
    }

    private func trim() {
        bytesSinceTrim = 0
        DiskCacheName.trim(directory, to: byteLimit)
    }
}
