import CryptoKit
import Foundation

enum DiskCacheName {
    static func hashed(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Deletes the least recently modified files until `directory` is at 3/4 of `limit`,
    /// if it is over it.
    static func trim(_ directory: URL, to limit: Int) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)
        else { return }
        var files = urls.compactMap { url -> (url: URL, size: Int, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), let size = values.fileSize else { return nil }
            return (url, size, values.contentModificationDate ?? .distantPast)
        }
        var total = files.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        files.sort { $0.date < $1.date }
        for file in files where total > limit * 3 / 4 {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }
}
