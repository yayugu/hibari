import Foundation

struct EmojiCatalog: Sendable {
    struct Entry: Codable, Hashable, Sendable {
        let name: String
        let url: String
        let aliases: [String]
        let category: String?
        /// nil when not, and in copies saved before it existed.
        var isSensitive: Bool? = nil
    }

    struct Category: Sendable {
        let name: String
        let entries: [Entry]
    }

    let entries: [Entry]
    /// Categories in the order their first emoji appears; uncategorized emojis last.
    let categories: [Category]
    private let byName: [String: Entry]
    private let searchTerms: [[String]]

    static let empty = EmojiCatalog(entries: [])

    init(entries: [Entry]) {
        self.entries = entries
        byName = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        searchTerms = entries.map { entry in
            [entry.name.lowercased()] + entry.aliases.filter { !$0.isEmpty }.map { $0.lowercased() }
        }
        var order: [String] = []
        var grouped: [String: [Entry]] = [:]
        var uncategorized: [Entry] = []
        for entry in entries {
            guard let category = entry.category, !category.isEmpty else {
                uncategorized.append(entry)
                continue
            }
            if grouped[category] == nil { order.append(category) }
            grouped[category, default: []].append(entry)
        }
        var categories = order.map { Category(name: $0, entries: grouped[$0]!) }
        if !uncategorized.isEmpty {
            categories.append(Category(name: categories.isEmpty ? "カスタム絵文字" : "その他", entries: uncategorized))
        }
        self.categories = categories
    }

    func entry(named name: String) -> Entry? {
        byName[name]
    }

    /// Emojis whose name or an alias contains `query`: exact matches first, then prefix
    /// matches, then the rest, each in catalog order.
    func search(_ query: String, limit: Int = 400) -> [Entry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        var exact: [Entry] = []
        var prefix: [Entry] = []
        var contains: [Entry] = []
        for (index, terms) in searchTerms.enumerated() {
            if terms.contains(query) {
                exact.append(entries[index])
            } else if terms.contains(where: { $0.hasPrefix(query) }) {
                prefix.append(entries[index])
            } else if terms.contains(where: { $0.contains(query) }) {
                contains.append(entries[index])
            }
        }
        return Array((exact + prefix + contains).prefix(limit))
    }
}
