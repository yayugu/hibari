import Foundation

@MainActor
final class EmojiAspectStore {
    static let shared = EmojiAspectStore(file: URL.cachesDirectory.appending(path: "EmojiAspects.plist"))

    static let minimumAspect: Float = 1.15
    private static let limit = 20_000
    private static let writeQueue = DispatchQueue(label: "hibari.emojiAspects", qos: .utility)

    private let file: URL
    private lazy var aspects: [String: Float] = Self.read(file)
    private var hasChanges = false

    init(file: URL) {
        self.file = file
    }

    func aspect(of url: String) -> Float? {
        aspects[url]
    }

    func record(_ aspect: Float, for url: String) {
        let kept = aspect >= Self.minimumAspect ? aspect : nil
        guard aspects[url] != kept else { return }
        if kept != nil, aspects[url] == nil, aspects.count >= Self.limit {
            aspects.remove(at: aspects.startIndex)
        }
        aspects[url] = kept
        hasChanges = true
    }

    /// Writes the changes in the background.
    func save() {
        guard hasChanges else { return }
        hasChanges = false
        let aspects = self.aspects
        let file = self.file
        Self.writeQueue.async {
            guard let data = try? PropertyListSerialization.data(fromPropertyList: aspects, format: .binary, options: 0)
            else { return }
            try? data.write(to: file, options: .atomic)
        }
    }

    func removeAll() {
        aspects = [:]
        hasChanges = false
        let file = self.file
        Self.writeQueue.async {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Blocks until pending writes have finished (tests).
    func waitForPendingWrites() {
        Self.writeQueue.sync {}
    }

    private static func read(_ file: URL) -> [String: Float] {
        guard let data = try? Data(contentsOf: file),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: NSNumber]
        else { return [:] }
        return plist.mapValues(\.floatValue)
    }
}
