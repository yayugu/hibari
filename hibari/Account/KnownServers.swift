import Foundation

/// A server the sign-in screen suggests, from KnownServers.json: the servers on
/// join.misskey.page (https://instanceapp.misskey.page/instances.json) with 5 or more daily
/// users (`dru15`), most used first. A few are left out for one reason or another.
struct KnownServer: Decodable, Hashable, Sendable {
    let domain: String
    let name: String
}

enum KnownServers {
    static let all: [KnownServer] = {
        guard let url = Bundle.main.url(forResource: "KnownServers", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let servers = try? JSONDecoder().decode([KnownServer].self, from: data)
        else { return [] }
        return servers
    }()

    /// The part of what the user typed that names the server: `@alice@Misskey.io` and
    /// `https://misskey.io/notes` both give `misskey.io`. Unlike `ServerAddress` it takes
    /// half-typed input as it is.
    static func query(from input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
        } else if let at = text.lastIndex(of: "@") {
            text = String(text[text.index(after: at)...])
        }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        return text
    }

    /// What the user typed before the server (`@alice@`, `https://`), kept when a suggestion
    /// replaces the rest.
    static func prefix(of input: String) -> String {
        let text = input.drop { $0.isWhitespace }
        if let scheme = text.range(of: "://") { return String(text[..<scheme.upperBound]) }
        if let at = text.lastIndex(of: "@") { return String(text[...at]) }
        return ""
    }

    struct Match: Hashable, Sendable {
        let server: KnownServer
        /// What matched the query, to show in bold.
        let domainRange: Range<String.Index>?
        let nameRange: Range<String.Index>?
    }

    struct Suggestions: Sendable {
        /// The server the query names exactly, if it is one of `all`; it also leads `matches`.
        let exact: KnownServer?
        let matches: [Match]
    }

    /// All servers for an empty query; otherwise the one named exactly, then those with a
    /// part of the domain starting with the query, then those with the query in their name.
    static func suggestions(for input: String, in servers: [KnownServer] = all) -> Suggestions {
        let query = query(from: input)
        guard !query.isEmpty else {
            return Suggestions(exact: nil, matches: servers.map { Match(server: $0, domainRange: nil, nameRange: nil) })
        }
        var exact: Match?
        var byDomain: [Match] = []
        var byName: [Match] = []
        for server in servers {
            let domain = server.domain
            if domain == query {
                exact = Match(server: server, domainRange: domain.startIndex..<domain.endIndex, nameRange: nil)
            } else if let range = labelPrefix(query, in: domain) {
                byDomain.append(Match(server: server, domainRange: range, nameRange: nil))
            } else if let range = server.name.range(of: query, options: [.caseInsensitive, .widthInsensitive]) {
                byName.append(Match(server: server, domainRange: nil, nameRange: range))
            }
        }
        return Suggestions(exact: exact?.server, matches: (exact.map { [$0] } ?? []) + byDomain + byName)
    }

    /// Where `query` starts one of the dot-separated parts of `domain` (`design` in
    /// `misskey.design`); a query with dots of its own can match across them.
    private static func labelPrefix(_ query: String, in domain: String) -> Range<String.Index>? {
        var start = domain.startIndex
        while true {
            if domain[start...].hasPrefix(query) {
                return start..<domain.index(start, offsetBy: query.count)
            }
            guard let dot = domain[start...].firstIndex(of: ".") else { return nil }
            start = domain.index(after: dot)
        }
    }
}
