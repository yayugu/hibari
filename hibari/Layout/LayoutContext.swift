import CoreGraphics
import Foundation
import UIKit

struct LayoutMetrics: Hashable, Sendable {
    var contentInsets = Insets(top: 12, left: 12, bottom: 12, right: 12)
    var avatarSize: CGFloat = 44
    var avatarSpacing: CGFloat = 10
    /// Width reserved at the trailing end of the header line for the "…" menu.
    var accessoryWidth: CGFloat = 22
    /// Put body content below the avatar instead of beside it (focused-note style).
    var bodyBelowAvatar = false
    var lineHeightMultiple: CGFloat = 1.32
    var blockSpacing: CGFloat = 10
    var headerSpacing: CGFloat = 2
    var mediaSpacing: CGFloat = 2
    var mediaCornerRadius: CGFloat = 16
    var quotePadding: CGFloat = 12
    var quoteAvatarSize: CGFloat = 20
    var quoteMaxLines = 6
    var bodyCollapseLines = 14
    var bodyCollapsedLines = 10
    var actionBarHeight: CGFloat = 20
    var actionIconSize: CGFloat = 18
    var reactionChipHeight: CGFloat = 28
    var reactionChipSpacing: CGFloat = 6
    var reactionMaxRows = 3

    func actionIconXs(for width: CGFloat) -> [CGFloat] {
        let share = width - actionIconSize
        return [
            0,
            (width * 0.26).rounded(),
            (width * 0.52).rounded(),
            share - actionIconSize - 22,
            share,
        ]
    }

    struct Insets: Hashable, Sendable {
        var top: CGFloat
        var left: CGFloat
        var bottom: CGFloat
        var right: CGFloat
    }
}

struct LayoutContext: Hashable, Sendable {
    var canvasWidth: CGFloat
    var safeAreaLeft: CGFloat = 0
    var safeAreaRight: CGFloat = 0
    var displayScale: CGFloat
    /// Dynamic Type scale of body text (1 at the default size).
    var fontScale: CGFloat
    var style: ThemeStyle
    var metrics = LayoutMetrics()
    var revealsSensitiveMedia: Bool

    var palette: Palette { Palette.palette(for: style) }
}

extension LayoutContext {
    @MainActor
    init(width: CGFloat, safeAreaInsets: UIEdgeInsets, traits: UITraitCollection,
         metrics: LayoutMetrics = LayoutMetrics(), revealsSensitiveMedia: Bool) {
        self.init(
            canvasWidth: width,
            safeAreaLeft: safeAreaInsets.left,
            safeAreaRight: safeAreaInsets.right,
            displayScale: traits.displayScale > 0 ? traits.displayScale : 3,
            fontScale: UIFontMetrics(forTextStyle: .body).scaledValue(for: 100, compatibleWith: traits) / 100,
            style: ThemeStyle(traits.userInterfaceStyle),
            metrics: metrics,
            revealsSensitiveMedia: revealsSensitiveMedia)
    }
}

struct NoteDisplayState: Hashable, Sendable {
    var cwExpanded = false
    var textExpanded = false
    var sensitiveRevealed = false
    var thread: ThreadLinks = []
}

struct ThreadLinks: OptionSet, Hashable, Sendable {
    let rawValue: UInt8
    static let above = ThreadLinks(rawValue: 1)
    static let below = ThreadLinks(rawValue: 2)
}

struct LayoutKey: Hashable, Sendable {
    let noteID: String
    let contentHash: Int
    let state: NoteDisplayState
    let timeStyles: TimeStyles
    let context: LayoutContext

    /// Whether going from `old` to this key changes something that must show right away
    /// (the note's content, its display state, the context), rather than only something
    /// that changes by itself (time styles), which waits until the note is off screen.
    func requiresImmediateRelayout(from old: LayoutKey) -> Bool {
        noteID != old.noteID || contentHash != old.contentHash || state != old.state || context != old.context
    }
}
