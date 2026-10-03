import Foundation

/// What the composer has written so far, kept on disk until the note is sent or thrown
/// away: closing the composer or the app quitting does not lose it.
struct ComposeDraft: Codable, Sendable {
    /// A photo whose image is ready. The prepared image itself is a file next to the draft.
    struct Attachment: Codable, Sendable {
        let id: UUID
        let name: String
        let mimeType: String
        let fileExtension: String
        let width: Double
        let height: Double
        /// Once uploaded: sending the note again does not upload it again.
        var file: DriveFile?

        var pixelSize: CGSize { CGSize(width: width, height: height) }
    }

    var text: String
    var visibility: String
    var quote: Note?
    var attachments: [Attachment]
}

/// The draft of one composer: each way of opening it (a new note, a reply to a note, a
/// quote of a note, a direct note to a user) has its own per account, and opening it the
/// same way again picks the draft up.
struct ComposeDraftStore: Sendable {
    enum Slot: Equatable {
        case note
        case reply(noteID: String)
        case quote(noteID: String)
        case direct(userID: String)

        var name: String {
            switch self {
            case .note: "note"
            case .reply(let id): "reply-\(id)"
            case .quote(let id): "quote-\(id)"
            case .direct(let id): "direct-\(id)"
            }
        }
    }

    let directory: URL

    init(accountID: String, slot: Slot, root: URL = Self.root) {
        directory = root.appending(path: DiskCacheName.hashed(accountID), directoryHint: .isDirectory)
            .appending(path: DiskCacheName.hashed(slot.name), directoryHint: .isDirectory)
    }

    /// Not caches: the system may empty those.
    static var root: URL {
        URL.applicationSupportDirectory.appending(path: AppSettings.usesTestAccounts ? "DraftsUITest" : "Drafts",
                                                  directoryHint: .isDirectory)
    }

    /// Writes run in order on one queue, so a draft never names an image not yet written
    /// and a removal is not undone by a write sent before it.
    private static let queue = DispatchQueue(label: "hibari.compose.drafts", qos: .utility)

    private var draftURL: URL { directory.appending(path: "draft.json") }

    func imageURL(for id: UUID) -> URL { directory.appending(path: id.uuidString) }

    /// Small (the images stay on disk), so the composer reads it as it opens.
    func load() -> ComposeDraft? {
        Self.queue.sync {
            guard let data = try? Data(contentsOf: draftURL) else { return nil }
            return try? MisskeyJSON.decoder().decode(ComposeDraft.self, from: data)
        }
    }

    func save(_ draft: ComposeDraft) {
        guard let data = try? MisskeyJSON.encoder().encode(draft) else { return }
        let directory = directory, url = draftURL
        Self.queue.async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            Self.removeImages(in: directory, keeping: Set(draft.attachments.map(\.id)))
        }
    }

    func saveImage(_ data: Data, for id: UUID) {
        let directory = directory, url = imageURL(for: id)
        Self.queue.async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    func remove() {
        let directory = directory
        Self.queue.async { try? FileManager.default.removeItem(at: directory) }
    }

    /// Waits for the writes sent so far (tests).
    func flush() {
        Self.queue.sync {}
    }

    static func removeAll(accountID: String, root: URL = Self.root) {
        let directory = root.appending(path: DiskCacheName.hashed(accountID), directoryHint: .isDirectory)
        queue.async { try? FileManager.default.removeItem(at: directory) }
    }

    /// Images of photos taken off the note. An image is written just before the first
    /// draft naming it, so none is removed before that draft.
    private static func removeImages(in directory: URL, keeping ids: Set<UUID>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for file in files {
            guard let id = UUID(uuidString: file.lastPathComponent), !ids.contains(id) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
