import CoreGraphics
import Foundation

/// What the account's server says about a web page (`/url`, Misskey's summaly), for the
/// card under a note that links to it.
struct LinkPreview: Sendable, Equatable {
    /// How the page asks to be shown (its `twitter:card`).
    enum Style: Sendable, Equatable {
        case summary
        case largeImage
    }

    /// The page, after redirects.
    let url: String
    let title: String
    /// Through the server's media proxy, at full size.
    let thumbnail: String?
    /// nil when the page does not say, or the server does not tell (misskey.io).
    let style: Style?
    /// The page plays something (a video).
    let hasPlayer: Bool
    let isSensitive: Bool

    /// The link a note's card is for: its last URL, as on X. None when the note shows media,
    /// a quote or a poll (they take the card's place) or links nothing; links written
    /// `?[label](url)` ask for no preview.
    static func target(of note: Note) -> String? {
        guard note.files.isEmpty, note.renote == nil, note.poll == nil,
              let text = note.text, text.contains("http")
        else { return nil }
        return lastLink(in: MFMParser.parse(text))
    }

    /// `text` without `url` where it begins or ends it (a bare URL, apart from white space),
    /// for a note showing the card for it: as on X, the card stands for it there. Elsewhere
    /// it stays, not to break the sentence around it.
    static func text(_ text: String, showingCardFor url: String) -> String {
        let nodes = MFMParser.parse(text)
        func isBlank(_ node: MFMNode) -> Bool {
            if case .text(let string) = node { return string.allSatisfy(\.isWhitespace) }
            return false
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if nodes.last(where: { !isBlank($0) }) == .url(url), trimmed.hasSuffix(url) {
            return String(trimmed.dropLast(url.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if nodes.first(where: { !isBlank($0) }) == .url(url), trimmed.hasPrefix(url) {
            return String(trimmed.dropFirst(url.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private static func lastLink(in nodes: [MFMNode]) -> String? {
        for node in nodes.reversed() {
            switch node {
            case .url(let url):
                return url
            case .link(_, let url, let silent):
                if !silent { return url }
            case .bold(let children), .italic(let children), .strike(let children), .small(let children),
                 .center(let children), .quote(let children), .fn(_, _, let children):
                if let url = lastLink(in: children) { return url }
            case .text, .inlineCode, .codeBlock, .mention, .hashtag, .emoji:
                break
            }
        }
        return nil
    }

    /// The host shown with the card, without "www.".
    var domain: String {
        let host = URL(string: url)?.host() ?? url
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

extension LinkPreview {
    /// From the body of a `/url` response; nil when it has nothing to show.
    init?(json data: Data) {
        struct Summary: Decodable {
            struct Player: Decodable {
                let url: String?
            }

            let url: String?
            let title: String?
            let thumbnail: String?
            let thumbnailStyle: String?
            let player: Player?
            let sensitive: Bool?
        }

        guard let summary = try? JSONDecoder().decode(Summary.self, from: data),
              let url = summary.url, let title = summary.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty,
              // misskey.io answers a page it could not get with this title instead of an error.
              !title.hasPrefix("Preview not available")
        else { return nil }
        self.url = url
        self.title = title
        thumbnail = summary.thumbnail.map(Self.fullSize)
        style = switch summary.thumbnailStyle {
        case "summary_large_image": .largeImage
        case "summary": .summary
        default: nil
        }
        hasPlayer = summary.player?.url != nil
        isSensitive = summary.sensitive ?? false
    }

    /// The media proxy's URL for an image without `preview`, which makes it serve the
    /// image as it is rather than shrunk to 200px. Misskey's proxy has the image in `url`
    /// (`/proxy/preview.webp?url=...&preview=1`), misskey.io's in the path
    /// (`/preview/host%2Fpath?preview=1`); both take the same flags.
    static func fullSize(_ thumbnail: String) -> String {
        // Percent-encoded as they came: decoding `url` and encoding it again would leave the
        // image's own `&` and `=` unescaped.
        guard var components = URLComponents(string: thumbnail),
              let items = components.percentEncodedQueryItems, items.contains(where: { $0.name == "preview" })
        else { return thumbnail }
        let kept = items.filter { $0.name != "preview" }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.string ?? thumbnail
    }
}

/// What layout shows for a link.
enum LinkPreviewState: Sendable, Equatable {
    /// Not known yet.
    case unknown
    /// No card: the server has no preview of the page.
    case none
    case ready(LinkCard)
}

/// A preview with what layout needs of its image.
struct LinkCard: Sendable, Equatable {
    struct Thumbnail: Sendable, Equatable {
        let url: String
        let pixelSize: CGSize

        /// Big enough to stand across the note: the part the large card shows (cropped to
        /// its shape) at least this wide. Not an icon (summaly falls back to a page's
        /// apple-touch-icon).
        var fillsALargeCard: Bool {
            min(pixelSize.width, pixelSize.height * LinkCardGeometry.aspect) >= 300
        }
    }

    enum Size: Sendable, Equatable {
        /// The image across the note, the title over it (X's `summary_large_image`).
        case large
        /// A square image (or a placeholder) beside the title and the domain (X's `summary`).
        case small
    }

    let preview: LinkPreview
    /// nil when the page has none, or it did not load.
    let thumbnail: Thumbnail?

    /// What the page asks for, if its image can take it. Pages that do not say (all of
    /// them on misskey.io) get the large card for a wide image, and the small one for a
    /// square one (a logo, or what `summary` pages have).
    var size: Size {
        guard let thumbnail, thumbnail.fillsALargeCard else { return .small }
        switch preview.style {
        case .largeImage: return .large
        case .summary: return .small
        case nil: return thumbnail.pixelSize.width >= thumbnail.pixelSize.height * 1.3 ? .large : .small
        }
    }

    /// The image the card shows: none for a page marked sensitive (the small card with a
    /// placeholder), unless the account shows sensitive media.
    func image(revealingSensitiveMedia: Bool) -> Thumbnail? {
        preview.isSensitive && !revealingSensitiveMedia ? nil : thumbnail
    }
}
