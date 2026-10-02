import CoreGraphics
import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import hibari

@Suite("Media viewer")
@MainActor
struct MediaViewerTests {
    private static let still = "https://media.example/still.png"
    private static let animated = "https://media.example/animated.gif"

    private let window: UIWindow

    init() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
    }

    private func page(_ url: String, isCurrent: Bool) async throws -> MediaPageView {
        let directory = TestData.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: URL(string: url)!.lastPathComponent)
        // Still larger than a 402pt @3x page, so zooming must decode a sharper bitmap.
        let data = url == Self.still ? TestData.png(width: 1600, height: 1000)
            : TestData.gif(width: 300, height: 200, frames: 4)
        try data.write(to: file)
        let pipeline = ImagePipeline(source: FileMediaSource(files: [url: file]),
                                     diskDirectory: directory.appending(path: "processed"))
        let page = MediaPageView(file: DriveFile(imageURL: url), imagePipeline: pipeline)
        page.frame = window.bounds
        window.addSubview(page)
        page.layoutIfNeeded()
        page.isCurrent = isCurrent
        await withCheckedContinuation { continuation in
            page.load(scale: page.traitCollection.displayScale) { continuation.resume() }
        }
        return page
    }

    private func pixelWidth(of page: MediaPageView) -> Int {
        page.imageView.image?.cgImage?.width ?? 0
    }

    private func wait(until condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func leavingAPageDropsItsBitmapForZooming() async throws {
        let page = try await page(Self.still, isCurrent: true)
        let fitted = pixelWidth(of: page)
        try #require(fitted > 0)

        page.zoomScale = 2
        await wait { pixelWidth(of: page) > fitted }
        #expect(pixelWidth(of: page) > fitted, "zooming in decodes a sharper bitmap")
        page.zoomScale = 1
        #expect(pixelWidth(of: page) > fitted, "kept while the page is on screen")

        page.isCurrent = false
        #expect(pixelWidth(of: page) == fitted)

        page.isCurrent = true
        page.zoomScale = 2
        page.isCurrent = false
        try await Task.sleep(for: .milliseconds(300))
        #expect(pixelWidth(of: page) == fitted)
    }

    @Test func onlyTheCurrentPageAnimates() async throws {
        let page = try await page(Self.animated, isCurrent: false)
        let firstFrame = try #require(page.imageView.image)
        try await Task.sleep(for: .milliseconds(150))
        #expect(page.imageView.image === firstFrame, "a neighbour shows its first frame")

        page.isCurrent = true
        await wait { page.imageView.image !== firstFrame }
        #expect(page.imageView.image !== firstFrame)

        page.isCurrent = false
        #expect(page.imageView.image === firstFrame)
        try await Task.sleep(for: .milliseconds(150))
        #expect(page.imageView.image === firstFrame, "no more frames once it is left")
    }

    @Test func pagesLetGoOfTheirImagesAndLoadThemAgain() async throws {
        let page = try await page(Self.still, isCurrent: false)
        #expect(page.isLoaded && page.imageView.image != nil)
        page.unload()
        #expect(!page.isLoaded && page.imageView.image == nil)

        page.load(scale: page.traitCollection.displayScale)
        page.unload()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!page.isLoaded && page.imageView.image == nil)

        await withCheckedContinuation { continuation in
            page.load(scale: page.traitCollection.displayScale) { continuation.resume() }
        }
        #expect(page.isLoaded && page.imageView.image != nil)
    }
}

private final class FileMediaSource: MediaSource {
    private let files: [String: URL]

    init(files: [String: URL]) {
        self.files = files
    }

    func imageSource(for url: String) -> CGImageSource? {
        files[url].flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }
    }

    func mediaSize(for url: String) -> MediaSize {
        imageSource(for: url).flatMap(ImageMetadata.pixelSize(of:)).map(MediaSize.known) ?? .unavailable
    }

    func prepare(_ url: String) async -> Bool {
        files[url] != nil
    }

    func localFile(for url: String) -> URL? {
        files[url]
    }
}
