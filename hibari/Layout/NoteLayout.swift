import CoreGraphics
import Foundation
import Synchronization

enum MediaOverlay: Hashable, Sendable {
    case play
    case gif
    case sensitive
    case more(Int)
}

struct CornerMask: OptionSet, Hashable, Sendable {
    let rawValue: UInt8
    static let topLeft = CornerMask(rawValue: 1)
    static let topRight = CornerMask(rawValue: 2)
    static let bottomLeft = CornerMask(rawValue: 4)
    static let bottomRight = CornerMask(rawValue: 8)
    static let all: CornerMask = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

enum MediaOwner: UInt8, Hashable, Sendable {
    case note
    case quote
}

/// A piece of media in a cell: its note and its index in that note's `visualFiles`.
struct MediaRef: Hashable, Sendable {
    let owner: MediaOwner
    let index: Int
}

/// An image layer in the cell. `request` is nil when the media is hidden (sensitive)
/// or has no preview; the blurhash placeholder is shown instead.
struct ImageSlot: Sendable {
    let frame: CGRect
    let request: ImageRequest?
    let blurhash: String?
    let cornerRadius: CGFloat
    let corners: CornerMask
    let overlay: MediaOverlay?
    /// nil for avatars.
    var media: MediaRef? = nil
}

enum NoteTapAction: Hashable, Sendable {
    case media(MediaRef)
    case revealSensitive
    case toggleCW
    case expandText
    /// The poll choice at this index.
    case vote(Int)
    /// "結果を見る" / "投票する" under a poll the account can vote in.
    case togglePollResults
    case quote
    /// A reaction chip (its key in `note.reactions`).
    case reaction(String)
    case reply
    case renote
    case react
    case bookmark
    case share
    case more
    /// A link in the text: a URL, `mention:@user@host` or `hashtag:tag`.
    case link(String)
    /// Opens the profile of the user with this id (the note's author, the renoter or the
    /// user replied to).
    case user(String)
}

/// A tappable area, in cell coordinates.
struct TapTarget: Sendable {
    let frame: CGRect
    let action: NoteTapAction
}

struct Decoration: Sendable {
    let frame: CGRect
    let cornerRadius: CGFloat
    let border: ColorRole
}

struct NoteLayout: Sendable {
    let key: LayoutKey
    /// Unique per computed layout. Two layouts can share a key (one computed before an
    /// emoji size was known, one after), so bitmaps are cached by this instead.
    let serial: UInt64
    let height: CGFloat
    let blocks: [RasterBlock]
    let images: [ImageSlot]
    let decorations: [Decoration]
    let timeSlots: [TimeSlot]
    let accessibility: AccessibilityText
    /// Custom emojis laid out with a guessed (square) size because theirs was not known.
    let provisionalEmojis: Set<String>
    /// The link whose card is left out because its preview was not known.
    let pendingLinkPreview: String?
    /// Tappable parts, later ones on top.
    let targets: [TapTarget]
    /// Thread lines between avatars (filled with `ColorRole.border`).
    let connectors: [CGRect]
    /// False when a thread line continues into the next note.
    let showsSeparator: Bool

    private static let serials = Atomic<UInt64>(0)

    init(key: LayoutKey, height: CGFloat, blocks: [RasterBlock], images: [ImageSlot], decorations: [Decoration],
         timeSlots: [TimeSlot], accessibility: AccessibilityText, provisionalEmojis: Set<String>,
         pendingLinkPreview: String? = nil, targets: [TapTarget] = [], connectors: [CGRect] = [],
         showsSeparator: Bool = true) {
        self.key = key
        serial = Self.serials.add(1, ordering: .relaxed).newValue
        self.height = height
        self.blocks = blocks
        self.images = images
        self.decorations = decorations
        self.timeSlots = timeSlots
        self.accessibility = accessibility
        self.provisionalEmojis = provisionalEmojis
        self.pendingLinkPreview = pendingLinkPreview
        self.targets = targets
        self.connectors = connectors
        self.showsSeparator = showsSeparator
    }

    /// What a tap at `point` (cell coordinates) does; nil for the note itself.
    func action(at point: CGPoint) -> NoteTapAction? {
        targets.last { $0.frame.contains(point) }?.action
    }

    /// Where the icon of the button `action` (one of the action bar's) is drawn, in cell
    /// coordinates.
    func iconFrame(of action: NoteTapAction) -> CGRect? {
        guard let target = targets.last(where: { $0.action == action }) else { return nil }
        for block in blocks where block.frame.intersects(target.frame) {
            for case .icon(_, let rect, _) in block.ops {
                let frame = rect.offsetBy(dx: block.frame.minX, dy: block.frame.minY)
                if target.frame.contains(frame) && abs(frame.midY - target.frame.midY) < 1 { return frame }
            }
        }
        return nil
    }

    func slotIndex(of media: MediaRef) -> Int? {
        images.firstIndex { $0.media == media }
    }

    var imageRequests: [ImageRequest] { images.compactMap(\.request) }

    func timeLabelRequests(at now: Date) -> [TimeLabelRequest] {
        timeSlots.map { $0.labelRequest(at: now, context: key.context) }
    }

    var blurhashes: [String] { images.compactMap(\.blurhash) }

    var emojiRequests: [ImageRequest] {
        var requests: [ImageRequest] = []
        for block in blocks {
            for op in block.ops {
                switch op {
                case .text(let text, _):
                    requests += text.emojis.map { Self.emojiRequest($0.url, $0.rect.size, key.context.displayScale) }
                case .emoji(let url, let rect):
                    requests.append(Self.emojiRequest(url, rect.size, key.context.displayScale))
                default:
                    break
                }
            }
        }
        return requests
    }

    static func emojiRequest(_ url: String, _ size: CGSize, _ scale: CGFloat) -> ImageRequest {
        ImageRequest(url: url, size: size, scale: scale, mode: .aspectFit)
    }
}

/// What VoiceOver reads for a note: `beforeTime`, the relative time of `date`, then
/// `afterTime`. The time is filled in when read, like the visible one.
struct AccessibilityText: Sendable {
    let beforeTime: String
    let date: Date
    let afterTime: String

    func label(at now: Date) -> String {
        let head = "\(beforeTime) \(RelativeTime.format(date, now: now))"
        return afterTime.isEmpty ? head : "\(head)、\(afterTime)"
    }
}

struct TimelineItem: Sendable {
    enum Content: Sendable {
        case note(Note)
        /// A notification shown as a row saying what happened. Those shown as their note
        /// (mentions, replies, ...) are `.note`, under the notification's id.
        case notification(MisskeyNotification)
    }

    /// The note's id, or the notification's for a notification.
    let id: String
    let content: Content
    let contentHash: Int
    var state: NoteDisplayState

    /// The note the cell shows, nil for notification rows.
    var note: Note? {
        if case .note(let note) = content { return note }
        return nil
    }

    var notification: MisskeyNotification? {
        if case .notification(let notification) = content { return notification }
        return nil
    }

    /// What a list shows only once (`TimelineEntries`): the note shown, the renoted one for
    /// a renote. nil for notifications, also those shown as their note, and for the
    /// account's own renotes: they always show.
    func shownNoteID(accountUserID: String?) -> String? {
        guard let note, note.id == id else { return nil }
        if note.isPureRenote, note.user.id == accountUserID { return nil }
        return note.displayedNote.id
    }

    init(note: Note, state: NoteDisplayState = NoteDisplayState()) {
        self.init(id: note.id, note: note, state: state)
    }

    /// A note under another id (a notification's).
    init(id: String, note: Note, state: NoteDisplayState = NoteDisplayState()) {
        self.id = id
        content = .note(note)
        self.state = state
        var hasher = Hasher()
        Self.combine(note, into: &hasher)
        contentHash = hasher.finalize()
    }

    init(notification: MisskeyNotification) {
        id = notification.id
        content = .notification(notification)
        state = NoteDisplayState()
        var hasher = Hasher()
        hasher.combine(notification.id)
        for user in notification.users {
            hasher.combine(user.id)
            hasher.combine(user.name)
            hasher.combine(user.avatarUrl)
        }
        if case .reactions(let reactions) = notification.kind {
            for reaction in reactions { hasher.combine(reaction.reaction) }
        }
        if let note = notification.subjectNote {
            Self.combine(note, into: &hasher)
        }
        contentHash = hasher.finalize()
    }

    /// Whether deleting the note `noteID` takes this entry with it: the note itself, and
    /// its renotes, quotes and replies (Misskey deletes those too), or a notification about
    /// it.
    func isGone(afterDeleting noteID: String) -> Bool {
        if id == noteID { return true }
        let note = note ?? notification?.subjectNote
        guard let note else { return false }
        return note.id == noteID || note.renoteId == noteID || note.replyId == noteID
    }

    /// Whether the entry is one Misskey leaves out once the account mutes or blocks the
    /// user `userID` (its `isUserRelated`): their note, a reply to them, a renote or quote
    /// of theirs, or a notification of what only they did.
    func involves(user userID: String) -> Bool {
        switch content {
        case .note(let note):
            return [note.user, note.reply?.user, note.renote?.user].contains { $0?.id == userID }
        case .notification(let notification):
            let users = notification.users
            return !users.isEmpty && users.allSatisfy { $0.id == userID }
        }
    }

    /// With `change` applied to the note it shows, nil when that is not affected.
    func applying(_ change: some NoteChange) -> TimelineItem? {
        guard let note, note.contains(noteID: change.noteID) else { return nil }
        let changed = note.applying(change)
        return changed === note ? nil : TimelineItem(id: id, note: changed, state: state)
    }

    private static func combine(_ note: Note, into hasher: inout Hasher) {
        hasher.combine(note.id)
        hasher.combine(note.text)
        hasher.combine(note.cw)
        hasher.combine(note.user.name)
        hasher.combine(note.user.avatarUrl)
        hasher.combine(note.renoteCount)
        hasher.combine(note.repliesCount)
        hasher.combine(note.myReaction)
        hasher.combine(note.isRenotedByMe)
        hasher.combine(note.isBookmarked)
        for (key, count) in note.reactions.sorted(by: { $0.key < $1.key }) {
            hasher.combine(key)
            hasher.combine(count)
        }
        for file in note.files {
            hasher.combine(file.id)
            hasher.combine(file.isSensitive)
        }
        if let poll = note.poll {
            for choice in poll.choices {
                hasher.combine(choice.votes)
                hasher.combine(choice.isVoted)
            }
        }
        hasher.combine(note.reply?.user.username)
        if let renote = note.renote {
            combine(renote, into: &hasher)
        }
    }
}
