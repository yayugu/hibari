import CoreGraphics
import Foundation
import Testing
@testable import hibari

@Suite("Image pipeline")
struct ImagePipelineTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "hibari-tests-\(UUID().uuidString)")
    }

    private let avatar = ImageRequest(url: "https://media.example/avatar.png?w=96&h=96",
                                      size: CGSize(width: 24, height: 24), scale: 3, shape: .circle)

    @Test func displayImagesHaveTheRequestedPixelsAndAvatarMask() throws {
        let pipeline = ImagePipeline(source: SampleMediaSource(), diskDirectory: temporaryDirectory())
        let media = ImageRequest(url: "https://media.example/photo.png?w=320&h=160",
                                 size: CGSize(width: 40, height: 30), scale: 3)
        for request in [avatar, media] {
            let image = try #require(pipeline.imageSynchronously(for: request))
            #expect(image.width == request.pixelWidth && image.height == request.pixelHeight)
            #expect(image.bitmapInfo.contains(.byteOrder32Little) && image.bitsPerPixel == 32)
            if request.shape == .circle {
                #expect(alpha(of: image, x: 0, y: 0) == 0)
                #expect(alpha(of: image, x: image.width / 2, y: image.height / 2) > 0)
            }
        }
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

    @Test func preparingSizesStopsWaitingAtTheTimeoutButNotLoading() async throws {
        let base = SampleMediaSource()
        let pipeline = ImagePipeline(source: DownloadingMediaSource(base: base, delay: .milliseconds(150)),
                                     diskDirectory: temporaryDirectory())
        let request = avatar
        let start = ContinuousClock.now
        await pipeline.prepareSizes(of: [request.url], timeout: .milliseconds(30))
        #expect(ContinuousClock.now - start < .milliseconds(200))
        #expect(pipeline.mediaSize(for: request.url) == .unknown)
        for _ in 0..<50 where pipeline.mediaSize(for: request.url) == .unknown {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(pipeline.mediaSize(for: request.url) == base.mediaSize(for: request.url), "the download went on")
    }

    @Test func oversizedBlocksAreNotRasterized() {
        let tall = RasterBlock(frame: CGRect(x: 0, y: 0, width: 300, height: 10_000), ops: [])
        #expect(Rasterizer.render(tall, palette: .dark, scale: 3) { _ in nil } == nil)
        let normal = RasterBlock(frame: CGRect(x: 0, y: 0, width: 300, height: 100), ops: [])
        #expect(Rasterizer.render(normal, palette: .dark, scale: 3) { _ in nil } != nil)
    }

    /// Both render threads want the same action icons when the first notes are drawn. Drawing
    /// one of UIKit's vector images on two threads at once corrupts memory (the app crashed on
    /// launch), so each icon is drawn once, by one thread, whoever asks.
    @Test func iconsWantedOnManyThreadsAtOnceAreDrawnOnceEach() {
        let icons: [Icon] = [.reply, .renote, .reaction, .bookmark, .share, .file]
        for round in 0..<300 {
            let store = IconStore()
            let icon = icons[round % icons.count]
            let sizes = [CGSize(width: 18, height: 18), CGSize(width: 22, height: 22)]
            let images = Locked<[[CGImage]]>([[], []])
            DispatchQueue.concurrentPerform(iterations: 8) { index in
                let image = store.image(icon, size: sizes[index % 2], role: .secondaryText, palette: .dark, scale: 3)
                if let image { images.withLock { $0[index % 2].append(image) } }
            }
            for drawn in images.withLock({ $0 }) {
                #expect(drawn.count == 4 && drawn.allSatisfy { $0 === drawn[0] }, "\(icon) in round \(round)")
            }
        }
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
