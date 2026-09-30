import ImageIO
import UIKit
import UniformTypeIdentifiers

struct PreparedImage: Sendable {
    let data: Data
    let mimeType: String
    let fileExtension: String
    let pixelSize: CGSize
}

enum ImageUploadPreparation {
    static let maxPixelSize = 4096

    enum Failure: Error {
        case unreadable
    }

    /// GIFs as they are (they may be animated), and PNGs unless they are too large or
    /// carry a location. Everything else (HEIC, JPEG, …) is drawn again upright as a JPEG,
    /// which leaves its metadata (location, camera, date) behind.
    static func prepare(_ data: Data) throws -> PreparedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { throw Failure.unreadable }

        if type.conforms(to: .gif) {
            return PreparedImage(data: data, mimeType: "image/gif", fileExtension: "gif",
                                 pixelSize: CGSize(width: width, height: height))
        }
        let isPNG = type.conforms(to: .png)
        if isPNG && max(width, height) <= maxPixelSize && properties[kCGImagePropertyGPSDictionary] == nil {
            return PreparedImage(data: data, mimeType: "image/png", fileExtension: "png",
                                 pixelSize: CGSize(width: width, height: height))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixelSize, max(width, height)),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.unreadable
        }
        let output = NSMutableData()
        let outputType = isPNG ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(output, outputType.identifier as CFString, 1, nil)
        else { throw Failure.unreadable }
        let encoding: [CFString: Any] = isPNG ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(destination, image, encoding as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unreadable }
        return PreparedImage(data: output as Data, mimeType: isPNG ? "image/png" : "image/jpeg",
                             fileExtension: isPNG ? "png" : "jpg",
                             pixelSize: CGSize(width: image.width, height: image.height))
    }

    static func thumbnail(of data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static let queue = DispatchQueue(label: "hibari.compose.prepare", qos: .userInitiated)

    /// `prepare` and a thumbnail, off the main thread.
    static func prepareInBackground(_ data: Data, thumbnailSize: Int) async throws -> (PreparedImage, CGImage?) {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let prepared = try prepare(data)
                    continuation.resume(returning: (prepared, thumbnail(of: prepared.data, maxPixelSize: thumbnailSize)))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// A photo attached to the note being written. It uploads as soon as it is picked; the
/// note waits for it when sent.
@MainActor
final class ComposeAttachment {
    enum State: Equatable {
        case preparing
        /// How much has been sent (0...1).
        case uploading(Double)
        case uploaded
        case failed
    }

    let id = UUID()
    private(set) var state = State.preparing {
        didSet { if state != oldValue { onChange?() } }
    }
    private(set) var thumbnail: UIImage?
    /// Width / height (1 until known).
    private(set) var aspectRatio: CGFloat = 1
    var onChange: (() -> Void)?

    private let client: MisskeyClient
    private let name: String
    private let load: @Sendable () async throws -> Data
    private var prepared: PreparedImage?
    private var upload: Task<DriveFile, any Error>?

    /// `name` without an extension (the photo's file name); the prepared image's goes on.
    init(name: String, client: MisskeyClient, load: @escaping @Sendable () async throws -> Data) {
        self.name = name
        self.client = client
        self.load = load
        start()
    }

    convenience init(_ provider: NSItemProvider, client: MisskeyClient) {
        let type = provider.registeredContentTypes.first { $0.conforms(to: .image) } ?? .image
        nonisolated(unsafe) let provider = provider
        self.init(name: provider.suggestedName ?? "image", client: client) {
            try await withCheckedThrowingContinuation { continuation in
                _ = provider.loadDataRepresentation(for: type) { data, error in
                    if let data {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: error ?? ImageUploadPreparation.Failure.unreadable)
                    }
                }
            }
        }
    }

    /// The uploaded file, once it is (a failed upload is tried again).
    func file() async throws -> DriveFile {
        if state == .failed { start() }
        guard let upload else { throw CancellationError() }
        return try await upload.value
    }

    func retry() {
        guard state == .failed else { return }
        start()
    }

    /// Removed from the note: stops uploading. (A file already uploaded stays in the drive,
    /// as with Misskey's own client.)
    func cancel() {
        upload?.cancel()
        upload = nil
    }

    private func start() {
        state = prepared == nil ? .preparing : .uploading(0)
        let task = Task { [weak self, client, name, load] () async throws -> DriveFile in
            let prepared: PreparedImage
            if let ready = self?.prepared {
                prepared = ready
            } else {
                let (image, thumbnail) = try await ImageUploadPreparation.prepareInBackground(try await load(),
                                                                                             thumbnailSize: 900)
                prepared = image
                self?.didPrepare(image, thumbnail: thumbnail)
            }
            try Task.checkCancellation()
            return try await client.uploadFile(prepared.data, name: "\(name).\(prepared.fileExtension)",
                                               mimeType: prepared.mimeType) { sent in
                Task { @MainActor in self?.didSend(sent) }
            }
        }
        upload = task
        Task { [weak self] in
            do {
                _ = try await task.value
                guard let self, self.upload == task else { return }
                self.state = .uploaded
                self.prepared = nil
            } catch {
                guard let self, self.upload == task else { return }
                self.state = .failed
            }
        }
    }

    private func didPrepare(_ image: PreparedImage, thumbnail: CGImage?) {
        prepared = image
        aspectRatio = image.pixelSize.width / max(1, image.pixelSize.height)
        self.thumbnail = thumbnail.map { UIImage(cgImage: $0) }
        state = .uploading(0)
        onChange?()
    }

    private func didSend(_ share: Double) {
        guard case .uploading = state else { return }
        state = .uploading(share)
    }
}
