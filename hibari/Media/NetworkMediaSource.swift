import Foundation
import ImageIO
import UniformTypeIdentifiers

final class NetworkMediaSource: MediaSource {
    static let shared = NetworkMediaSource(
        cache: RawMediaCache(directory: URL.cachesDirectory.appending(path: "RawMedia", directoryHint: .isDirectory)))

    static let emojis = NetworkMediaSource(
        cache: RawMediaCache(directory: URL.cachesDirectory.appending(path: "Emojis", directoryHint: .isDirectory),
                             byteLimit: 64 * 1024 * 1024),
        maxHeight: 128)

    private let session: URLSession
    private let cache: RawMediaCache
    private let retryDelay: Duration
    private let maxBytes: Int
    private let maxHeight: Int?
    private let sizes = Locked<[String: MediaSize]>([:])
    private let unavailable = Locked<Set<String>>([])
    private let downloads = Locked<[String: Task<Bool, Never>]>([:])

    init(cache: RawMediaCache, session: URLSession = .media, retryDelay: Duration = .seconds(1),
         maxBytes: Int = 64 * 1024 * 1024, maxHeight: Int? = nil) {
        self.cache = cache
        self.session = session
        self.retryDelay = retryDelay
        self.maxBytes = maxBytes
        self.maxHeight = maxHeight
    }

    func removeAllCaches() {
        cache.removeAll()
        sizes.withLock { $0.removeAll() }
        unavailable.withLock { $0.removeAll() }
    }

    func localFile(for url: String) -> URL? {
        cache.file(for: url)
    }

    func imageSource(for url: String) -> CGImageSource? {
        guard let file = cache.file(for: url) else { return nil }
        return CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    func mediaSize(for url: String) -> MediaSize {
        if let known = sizes.withLock({ $0[url] }) { return known }
        if unavailable.withLock({ $0.contains(url) }) { return .unavailable }
        guard let source = imageSource(for: url) else { return .unknown }
        let size = ImageMetadata.pixelSize(of: source).map(MediaSize.known) ?? .unavailable
        sizes.withLock { $0[url] = size }
        return size
    }

    func prepare(_ url: String) async -> Bool {
        if cache.file(for: url) != nil { return true }
        if unavailable.withLock({ $0.contains(url) }) { return false }
        let task = downloads.withLock { downloads in
            if let running = downloads[url] { return running }
            let task = Task { await self.download(url) }
            downloads[url] = task
            return task
        }
        return await task.value
    }

    private func download(_ url: String) async -> Bool {
        defer { downloads.withLock { _ = $0.removeValue(forKey: url) } }
        guard let requestURL = URL(string: url), requestURL.scheme == "https" || requestURL.scheme == "http" else {
            unavailable.withLock { _ = $0.insert(url) }
            return false
        }
        for attempt in 0..<2 {
            do {
                let (file, response) = try await session.download(from: requestURL)
                defer { try? FileManager.default.removeItem(at: file) }
                if let http = response as? HTTPURLResponse,
                   http.statusCode == 408 || http.statusCode == 429 || (500...599).contains(http.statusCode) {
                    return false
                }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      isImage(file, response: http)
                else {
                    unavailable.withLock { _ = $0.insert(url) }
                    return false
                }
                guard let kept = maxHeight.map({ Self.still(of: file, maxHeight: $0) }) ?? file else { return false }
                return cache.store(kept, for: url)
            } catch {
                if attempt == 0 { try? await Task.sleep(for: retryDelay) }
            }
        }
        return false
    }

    private static func still(of file: URL, maxHeight: Int) -> URL? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let size = ImageMetadata.pixelSize(of: source)
        else { return nil }
        let scale = min(1, CGFloat(maxHeight) / size.height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int((max(size.width, size.height) * scale).rounded()),
        ]
        let still = file.appendingPathExtension("png")
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let destination = CGImageDestinationCreateWithURL(still as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? still : nil
    }

    private func isImage(_ file: URL, response: HTTPURLResponse) -> Bool {
        if let type = response.mimeType?.lowercased(),
           !type.hasPrefix("image/"), type != "application/octet-stream", type != "binary/octet-stream" {
            return false
        }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 0, size <= maxBytes,
              let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return false }
        return ImageMetadata.pixelSize(of: source) != nil
    }
}

extension URLSession {
    static let media: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.httpAdditionalHeaders = ["User-Agent": HibariUserAgent.value]
        return URLSession(configuration: configuration)
    }()
}

final class RawMediaCache: Sendable {
    private let directory: URL
    private let byteLimit: Int
    private let queue = DispatchQueue(label: "hibari.media.raw", qos: .utility)
    nonisolated(unsafe) private var bytesSinceTrim = 0

    init(directory: URL, byteLimit: Int = 256 * 1024 * 1024) {
        self.directory = directory
        self.byteLimit = byteLimit
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        queue.async { self.trim() }
    }

    private func path(for url: String) -> URL {
        directory.appending(path: DiskCacheName.hashed(url))
    }

    /// The file for `url` if it has been downloaded. Marks it as recently used.
    func file(for url: String) -> URL? {
        let file = path(for: url)
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return nil }
        queue.async {
            try? FileManager.default.setAttributes([.modificationDate: Date()],
                                                   ofItemAtPath: file.path(percentEncoded: false))
        }
        return file
    }

    /// Moves a downloaded file in. Returns false if that failed.
    func store(_ downloaded: URL, for url: String) -> Bool {
        let destination = path(for: url)
        let size = (try? downloaded.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: downloaded, to: destination)
        } catch {
            return false
        }
        queue.async {
            self.bytesSinceTrim += size
            if self.bytesSinceTrim > self.byteLimit / 8 { self.trim() }
        }
        return true
    }

    func removeAll() {
        queue.sync {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            bytesSinceTrim = 0
        }
    }

    /// Blocks until pending bookkeeping has finished (tests).
    func waitForPendingWork() {
        queue.sync {}
    }

    private func trim() {
        bytesSinceTrim = 0
        DiskCacheName.trim(directory, to: byteLimit)
    }
}
