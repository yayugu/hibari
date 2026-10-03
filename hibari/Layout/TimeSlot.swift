import CoreGraphics
import CoreText
import Foundation

struct TimeSlot: Sendable {
    enum Kind: Hashable, Sendable {
        /// Time since the date, always written in the given style.
        case since(Date, ElapsedStyle)
        /// Time left until the date: "残り2日", then "終了済み".
        case until(Date)
    }

    let kind: Kind
    /// Drawn before the time, e.g. " · ".
    let prefix: String
    /// Top-left of the label, in cell coordinates.
    let origin: CGPoint
    let reservedWidth: CGFloat
    let height: CGFloat
    /// Baseline, from the top.
    let baseline: CGFloat
    let fontSize: CGFloat
    let color: ColorRole

    func text(at now: Date) -> String {
        switch kind {
        case .since(let date, let style):
            return prefix + RelativeTime.format(date, now: now, style: style)
        case .until(let date):
            let remaining = date.timeIntervalSince(now)
            return prefix + (remaining <= 0 ? "終了済み" : "残り\(RelativeTime.duration(remaining))")
        }
    }

    /// When `text(at:)` changes next.
    func nextChange(after now: Date) -> Date {
        switch kind {
        case .since(let date, let style):
            return RelativeTime.nextChange(date, now: now, style: style)
        case .until(let date):
            let wait = RelativeTime.durationNextChange(date.timeIntervalSince(now))
            return wait.isFinite ? now.addingTimeInterval(wait) : .distantFuture
        }
    }

    func labelRequest(at now: Date, context: LayoutContext) -> TimeLabelRequest {
        TimeLabelRequest(text: text(at: now), fontSize: fontSize, color: color, style: context.style,
                         height: height, baseline: baseline, scale: context.displayScale)
    }

    static func font(size: CGFloat) -> CTFont {
        Typography.tabularDigits(Typography.system(size))
    }

    enum Labels: Hashable, Sendable {
        case elapsed(ElapsedStyle)
        case remaining

        fileprivate var widest: [String] {
            switch self {
            case .elapsed(.relative): ["00秒", "00分", "00時間", "00日"]
            case .elapsed(.date): ["00月00日"]
            case .elapsed(.dateWithYear): ["0000年00月00日"]
            case .remaining: ["残り000日", "残り00時間", "残り00分", "終了済み"]
            }
        }
    }

    private struct WidthKey: Hashable {
        let labels: Labels
        let prefix: String
        let fontSize: CGFloat
    }

    private static let widths = Locked<[WidthKey: CGFloat]>([:])

    static func reservedWidth(for labels: Labels, prefix: String, fontSize: CGFloat) -> CGFloat {
        let key = WidthKey(labels: labels, prefix: prefix, fontSize: fontSize)
        if let hit = widths.withLock({ $0[key] }) { return hit }
        let font = font(size: fontSize)
        let width = labels.widest.map { label in
            TextLayout.width(of: NSAttributedString(string: prefix + label, attributes: [TextAttribute.font: font]))
        }.max()?.rounded(.up) ?? 0
        widths.withLock { $0[key] = width }
        return width
    }
}

struct TimeStyles: Hashable, Sendable {
    let created: ElapsedStyle
    let quoted: ElapsedStyle?
    /// The note's poll has ended: it takes no more votes.
    let pollClosed: Bool

    init(for item: TimelineItem, now: Date) {
        switch item.content {
        case .note(let outer):
            let note = outer.displayedNote
            created = RelativeTime.style(for: note.createdAt, now: now)
            quoted = note.renote.map { RelativeTime.style(for: $0.createdAt, now: now) }
            pollClosed = note.poll?.isClosed(at: now) ?? false
        case .notification(let notification):
            created = RelativeTime.style(for: notification.createdAt, now: now)
            quoted = nil
            pollClosed = false
        }
    }
}
