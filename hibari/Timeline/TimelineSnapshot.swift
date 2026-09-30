import Foundation

struct TimelineSnapshot: Codable, Sendable {
    struct Gap: Codable, Sendable {
        let newerID: String
        let olderID: String
    }

    /// Newest first, as the API sent them.
    var notes: [Note]
    /// Among `notes`.
    var gaps: [Gap]
    /// The newest entry fetched (maybe hidden): a refresh that reaches it leaves no gap.
    var newestID: String?
    /// Where the next page starts, below `notes`.
    var cursor: String?
    /// Notes the timeline has shown (renoted ones for renotes), and since when. A renote
    /// of one is left out of the timeline after a restart; the note itself still shows.
    var shown: [String: Date]
}

struct TimelineSnapshotStore: Sendable {
    static let noteLimit = 50
    static let shownLifetime: TimeInterval = 3 * 86400

    let url: URL

    init(accountID: String, timelineID: String, directory: URL = Self.directory) {
        url = directory.appending(path: DiskCacheName.hashed(accountID), directoryHint: .isDirectory)
            .appending(path: "\(timelineID).json")
    }

    static var directory: URL {
        URL.cachesDirectory.appending(path: AppSettings.usesTestAccounts ? "TimelinesUITest" : "Timelines",
                                      directoryHint: .isDirectory)
    }

    /// Call off the main thread.
    func load() -> TimelineSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? MisskeyJSON.decoder().decode(TimelineSnapshot.self, from: data)
    }

    /// Call off the main thread.
    func save(_ snapshot: TimelineSnapshot) {
        guard let data = try? MisskeyJSON.encoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func removeAll(accountID: String, directory: URL = Self.directory) {
        try? FileManager.default.removeItem(at: directory.appending(path: DiskCacheName.hashed(accountID),
                                                                    directoryHint: .isDirectory))
    }
}
