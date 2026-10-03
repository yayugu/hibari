import Foundation

/// One of the achievements Misskey itself defines, with its text and badge as Misskey's
/// web client shows them (`catalog`, generated from its source). A server's own
/// achievements are not in it.
struct Achievement: Sendable {
    /// The ring around the badge.
    enum Frame: Sendable {
        case bronze, silver, gold, platinum
    }

    let title: String
    let description: String
    let flavor: String?
    /// The Fluent Emoji in the badge: the server serves it at `/fluent-emoji/<emoji>.png`.
    let emoji: String
    /// The badge's background, bottom to top, as 0xRRGGBB (nil: the frame's).
    let background: (bottom: UInt32, top: UInt32)?
    let frame: Frame

    static func named(_ id: String) -> Achievement? {
        catalog[id]
    }

    func emojiURL(server: URL) -> String {
        server.appending(path: "fluent-emoji/\(emoji).png").absoluteString
    }
}
