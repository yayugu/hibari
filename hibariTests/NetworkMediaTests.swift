import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import hibari

@Suite("Network media")
struct NetworkMediaTests {
    private func source(requests: Counter = Counter(), delay: TimeInterval = 0,
                        maxBytes: Int = 64 * 1024 * 1024) -> NetworkMediaSource {
        let png = TestData.png(width: 300, height: 200)
        let session = StubURLProtocol.session { request, _ in
            requests.increment()
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            switch request.url?.path {
            case "/ok.png": return .init(status: 200, body: png, contentType: "image/png")
            case "/untyped.png": return .init(status: 200, body: png, contentType: "application/octet-stream")
            case "/png-as-text": return .init(status: 200, body: png, contentType: "text/html")
            case "/page": return .init(status: 200, body: Data("<html></html>".utf8), contentType: "text/html")
            case "/page-as-image": return .init(status: 200, body: Data("<html></html>".utf8), contentType: "image/png")
            default: return .init(status: 404)
            }
        }
        return NetworkMediaSource(cache: RawMediaCache(directory: TestData.temporaryDirectory()), session: session,
                                  retryDelay: .milliseconds(10), maxBytes: maxBytes)
    }

    @Test func nothingIsLocalUntilPrepared() async {
        let requests = Counter()
        let source = source(requests: requests)
        let url = "https://media.example/ok.png"
        #expect(source.mediaSize(for: url) == .unknown)
        #expect(source.imageSource(for: url) == nil)
        #expect(requests.count == 0, "the synchronous methods never touch the network")

        #expect(await source.prepare(url))
        #expect(source.mediaSize(for: url) == .known(CGSize(width: 300, height: 200)))
        #expect(source.imageSource(for: url) != nil)
        #expect(await source.prepare(url))
        #expect(requests.count == 1, "downloaded once")
    }

    @Test func concurrentPreparesShareOneDownload() async {
        let requests = Counter()
        let source = source(requests: requests, delay: 0.1)
        let url = "https://media.example/ok.png"
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<5 { group.addTask { await source.prepare(url) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results == Array(repeating: true, count: 5))
        #expect(requests.count == 1)
    }

    @Test func failuresAreRemembered() async {
        let requests = Counter()
        let source = source(requests: requests)
        let missing = "https://media.example/gone.png"
        #expect(await source.prepare(missing) == false)
        #expect(source.mediaSize(for: missing) == .unavailable)
        #expect(await source.prepare(missing) == false)
        #expect(requests.count == 1, "an HTTP error is not retried")

        #expect(await source.prepare("not a url") == false)
    }

    @Test func onlyImagesAreKept() async {
        let requests = Counter()
        let source = source(requests: requests)
        for path in ["page", "page-as-image", "png-as-text"] {
            let url = "https://media.example/\(path)"
            #expect(await source.prepare(url) == false, "\(path)")
            #expect(source.localFile(for: url) == nil, "\(path)")
            #expect(source.mediaSize(for: url) == .unavailable, "\(path)")
        }
        #expect(await source.prepare("https://media.example/untyped.png"))

        let small = self.source(maxBytes: 100)
        #expect(await small.prepare("https://media.example/ok.png") == false)
        #expect(small.localFile(for: "https://media.example/ok.png") == nil)
    }

    @Test func connectionProblemsAreRetriedOnce() async {
        let attempts = Counter()
        let png = TestData.png(width: 10, height: 10)
        let session = StubURLProtocol.session { _, _ in
            if attempts.increment() == 1 { throw URLError(.networkConnectionLost) }
            return .init(status: 200, body: png, contentType: "image/png")
        }
        let source = NetworkMediaSource(cache: RawMediaCache(directory: TestData.temporaryDirectory()), session: session,
                                        retryDelay: .milliseconds(10))
        #expect(await source.prepare("https://media.example/flaky.png"))
        #expect(attempts.count == 2)
    }

    @Test func emojisAreKeptAsSmallStills() async throws {
        let gif = TestData.gif(width: 300, height: 200, frames: 4)
        let session = StubURLProtocol.session { _, _ in .init(status: 200, body: gif, contentType: "image/gif") }
        let source = NetworkMediaSource(cache: RawMediaCache(directory: TestData.temporaryDirectory()), session: session,
                                        maxHeight: 128)
        let url = "https://media.example/emoji.gif"
        #expect(await source.prepare(url))
        let kept = try #require(source.localFile(for: url).flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) })
        #expect(CGImageSourceGetType(kept) as String? == UTType.png.identifier)
        #expect(CGImageSourceGetCount(kept) == 1)
        #expect(source.mediaSize(for: url) == .known(CGSize(width: 192, height: 128)))
    }

    @Test func thePipelineDownloadsBeforeProcessing() async throws {
        let requests = Counter()
        let pipeline = ImagePipeline(source: source(requests: requests), diskDirectory: TestData.temporaryDirectory())
        let request = ImageRequest(url: "https://media.example/ok.png", size: CGSize(width: 40, height: 40), scale: 3,
                                   shape: .circle)
        #expect(pipeline.imageSynchronously(for: request) == nil, "synchronous lookups do not wait for the network")

        let sizes = await withCheckedContinuation { (continuation: CheckedContinuation<[CGSize?], Never>) in
            Task { @MainActor in
                var results: [CGSize?] = []
                for _ in 0..<3 {
                    pipeline.load(request) { image in
                        results.append(image.map { CGSize(width: $0.width, height: $0.height) })
                        if results.count == 3 { continuation.resume(returning: results) }
                    }
                }
            }
        }
        #expect(sizes == Array(repeating: CGSize(width: 120, height: 120), count: 3))
        #expect(requests.count == 1)
        #expect(pipeline.stats.withLock { $0.sourceDecodes } == 1)
        #expect(pipeline.cachedImage(for: request) != nil)

        let missing = ImageRequest(url: "https://media.example/gone.png", size: CGSize(width: 10, height: 10), scale: 3)
        let image = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            Task { @MainActor in
                pipeline.load(missing) { continuation.resume(returning: $0 != nil) }
            }
        }
        #expect(image == false)
    }

    @Test func layoutWaitsForEmojiSizesFromTheNetwork() async {
        let pipeline = ImagePipeline(source: source(), diskDirectory: TestData.temporaryDirectory())
        let url = "https://media.example/ok.png"
        #expect(pipeline.mediaSize(for: url) == .unknown)
        await pipeline.prepareSizes(of: [url, "https://media.example/gone.png"], timeout: .seconds(5))
        #expect(pipeline.mediaSize(for: url) == .known(CGSize(width: 300, height: 200)))
        #expect(pipeline.mediaSize(for: "https://media.example/gone.png") == .unavailable)
    }

    @Test func rawCacheStaysUnderItsLimit() throws {
        let directory = TestData.temporaryDirectory()
        let cache = RawMediaCache(directory: directory, byteLimit: 100_000)
        let blob = Data(repeating: 7, count: 20_000)
        for index in 0..<12 {
            let file = FileManager.default.temporaryDirectory.appending(path: "raw-\(UUID().uuidString)")
            try blob.write(to: file)
            #expect(cache.store(file, for: "https://media.example/\(index)"))
        }
        cache.waitForPendingWork()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count < 12 && files.count * 20_000 <= 100_000)
        #expect(cache.file(for: "https://media.example/11") != nil, "the newest are kept")
    }
}
