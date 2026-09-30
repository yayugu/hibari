import CoreGraphics
import Foundation
import Testing
@testable import hibari

@Suite("Image pipeline")
struct ImagePipelineTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "hibari-tests-\(UUID().uuidString)")
    }

    private func sampleRequests(_ count: Int) -> [ImageRequest] {
        let layouts = Samples.engine().layouts(
            for: Array(Samples.items.prefix(200)),
            context: Samples.context(revealsSensitiveMedia: true))
        var seen = Set<String>()
        return layouts.flatMap(\.imageRequests)
            .filter { SampleMediaSource.pixelSize(of: $0.url) != nil && seen.insert($0.cacheKey).inserted }
            .prefix(count)
            .map { $0 }
    }

    @Test func producesExactlyTheDisplayPixelSize() {
        let pipeline = ImagePipeline(source: SampleMediaSource(), diskDirectory: temporaryDirectory())
        let requests = sampleRequests(30)
        #expect(requests.count == 30)
        for request in requests {
            guard let image = pipeline.imageSynchronously(for: request) else {
                Issue.record("failed to process \(request.url)")
                continue
            }
            #expect(image.width == request.pixelWidth && image.height == request.pixelHeight)
            #expect(image.bitmapInfo.contains(.byteOrder32Little))
            #expect(image.bitsPerPixel == 32)
        }
    }

    @Test func circleRequestsHaveTransparentCorners() throws {
        let request = try #require(sampleRequests(80).first { $0.shape == .circle })
        let pipeline = ImagePipeline(source: SampleMediaSource(), diskDirectory: temporaryDirectory())
        let image = try #require(pipeline.imageSynchronously(for: request))
        #expect(alpha(of: image, x: 0, y: 0) == 0)
        #expect(alpha(of: image, x: image.width / 2, y: image.height / 2) > 0)
    }

    @Test func fittedRequestsComeBackAtTheImagesShape() throws {
        let pipeline = ImagePipeline(source: SampleMediaSource(), diskDirectory: temporaryDirectory())
        func fitted(_ width: Int, _ height: Int) throws -> CGImage {
            try #require(pipeline.imageSynchronously(for: ImageRequest(
                url: "https://media.example/emoji/e.png?w=\(width)&h=\(height)", size: CGSize(width: 272, height: 34),
                scale: 3, mode: .fitted)))
        }
        let wide = try fitted(384, 96)
        #expect((wide.width, wide.height) == (408, 102))
        let tall = try fitted(96, 160)
        #expect((tall.width, tall.height) == (61, 102))
        let banner = try fitted(2000, 100)
        #expect((banner.width, banner.height) == (816, 41))
    }

    @Test func processedImagesComeBackFromTheDiskCache() throws {
        let directory = temporaryDirectory()
        let source = SampleMediaSource()
        let request = try #require(sampleRequests(1).first)
        let first = ImagePipeline(source: source, diskDirectory: directory)
        _ = try #require(first.imageSynchronously(for: request))
        #expect(first.stats.withLock { $0.sourceDecodes } == 1)

        first.waitForPendingWrites()
        let second = ImagePipeline(source: source, diskDirectory: directory)
        let image = try #require(second.imageSynchronously(for: request))
        #expect(second.stats.withLock { $0.diskHits } == 1)
        #expect(second.stats.withLock { $0.sourceDecodes } == 0)
        #expect(image.width == request.pixelWidth)
    }

    @Test func asynchronousLoadsAreDeduplicated() async throws {
        let request = try #require(sampleRequests(1).first)
        let pipeline = ImagePipeline(source: SampleMediaSource(), diskDirectory: temporaryDirectory())
        let results = await withCheckedContinuation { (continuation: CheckedContinuation<[Bool], Never>) in
            Task { @MainActor in
                let collector = Collector()
                for _ in 0..<3 {
                    pipeline.load(request) { image in
                        collector.results.append(image != nil)
                        if collector.results.count == 3 { continuation.resume(returning: collector.results) }
                    }
                }
            }
        }
        #expect(results == [true, true, true])
        #expect(pipeline.stats.withLock { $0.sourceDecodes } == 1)
        #expect(pipeline.cachedImage(for: request) != nil)
    }

    @Test func newBitmapContextsAreFullyTransparent() throws {
        for _ in 0..<20 {
            let dirty = try #require(Bitmap.makeContext(width: 300, height: 200, opaque: false))
            dirty.setFillColor(CGColor(gray: 1, alpha: 1))
            dirty.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        }
        let context = try #require(Bitmap.makeContext(width: 300, height: 200, opaque: false))
        let image = try #require(context.makeImage())
        let data = try #require(image.dataProvider?.data) as Data
        #expect(data.allSatisfy { $0 == 0 })
    }

    @Test func blurhashDecodes() throws {
        let image = try #require(Blurhash.decode("LEHV6nWB2yk8pyo0adR*.7kCMdnj", width: 24, height: 24))
        #expect(image.width == 24 && image.height == 24)
        #expect(Blurhash.decode("bad", width: 8, height: 8) == nil)
    }

    @Test func blurhashCacheKeepsSizesApart() {
        let hash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
        #expect(Blurhash.image(for: hash, size: 8)?.width == 8)
        #expect(Blurhash.image(for: hash, size: 16)?.width == 16)
        #expect(Blurhash.cachedImage(for: hash, size: 8)?.width == 8)
    }

    @Test func diskCacheStaysUnderItsLimit() throws {
        let directory = temporaryDirectory()
        let limit = 1_000_000
        let cache = ProcessedImageDiskCache(directory: directory, byteLimit: limit)
        let image = try #require(noise(width: 256, height: 256))
        for index in 0..<24 {
            cache.write(image, key: "image-\(index)")
        }
        cache.waitForPendingWrites()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        let total = try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        #expect(files.count < 24, "some files were dropped")
        #expect(total <= limit)
        #expect(cache.read(key: "image-23") != nil, "the newest are kept")
    }

    @Test func preparingSizesWaitsForDownloads() async throws {
        let base = SampleMediaSource()
        let pipeline = ImagePipeline(source: DownloadingMediaSource(base: base, delay: .milliseconds(100)),
                                     diskDirectory: temporaryDirectory())
        let request = try #require(sampleRequests(1).first)
        #expect(pipeline.mediaSize(for: request.url) == .unknown)
        await pipeline.prepareSizes(of: [request.url], timeout: .seconds(5))
        #expect(pipeline.mediaSize(for: request.url) == base.mediaSize(for: request.url))

        let missing = "https://missing.example/emoji.png"
        await pipeline.prepareSizes(of: [missing], timeout: .seconds(5))
        #expect(pipeline.mediaSize(for: missing) == .unavailable)
    }

    @Test func preparingSizesStopsWaitingAtTheTimeoutButNotLoading() async throws {
        let base = SampleMediaSource()
        let pipeline = ImagePipeline(source: DownloadingMediaSource(base: base, delay: .milliseconds(150)),
                                     diskDirectory: temporaryDirectory())
        let request = try #require(sampleRequests(1).first)
        let start = ContinuousClock.now
        await pipeline.prepareSizes(of: [request.url], timeout: .milliseconds(30))
        #expect(ContinuousClock.now - start < .milliseconds(200))
        #expect(pipeline.mediaSize(for: request.url) == .unknown)
        for _ in 0..<50 where pipeline.mediaSize(for: request.url) == .unknown {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(pipeline.mediaSize(for: request.url) == base.mediaSize(for: request.url), "the download went on")
    }

    @Test func timeLabelsAreDrawnAtTheSlotHeight() throws {
        let request = TimeLabelRequest(text: " · 5分", fontSize: 15, color: .secondaryText, style: .dark,
                                       height: 21, baseline: 15, scale: 3)
        let image = try #require(TimeLabelRenderer.image(for: request))
        #expect(image.height == 63 && image.width > 0)
        #expect(TimeLabelRenderer.cachedImage(for: request) === image)
    }

    @Test func oversizedBlocksAreNotRasterized() {
        let tall = RasterBlock(frame: CGRect(x: 0, y: 0, width: 300, height: 10_000), ops: [])
        #expect(Rasterizer.render(tall, palette: .dark, scale: 3) { _ in nil } == nil)
        let normal = RasterBlock(frame: CGRect(x: 0, y: 0, width: 300, height: 100), ops: [])
        #expect(Rasterizer.render(normal, palette: .dark, scale: 3) { _ in nil } != nil)
    }

    @Test func emojisComeFromTheirOwnSource() async throws {
        let directory = temporaryDirectory()
        let pipeline = ImagePipeline(source: SampleMediaSource(),
                                     emojiSource: DownloadingMediaSource(base: SampleMediaSource(), delay: .zero),
                                     diskDirectory: directory)
        let url = "https://media.example/emoji/e.png?w=96&h=96"
        let emoji = NoteLayout.emojiRequest(url, CGSize(width: 20, height: 20), 3)
        #expect(pipeline.imageSynchronously(for: ImageRequest(url: url, size: CGSize(width: 20, height: 20), scale: 3)) != nil)
        #expect(pipeline.imageSynchronously(for: emoji) == nil)
        #expect(pipeline.mediaSize(for: url) == .unknown)

        await pipeline.prepareSizes(of: [url], timeout: .seconds(5))
        #expect(pipeline.imageSynchronously(for: emoji) != nil)
        pipeline.waitForPendingWrites()
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).count == 1,
                "only the media image")
    }

    @Test func loadingAnEmojiAnnouncesItsSize() async throws {
        let pipeline = ImagePipeline(source: DownloadingMediaSource(base: SampleMediaSource(), delay: .milliseconds(10)),
                                     diskDirectory: temporaryDirectory())
        let url = "https://media.example/emoji/wide.png?w=384&h=96"
        let announced = Locked(false)
        let observer = NotificationCenter.default.addObserver(forName: ImagePipeline.mediaSizesDidChange,
                                                              object: pipeline, queue: nil) { _ in
            announced.withLock { $0 = true }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        #expect(pipeline.mediaSize(for: url) == .unknown)
        await MainActor.run { _ = pipeline.load(NoteLayout.emojiRequest(url, CGSize(width: 20, height: 20), 3)) { _ in } }
        for _ in 0..<150 where !announced.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(announced.withLock { $0 })
        #expect(pipeline.mediaSize(for: url) == .known(CGSize(width: 384, height: 96)))
    }

    @Test func notesAreRedrawnWhenAMissingEmojiArrives() async throws {
        let (name, url) = try #require(Samples.emojis.first)
        let engine = NoteLayoutEngine(emojiResolver: EmojiResolver(localEmojis: [name: url], mediaProxy: nil),
                                      sizes: SampleMediaSource())
        let layout = engine.layout(for: TimelineItem(note: try Samples.makeNote(text: "猫:\(name):")),
                                   context: Samples.context())
        let pipeline = ImagePipeline(source: FlakyMediaSource(base: SampleMediaSource()),
                                     diskDirectory: temporaryDirectory())
        let renderer = NoteRenderer(imagePipeline: pipeline)
        let redrawn = Locked<RenderedNote?>(nil)
        let observer = NotificationCenter.default.addObserver(forName: NoteRenderer.didRedraw, object: renderer,
                                                              queue: nil) { notification in
            let note = notification.userInfo?["note"] as? RenderedNote
            redrawn.withLock { $0 = note }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let first = renderer.renderSynchronously(layout)
        #expect(first.missingEmojis.map(\.url) == [url])
        for _ in 0..<150 where redrawn.withLock({ $0 }) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let second = try #require(redrawn.withLock { $0 })
        #expect(second.serial == layout.serial && second.missingEmojis.isEmpty)
        #expect(renderer.cached(layout) === second)
    }

    @MainActor private final class Collector {
        var results: [Bool] = []
    }

    private func noise(width: Int, height: Int) -> CGImage? {
        guard let context = Bitmap.makeContext(width: width, height: height, opaque: true),
              let data = context.data
        else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        for index in 0..<(context.bytesPerRow * height) {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return context.makeImage()
    }

    private func alpha(of image: CGImage, x: Int, y: Int) -> UInt8 {
        guard let data = image.dataProvider?.data as Data? else { return 0 }
        return data[y * image.bytesPerRow + x * 4 + 3]
    }
}
