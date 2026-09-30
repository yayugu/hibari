import CoreGraphics
import CoreText
import Foundation

extension NoteLayoutBuilder {
    static let notificationAvatarSize: CGFloat = 32
    static let notificationAvatarSpacing: CGFloat = 6
    static let notificationSummaryLines = 2
    static let notificationExcerptLines = 3

    mutating func build(_ notification: MisskeyNotification) -> NoteLayout {
        let leading = context.safeAreaLeft + m.contentInsets.left
        let trailing = context.canvasWidth - context.safeAreaRight - m.contentInsets.right
        let contentX = leading + m.avatarSize + m.avatarSpacing
        let contentWidth = max(40, trailing - contentX)
        let top = m.contentInsets.top
        var y = top

        let users = notification.users
        let avatar = Self.notificationAvatarSize
        if !users.isEmpty {
            avatarRow(notification, users: users, origin: CGPoint(x: contentX, y: y), width: contentWidth)
            y += avatar + 8
        }

        let summary = summaryLine(notification, users: users, width: contentWidth)
        addBlock(CGRect(x: contentX, y: y, width: contentWidth, height: summary.height), summary.ops, time: summary.time)
        let summaryTop = y
        y += summary.height

        if let excerpt = excerpt(of: notification, width: contentWidth) {
            y += 2
            collectsLinks = false
            addBlock(CGRect(x: contentX, y: y, width: contentWidth, height: excerpt.size.height),
                     [.text(excerpt, origin: .zero)])
            collectsLinks = true
            y += excerpt.size.height
        }

        let (icon, role) = Self.icon(for: notification.kind)
        let iconSize = (m.avatarSize * 0.6).rounded()
        let iconCenterY = users.isEmpty ? summaryTop + bodyMetrics.lineHeight / 2 : top + avatar / 2
        addBlock(CGRect(x: leading + m.avatarSize - iconSize, y: iconCenterY - iconSize / 2, width: iconSize,
                        height: iconSize),
                 [.icon(icon, rect: CGRect(x: 0, y: 0, width: iconSize, height: iconSize), color: role)])

        let height = (y + m.contentInsets.bottom).pixelCeil(scale: scale)
        return NoteLayout(
            key: key,
            height: height,
            blocks: blocks,
            images: images,
            decorations: decorations,
            timeSlots: timeSlots,
            accessibility: AccessibilityText(beforeTime: accessibilityBeforeTime.joined(separator: "、"),
                                             date: notification.createdAt,
                                             afterTime: accessibilityAfterTime.joined(separator: "、")),
            provisionalEmojis: sizer.provisional,
            targets: targets)
    }

    private mutating func avatarRow(_ notification: MisskeyNotification, users: [User], origin: CGPoint,
                                    width: CGFloat) {
        let size = Self.notificationAvatarSize
        let step = size + Self.notificationAvatarSpacing
        let count = min(users.count, max(1, Int((width + Self.notificationAvatarSpacing) / step)))
        var reactions: [String] = []
        if case .reactions(let list) = notification.kind { reactions = list.map(\.reaction) }
        var badges: [DrawOp] = []
        for (index, user) in users.prefix(count).enumerated() {
            let frame = CGRect(x: origin.x + CGFloat(index) * step, y: origin.y, width: size, height: size)
            images.append(avatarSlot(user, frame))
            targets.append(TapTarget(frame: frame.insetBy(dx: -3, dy: -6), action: .user(user.id)))
            if reactions.indices.contains(index), let note = notification.subjectNote {
                badges += reactionBadge(reactions[index], note: note,
                                        corner: CGPoint(x: CGFloat(index) * step + size, y: size))
            }
        }
        if !badges.isEmpty {
            addBlock(CGRect(x: origin.x, y: origin.y, width: width, height: size + Self.badgeOverhang), badges)
        }
    }

    private static let badgeOverhang: CGFloat = 4

    private func reactionBadge(_ key: String, note: Note, corner: CGPoint) -> [DrawOp] {
        let chipHeight: CGFloat = 20
        let emojiHeight: CGFloat = 14
        let content: DrawOp
        let contentWidth: CGFloat
        switch resolver.reaction(key, reactionEmojis: note.reactionEmojis) {
        case .custom(_, let url):
            guard let url, let aspect = sizer.aspectRatio(of: url) else { return [] }
            contentWidth = (emojiHeight * min(2, max(0.6, aspect))).rounded()
            content = .emoji(url: url, rect: CGRect(x: 0, y: 0, width: contentWidth, height: emojiHeight))
        case .unicode(let emoji):
            let font = Typography.system(12)
            let text = TextLayout.singleLine(plain(emoji, font: font, role: .primaryText),
                                             metrics: typography.lineMetrics(for: font))
            contentWidth = text.size.width
            content = .text(text, origin: CGPoint(x: 0, y: (emojiHeight - text.size.height) / 2))
        }
        let chipWidth = max(chipHeight, contentWidth + 6)
        let chip = CGRect(x: corner.x + Self.badgeOverhang - chipWidth, y: corner.y + Self.badgeOverhang - chipHeight,
                          width: chipWidth, height: chipHeight)
        return [
            .roundedRect(chip, radius: chipHeight / 2, fill: .background, stroke: nil),
            content.offset(dx: chip.midX - contentWidth / 2, dy: chip.midY - emojiHeight / 2),
        ]
    }

    private mutating func summaryLine(_ notification: MisskeyNotification, users: [User], width: CGFloat)
        -> (ops: [DrawOp], time: TimePlacement, height: CGFloat) {
        let metrics = bodyMetrics
        let timeFontSize = CTFontGetSize(typography.secondary)
        let style = key.timeStyles.created
        let timeWidth = TimeSlot.reservedWidth(for: .elapsed(style), prefix: Self.timePrefix, fontSize: timeFontSize)

        let rest = Self.summary(of: notification.kind, others: max(0, users.count - 1))
        let attributed: NSAttributedString
        if let user = users.first {
            attributed = concat(name(user, font: typography.bodyBold, role: .primaryText),
                                plain("さん", font: typography.bodyBold, role: .primaryText),
                                plain(rest, font: typography.body, role: .primaryText))
            accessibilityBeforeTime.append("\(user.displayName)さん\(rest)")
        } else {
            attributed = plain(rest, font: typography.bodyBold, role: .primaryText)
            accessibilityBeforeTime.append(rest)
        }
        let text = TextLayout(attributed, width: width, metrics: metrics, maxLines: Self.notificationSummaryLines)
        var height = text.size.height
        var time = TimePlacement(kind: .since(notification.createdAt, style),
                                 offset: CGPoint(x: text.lastLineWidth, y: height - metrics.lineHeight),
                                 reservedWidth: timeWidth, metrics: metrics, fontSize: timeFontSize)
        if time.offset.x + timeWidth > width {
            time = TimePlacement(kind: time.kind, offset: CGPoint(x: 0, y: height),
                                 reservedWidth: TimeSlot.reservedWidth(for: .elapsed(style), prefix: "",
                                                                       fontSize: timeFontSize),
                                 metrics: metrics, fontSize: timeFontSize, prefix: "")
            height += metrics.lineHeight
        }
        return ([.text(text, origin: .zero)], time, height)
    }

    private mutating func excerpt(of notification: MisskeyNotification, width: CGFloat) -> TextLayout? {
        let attributed: NSAttributedString
        if case .app(_, let body?, _) = notification.kind {
            attributed = plain(body, font: typography.body, role: .secondaryText)
            accessibilityAfterTime.append(body)
        } else if let note = notification.subjectNote {
            if let text = note.cw ?? note.text, !text.isEmpty {
                attributed = richText(text, .text(of: note), font: typography.body, role: .secondaryText)
                accessibilityAfterTime.append(text)
            } else if !note.files.isEmpty {
                let text = "添付ファイル\(note.files.count)件"
                attributed = plain(text, font: typography.body, role: .secondaryText)
                accessibilityAfterTime.append(text)
            } else {
                return nil
            }
        } else {
            return nil
        }
        return TextLayout(attributed, width: width, metrics: bodyMetrics, maxLines: Self.notificationExcerptLines)
    }

    /// What follows the name (or stands alone, for notifications without a user).
    static func summary(of kind: MisskeyNotification.Kind, others: Int) -> String {
        let and = others > 0 ? "と他\(others)人" : ""
        switch kind {
        case .reactions: return "\(and)がリアクションしました"
        case .renotes: return "\(and)がリノートしました"
        case .follow: return "にフォローされました"
        case .followRequest: return "からフォローリクエストが届きました"
        case .followRequestAccepted: return "がフォローリクエストを承認しました"
        case .chatRoomInvitation: return "からチャットルームに招待されました"
        case .pollEnded: return "アンケートが終了しました"
        case .scheduledNotePosted: return "予約したノートが投稿されました"
        case .scheduledNotePostFailed: return "予約したノートを投稿できませんでした"
        case .roleAssigned(let name): return name.map { "ロール「\($0)」が付与されました" } ?? "ロールが付与されました"
        case .achievementEarned: return "実績を獲得しました"
        case .app(let header, _, _): return header ?? "アプリからのお知らせ"
        case .exportCompleted: return "エクスポートが完了しました"
        case .login: return "ログインがありました"
        case .createToken: return "アクセストークンが作成されました"
        case .test: return "テスト通知"
        case .note, .mention, .reply, .quote: return ""
        }
    }

    static func icon(for kind: MisskeyNotification.Kind) -> (Icon, ColorRole) {
        switch kind {
        case .reactions: (.reacted, .reaction)
        case .renotes: (.renoteBadge, .renote)
        case .follow, .followRequest, .followRequestAccepted, .chatRoomInvitation: (.person, .accent)
        case .pollEnded: (.poll, .accent)
        case .scheduledNotePosted, .scheduledNotePostFailed: (.clock, .accent)
        default: (.bell, .accent)
        }
    }
}
