import Foundation

indirect enum MFMNode: Equatable, Sendable {
    case text(String)
    case bold([MFMNode])
    case italic([MFMNode])
    case strike([MFMNode])
    case small([MFMNode])
    case center([MFMNode])
    case quote([MFMNode])
    case inlineCode(String)
    case codeBlock(String)
    case mention(username: String, host: String?)
    case hashtag(String)
    case url(String)
    case link(label: [MFMNode], url: String)
    case emoji(String)
    case fn(name: String, args: [String: String], children: [MFMNode])
}

enum MFMParser {
    static func parse(_ text: String) -> [MFMNode] {
        var scanner = MFMScanner(text, simple: false)
        return scanner.parseAll()
    }

    /// Text + custom emoji only, for display names (like mfm-js `parseSimple`).
    static func parseSimple(_ text: String) -> [MFMNode] {
        var scanner = MFMScanner(text, simple: true)
        return scanner.parseAll()
    }

    /// Where the mentions, hashtags, URLs, links and custom emojis of full MFM are in
    /// `text`, for coloring the text being written (the same rules as the timeline's).
    /// Leaves out what is inside `>` quotes.
    static func highlights(in text: String) -> [MFMHighlight] {
        let text = text.contains("\r") ? text.replacingOccurrences(of: "\r\n", with: " \n") : text
        var scanner = MFMScanner(text, simple: false)
        scanner.recordsHighlights = true
        _ = scanner.parseInline(until: nil)
        guard !scanner.exhausted else { return [] }
        var utf16: [Int] = [0]
        utf16.reserveCapacity(text.unicodeScalars.count + 1)
        for scalar in text.unicodeScalars {
            utf16.append(utf16[utf16.count - 1] + scalar.utf16.count)
        }
        return scanner.highlights.map {
            MFMHighlight(kind: $0.kind, range: utf16[$0.range.lowerBound]..<utf16[$0.range.upperBound])
        }
    }
}

struct MFMHighlight: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case mention
        case hashtag
        case url
        /// `[label](url)` or `?[label](url)`, all of it.
        case link
        /// `:name:`
        case emoji(String)
    }

    let kind: Kind
    /// UTF-16 offsets into the text.
    let range: Range<Int>
}

private struct MFMScanner {
    private let s: [Unicode.Scalar]
    private var i = 0
    private let simple: Bool
    private var depth: Int
    private var failed = Set<Int>()
    private var quotes: [Int: (node: MFMNode, end: Int)] = [:]
    private var budget: Int
    var recordsHighlights = false
    private(set) var highlights: [(kind: MFMHighlight.Kind, range: Range<Int>)] = []

    private static let nestLimit = 20
    private static let budgetPerScalar = 64
    private static let maxBudget = 1_000_000

    private enum Construct: Int {
        case bold, strike, center, tagBold, tagItalic, tagStrike, tagSmall, function, link
    }

    init(_ text: String, simple: Bool, depth: Int = 0, budget: Int? = nil) {
        let normalized = text.contains("\r") ? text.replacingOccurrences(of: "\r\n", with: "\n") : text
        s = Array(normalized.unicodeScalars)
        self.simple = simple
        self.depth = depth
        self.budget = budget ?? min(1000 + s.count * Self.budgetPerScalar, Self.maxBudget)
    }

    var exhausted: Bool { budget < 0 }

    mutating func parseAll() -> [MFMNode] {
        let nodes = parseInline(until: nil).nodes
        return exhausted ? [.text(string(0..<s.count))] : nodes
    }

    mutating func parseInline(until terminator: String?, stopAtNewline: Bool = false) -> (nodes: [MFMNode], closed: Bool) {
        let term = terminator.map { Array($0.unicodeScalars) }
        var nodes: [MFMNode] = []
        var buffer = String.UnicodeScalarView()

        func flush() {
            if !buffer.isEmpty {
                if case .text(let previous)? = nodes.last {
                    nodes[nodes.count - 1] = .text(previous + String(buffer))
                } else {
                    nodes.append(.text(String(buffer)))
                }
                buffer = String.UnicodeScalarView()
            }
        }

        while i < s.count {
            budget -= 1
            if exhausted { return (nodes, false) }
            if let term, matches(term, at: i) {
                flush()
                i += term.count
                return (nodes, true)
            }
            if stopAtNewline && s[i] == "\n" {
                break
            }
            if let parsed = parseSpecial() {
                flush()
                nodes.append(contentsOf: parsed)
                continue
            }
            buffer.append(s[i])
            i += 1
        }
        flush()
        return (nodes, term == nil)
    }

    private mutating func parseSpecial() -> [MFMNode]? {
        let c = s[i]
        if simple {
            return c == ":" ? parseEmoji().map { [$0] } : nil
        }
        let start = i
        let highlightCount = highlights.count
        let result: MFMNode?
        switch c {
        case "`":
            result = atLineStart && matches("```") ? parseCodeBlock() : parseInlineCode()
        case ">":
            result = atLineStart ? parseQuote() : nil
        case "<":
            result = parseTag()
        case "$":
            result = matches("$[") ? parseFunction() : nil
        case "*":
            result = matches("**") ? parseNested(.bold, open: "**", close: "**", wrap: MFMNode.bold) : parseAsteriskItalic()
        case "~":
            result = matches("~~")
                ? parseNested(.strike, open: "~~", close: "~~", stopAtNewline: true, wrap: MFMNode.strike) : nil
        case "\\":
            result = matches("\\(") ? parseDelimitedRaw(open: "\\(", close: "\\)").map(MFMNode.inlineCode) : nil
        case ":":
            result = parseEmoji()
        case "@":
            result = parseMention()
        case "#":
            result = parseHashtag()
        case "h":
            result = parseURL()
        case "[":
            result = parseLink(prefixLength: 0)
        case "?":
            result = matches("?[") ? parseLink(prefixLength: 1) : nil
        default:
            result = nil
        }
        if let result {
            if recordsHighlights, let kind = Self.highlightKind(of: result) {
                highlights.append((kind, start..<i))
            }
        } else {
            i = start
            highlights.removeSubrange(highlightCount...)
        }
        return result.map { [$0] }
    }

    private static func highlightKind(of node: MFMNode) -> MFMHighlight.Kind? {
        switch node {
        case .mention: .mention
        case .hashtag: .hashtag
        case .url: .url
        case .link: .link
        case .emoji(let name): .emoji(name)
        default: nil
        }
    }

    private var atLineStart: Bool { i == 0 || s[i - 1] == "\n" }

    private func matches(_ literal: String, at index: Int? = nil) -> Bool {
        var j = index ?? i
        for scalar in literal.unicodeScalars {
            guard j < s.count, s[j] == scalar else { return false }
            j += 1
        }
        return true
    }

    private func matches(_ literal: [Unicode.Scalar], at index: Int) -> Bool {
        guard index + literal.count <= s.count else { return false }
        for (offset, scalar) in literal.enumerated() where s[index + offset] != scalar {
            return false
        }
        return true
    }

    private static func isAlnum(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: true
        default: false
        }
    }

    private func previousIsAlnum() -> Bool {
        i > 0 && Self.isAlnum(s[i - 1])
    }

    private func string(_ range: Range<Int>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: s[range])
        return String(view)
    }

    private func failureKey(_ construct: Construct, at position: Int) -> Int {
        position * 16 + construct.rawValue
    }

    private mutating func parseNested(
        _ construct: Construct,
        open: String,
        close: String,
        stopAtNewline: Bool = false,
        wrap: ([MFMNode]) -> MFMNode
    ) -> MFMNode? {
        let key = failureKey(construct, at: i)
        guard depth < Self.nestLimit, !failed.contains(key) else { return nil }
        i += open.unicodeScalars.count
        depth += 1
        let (children, closed) = parseInline(until: close, stopAtNewline: stopAtNewline)
        depth -= 1
        guard closed, !children.isEmpty else {
            failed.insert(key)
            return nil
        }
        return wrap(children)
    }

    private mutating func parseDelimitedRaw(open: String, close: String, allowNewline: Bool = false) -> String? {
        let closeScalars = Array(close.unicodeScalars)
        var j = i + open.unicodeScalars.count
        let contentStart = j
        defer { budget -= j - contentStart }
        while j < s.count {
            if matches(closeScalars, at: j) {
                guard j > contentStart else { return nil }
                i = j + closeScalars.count
                return string(contentStart..<j)
            }
            if !allowNewline && s[j] == "\n" { return nil }
            j += 1
        }
        return nil
    }

    private mutating func parseCodeBlock() -> MFMNode? {
        var j = i + 3
        while j < s.count && s[j] != "\n" { j += 1 }
        guard j < s.count else { return nil }
        let contentStart = j + 1
        var k = contentStart
        defer { budget -= k - contentStart }
        while k < s.count {
            if s[k] == "\n" && matches("```", at: k + 1) {
                let content = string(contentStart..<k)
                var end = k + 4
                while end < s.count && s[end] != "\n" { end += 1 }
                if end < s.count { end += 1 }
                i = end
                return .codeBlock(content)
            }
            k += 1
        }
        return nil
    }

    private mutating func parseQuote() -> MFMNode? {
        guard depth < Self.nestLimit else { return nil }
        if let quote = quotes[i] {
            i = quote.end
            return quote.node
        }
        let start = i
        var lines: [String] = []
        while i < s.count && atLineStart && s[i] == ">" {
            i += 1
            if i < s.count && s[i] == " " { i += 1 }
            let lineStart = i
            while i < s.count && s[i] != "\n" { i += 1 }
            lines.append(string(lineStart..<i))
            if i < s.count { i += 1 }
        }
        guard !lines.isEmpty else { return nil }
        var inner = MFMScanner(lines.joined(separator: "\n"), simple: false, depth: depth + 1, budget: budget)
        let node = MFMNode.quote(inner.parseInline(until: nil).nodes)
        budget = inner.budget
        quotes[start] = (node, i)
        return node
    }

    private mutating func parseTag() -> MFMNode? {
        if matches("<center>") {
            return parseNested(.center, open: "<center>", close: "</center>", wrap: MFMNode.center)
        }
        if matches("<b>") { return parseNested(.tagBold, open: "<b>", close: "</b>", wrap: MFMNode.bold) }
        if matches("<i>") { return parseNested(.tagItalic, open: "<i>", close: "</i>", wrap: MFMNode.italic) }
        if matches("<s>") { return parseNested(.tagStrike, open: "<s>", close: "</s>", wrap: MFMNode.strike) }
        if matches("<small>") { return parseNested(.tagSmall, open: "<small>", close: "</small>", wrap: MFMNode.small) }
        if matches("<plain>") {
            return parseDelimitedRaw(open: "<plain>", close: "</plain>", allowNewline: true).map(MFMNode.text)
        }
        if matches("<http://") || matches("<https://") {
            guard let raw = parseDelimitedRaw(open: "<", close: ">"),
                  !raw.unicodeScalars.contains(where: { $0.properties.isWhitespace })
            else { return nil }
            return .url(raw)
        }
        return nil
    }

    private mutating func parseFunction() -> MFMNode? {
        let key = failureKey(.function, at: i)
        guard depth < Self.nestLimit, !failed.contains(key) else { return nil }
        var j = i + 2
        let nameStart = j
        while j < s.count && (Self.isAlnum(s[j]) || s[j] == "_") { j += 1 }
        let nameEnd = j
        var argsRange: Range<Int>?
        if j < s.count && s[j] == "." {
            j += 1
            let argsStart = j
            while j < s.count && !s[j].properties.isWhitespace && s[j] != "]" { j += 1 }
            argsRange = argsStart..<j
        }
        budget -= j - i
        guard nameEnd > nameStart, j < s.count, s[j] == " " || s[j] == "\n" || s[j] == "\t" else {
            failed.insert(key)
            return nil
        }
        let name = string(nameStart..<nameEnd)
        let argsText = argsRange.map { string($0) } ?? ""
        var args: [String: String] = [:]
        for part in argsText.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard !kv[0].isEmpty else { continue }
            args[String(kv[0])] = kv.count > 1 ? String(kv[1]) : ""
        }
        i = j + 1
        depth += 1
        let (children, closed) = parseInline(until: "]")
        depth -= 1
        guard closed else {
            failed.insert(key)
            return nil
        }
        return .fn(name: name, args: args, children: children)
    }

    private mutating func parseAsteriskItalic() -> MFMNode? {
        guard !previousIsAlnum() else { return nil }
        var j = i + 1
        while j < s.count && (Self.isAlnum(s[j]) || s[j] == " " || s[j] == "\t") { j += 1 }
        guard j > i + 1, j < s.count, s[j] == "*" else { return nil }
        let content = string((i + 1)..<j)
        i = j + 1
        return .italic([.text(content)])
    }

    private mutating func parseInlineCode() -> MFMNode? {
        parseDelimitedRaw(open: "`", close: "`").map(MFMNode.inlineCode)
    }

    /// Unlike mentions and hashtags, a letter or digit may come before (`abc:ok:`, as in
    /// mfm-js); only one right after makes it text (`:ok:abc`, `12:30:45`).
    private mutating func parseEmoji() -> MFMNode? {
        var j = i + 1
        while j < s.count && (Self.isAlnum(s[j]) || s[j] == "_" || s[j] == "+" || s[j] == "-") { j += 1 }
        guard j > i + 1, j < s.count, s[j] == ":" else { return nil }
        if j + 1 < s.count && Self.isAlnum(s[j + 1]) { return nil }
        let name = string((i + 1)..<j)
        i = j + 1
        return .emoji(name)
    }

    private mutating func parseMention() -> MFMNode? {
        guard !previousIsAlnum() else { return nil }
        var j = i + 1
        let userStart = j
        while j < s.count && (Self.isAlnum(s[j]) || s[j] == "_" || s[j] == "-") { j += 1 }
        while j > userStart && s[j - 1] == "-" { j -= 1 }
        guard j > userStart, s[userStart] != "-" else { return nil }
        let username = string(userStart..<j)
        var host: String?
        if j < s.count && s[j] == "@" {
            var k = j + 1
            let hostStart = k
            while k < s.count && (Self.isAlnum(s[k]) || s[k] == "_" || s[k] == "." || s[k] == "-") { k += 1 }
            while k > hostStart && (s[k - 1] == "." || s[k - 1] == "-") { k -= 1 }
            if k > hostStart {
                host = string(hostStart..<k)
                j = k
            }
        }
        i = j
        return .mention(username: username, host: host)
    }

    private static let hashtagStops: Set<Unicode.Scalar> = Set(".,!?'\"#:/[]【】()「」（）<>".unicodeScalars)

    private mutating func parseHashtag() -> MFMNode? {
        guard !previousIsAlnum() else { return nil }
        var j = i + 1
        while j < s.count && !s[j].properties.isWhitespace && !Self.hashtagStops.contains(s[j]) { j += 1 }
        guard j > i + 1 else { return nil }
        let tag = string((i + 1)..<j)
        guard !tag.unicodeScalars.allSatisfy({ (0x30...0x39).contains($0.value) }) else { return nil }
        i = j
        return .hashtag(tag)
    }

    private static let urlChars: Set<Unicode.Scalar> = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,_/:%#@$&?!~=+-;*'".unicodeScalars
    )

    private mutating func parseURL() -> MFMNode? {
        let schemeLength: Int
        if matches("https://") {
            schemeLength = 8
        } else if matches("http://") {
            schemeLength = 7
        } else {
            return nil
        }
        var j = i + schemeLength
        var parens = 0
        var brackets = 0
        while j < s.count {
            let c = s[j]
            if c == "(" {
                parens += 1
            } else if c == ")" {
                guard parens > 0 else { break }
                parens -= 1
            } else if c == "[" {
                brackets += 1
            } else if c == "]" {
                guard brackets > 0 else { break }
                brackets -= 1
            } else if !Self.urlChars.contains(c) {
                break
            }
            j += 1
        }
        while j > i + schemeLength && (s[j - 1] == "." || s[j - 1] == ",") { j -= 1 }
        guard j > i + schemeLength else { return nil }
        let url = string(i..<j)
        i = j
        return .url(url)
    }

    private mutating func parseLink(prefixLength: Int) -> MFMNode? {
        let key = failureKey(.link, at: i + prefixLength)
        guard depth < Self.nestLimit, !failed.contains(key) else { return nil }
        i += prefixLength + 1
        depth += 1
        let (label, closed) = parseInline(until: "]", stopAtNewline: true)
        depth -= 1
        guard let url = closed && !label.isEmpty ? parseLinkURL() : nil else {
            failed.insert(key)
            return nil
        }
        return .link(label: label, url: url)
    }

    private mutating func parseLinkURL() -> String? {
        guard matches("(https://") || matches("(http://") else { return nil }
        var j = i + 1
        while j < s.count && s[j] != ")" && !s[j].properties.isWhitespace { j += 1 }
        guard j < s.count, s[j] == ")" else { return nil }
        let url = string((i + 1)..<j)
        i = j + 1
        return url
    }
}
