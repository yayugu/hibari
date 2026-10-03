import CoreGraphics

enum Icon: UInt8, Hashable, Sendable {
    case reply, renote, reaction, reacted, like, liked, bookmark, bookmarked, share
    case renoteBadge, visibilityHome, visibilityFollowers, visibilitySpecified, file, check
    case person, poll, clock, bell, medal

    var assetName: String? {
        switch self {
        case .reply: "NoteReply"
        case .renote, .renoteBadge: "NoteRenote"
        case .reaction: "NoteReact"
        case .reacted: "NoteReacted"
        case .like: "NoteLike"
        case .liked: "NoteLiked"
        case .bookmark: "NoteBookmark"
        case .bookmarked: "NoteBookmarked"
        case .share: "NoteShare"
        case .visibilityHome: "VisibilityHome"
        case .visibilityFollowers: "VisibilityFollowers"
        case .visibilitySpecified: "VisibilitySpecified"
        default: nil
        }
    }

    var symbolName: String {
        switch self {
        case .reply: "bubble.left"
        case .renote, .renoteBadge: "arrow.2.squarepath"
        case .reaction: "plus"
        case .reacted: "minus"
        case .like: "heart"
        case .liked: "heart.fill"
        case .bookmark: "bookmark"
        case .bookmarked: "bookmark.fill"
        case .share: "square.and.arrow.up"
        case .visibilityHome: "house"
        case .visibilityFollowers: "lock"
        case .visibilitySpecified: "envelope"
        case .file: "doc"
        case .check: "checkmark.circle.fill"
        case .person: "person.fill"
        case .poll: "chart.bar.fill"
        case .clock: "clock.fill"
        case .bell: "bell.fill"
        case .medal: "medal.fill"
        }
    }

    var weight: Icon.Weight {
        switch self {
        case .renoteBadge, .check: .bold
        default: .regular
        }
    }

    enum Weight: UInt8, Hashable, Sendable { case regular, bold }

    static func reactButton(for note: Note) -> (icon: Icon, color: ColorRole, label: String) {
        let reacted = note.myReaction != nil
        if note.isLikeOnly {
            return reacted ? (.liked, .reaction, "いいねを取り消す") : (.like, .secondaryText, "いいね")
        }
        return reacted ? (.reacted, .accent, "リアクションを取り消す") : (.reaction, .secondaryText, "リアクション")
    }
}

/// Drawing commands for one rasterized block, in block coordinates (top-left origin, points).
enum DrawOp: Sendable {
    case text(TextLayout, origin: CGPoint)
    case emoji(url: String, rect: CGRect)
    case icon(Icon, rect: CGRect, color: ColorRole)
    case roundedRect(CGRect, radius: CGFloat, fill: ColorRole?, stroke: ColorRole?)
    /// An achievement's badge without its emoji (see `Medal`).
    case medal(Achievement.Frame, background: (bottom: UInt32, top: UInt32)?, rect: CGRect)
}

struct RasterBlock: Sendable {
    let frame: CGRect
    let ops: [DrawOp]
}
