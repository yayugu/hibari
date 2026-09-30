import CoreGraphics
import CoreText
import Foundation
import os

final class NoteLayoutEngine: Sendable {
    let emojiResolver: EmojiResolver
    let sizes: any MediaSizeProvider
    private let cache = Locked<[LayoutKey: NoteLayout]>([:])
    private let cacheLimit = 5000

    init(emojiResolver: EmojiResolver, sizes: any MediaSizeProvider) {
        self.emojiResolver = emojiResolver
        self.sizes = sizes
    }

    func key(for item: TimelineItem, context: LayoutContext, now: Date) -> LayoutKey {
        LayoutKey(noteID: item.id, contentHash: item.contentHash, state: item.state,
                  timeStyles: TimeStyles(for: item, now: now), context: context)
    }

    /// False when the layout guessed the size of a custom emoji that is known by now.
    /// Only emoji sizes: whether the key still matches is the caller's to check.
    func emojiSizesAreCurrent(in layout: NoteLayout) -> Bool {
        layout.provisionalEmojis.allSatisfy { sizes.mediaSize(for: $0) == .unknown }
    }

    func cachedLayout(for item: TimelineItem, context: LayoutContext, now: Date) -> NoteLayout? {
        let key = key(for: item, context: context, now: now)
        return cache.withLock { $0[key] }.flatMap { emojiSizesAreCurrent(in: $0) ? $0 : nil }
    }

    func layout(for item: TimelineItem, context: LayoutContext, now: Date) -> NoteLayout {
        let key = key(for: item, context: context, now: now)
        if let hit = cache.withLock({ $0[key] }), emojiSizesAreCurrent(in: hit) { return hit }
        let signpost = Signposts.layout.beginInterval("note", id: Signposts.layout.makeSignpostID())
        var builder = NoteLayoutBuilder(item: item, key: key, resolver: emojiResolver, sizes: sizes)
        let layout = switch item.content {
        case .note(let note): builder.build(note)
        case .notification(let notification): builder.build(notification)
        }
        Signposts.layout.endInterval("note", signpost)
        cache.withLock { cache in
            if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[key] = layout
        }
        return layout
    }

    /// Lays out items in parallel on all cores. Blocks the caller; call off the main thread.
    func layouts(for items: [TimelineItem], context: LayoutContext, now: Date) -> [NoteLayout] {
        let signpost = Signposts.layout.beginInterval("batch", id: Signposts.layout.makeSignpostID(), "\(items.count) notes")
        defer { Signposts.layout.endInterval("batch", signpost) }
        let results = Locked([NoteLayout?](repeating: nil, count: items.count))
        DispatchQueue.concurrentPerform(iterations: items.count) { index in
            let layout = layout(for: items[index], context: context, now: now)
            results.withLock { $0[index] = layout }
        }
        return results.withLock { $0.map { $0! } }
    }

    func customEmojis(in items: [TimelineItem]) -> CustomEmojiUsage {
        var usage = CustomEmojiUsage()
        func add(_ text: String?, _ context: EmojiContext, isName: Bool = false) {
            guard let text else { return }
            collectEmojis(isName ? MFMParser.parseSimple(text) : MFMParser.parse(text), context, into: &usage.text)
        }
        for item in items {
            guard case .note(let outer) = item.content else {
                guard let notification = item.notification else { continue }
                if let user = notification.users.first {
                    add(user.displayName, .name(of: user), isName: true)
                }
                if let note = notification.subjectNote {
                    add(note.cw ?? note.text, .text(of: note))
                    if case .reactions(let reactions) = notification.kind {
                        for reaction in reactions {
                            if case .custom(_, let url?) = emojiResolver.reaction(reaction.reaction,
                                                                                  reactionEmojis: note.reactionEmojis) {
                                usage.reactions.insert(url)
                            }
                        }
                    }
                }
                continue
            }
            let note = outer.displayedNote
            if outer.isPureRenote {
                add(outer.user.displayName, .name(of: outer.user), isName: true)
            }
            add(note.user.displayName, .name(of: note.user), isName: true)
            add(note.cw, .text(of: note))
            add(note.text, .text(of: note))
            for choice in note.poll?.choices ?? [] {
                add(choice.text, .text(of: note))
            }
            if let quoted = note.renote {
                add(quoted.user.displayName, .name(of: quoted.user), isName: true)
                add(quoted.cw ?? quoted.text, .text(of: quoted))
            }
            for key in note.reactions.keys where !note.isLikeOnly {
                if case .custom(_, let url?) = emojiResolver.reaction(key, reactionEmojis: note.reactionEmojis) {
                    usage.reactions.insert(url)
                }
            }
        }
        usage.reactions.subtract(usage.text)
        return usage
    }

    private func collectEmojis(_ nodes: [MFMNode], _ context: EmojiContext, into urls: inout Set<String>) {
        for node in nodes {
            switch node {
            case .emoji(let name):
                if let url = emojiResolver.url(forName: name, in: context) { urls.insert(url) }
            case .bold(let children), .italic(let children), .strike(let children), .small(let children),
                 .center(let children), .quote(let children), .link(let children, _), .fn(_, _, let children):
                collectEmojis(children, context, into: &urls)
            case .text, .inlineCode, .codeBlock, .mention, .hashtag, .url:
                break
            }
        }
    }
}

struct CustomEmojiUsage: Sendable {
    /// In text (body, CW, poll, quote, names): they decide line breaks, so a note is not
    /// laid out without them.
    var text: Set<String> = []
    /// Only in reaction chips.
    var reactions: Set<String> = []
}

struct NoteLayoutBuilder {
    let item: TimelineItem
    let key: LayoutKey
    let context: LayoutContext
    let m: LayoutMetrics
    let typography: Typography
    let palette: Palette
    let resolver: EmojiResolver
    let sizer: EmojiSizer
    let scale: CGFloat
    let bodyMetrics: LineMetrics
    let secondaryMetrics: LineMetrics
    let smallMetrics: LineMetrics

    var blocks: [RasterBlock] = []
    var images: [ImageSlot] = []
    var decorations: [Decoration] = []
    var timeSlots: [TimeSlot] = []
    var targets: [TapTarget] = []
    var collectsLinks = true
    var accessibilityBeforeTime: [String] = []
    var accessibilityAfterTime: [String] = []

    static let timePrefix = " · "

    /// Where a block puts its time label, relative to the block.
    struct TimePlacement {
        let kind: TimeSlot.Kind
        let offset: CGPoint
        let reservedWidth: CGFloat
        let metrics: LineMetrics
        let fontSize: CGFloat
        var prefix = NoteLayoutBuilder.timePrefix
    }

    init(item: TimelineItem, key: LayoutKey, resolver: EmojiResolver, sizes: any MediaSizeProvider) {
        self.item = item
        self.key = key
        context = key.context
        m = context.metrics
        typography = Typography.shared(fontScale: context.fontScale, lineHeightMultiple: context.metrics.lineHeightMultiple)
        palette = context.palette
        self.resolver = resolver
        sizer = EmojiSizer(sizes)
        scale = context.displayScale
        bodyMetrics = typography.lineMetrics(for: typography.body)
        secondaryMetrics = typography.lineMetrics(for: typography.secondary)
        smallMetrics = typography.lineMetrics(for: typography.small)
    }

    func richText(_ text: String, _ emoji: EmojiContext, font: CTFont, role: ColorRole) -> NSAttributedString {
        RichTextBuilder(palette: palette, emojiResolver: resolver, emojiContext: emoji, sizer: sizer)
            .build(MFMParser.parse(text), style: TextStyle(font: font, color: palette[role]))
    }

    func name(_ user: User, font: CTFont, role: ColorRole) -> NSAttributedString {
        RichTextBuilder(palette: palette, emojiResolver: resolver, emojiContext: .name(of: user), sizer: sizer)
            .build(MFMParser.parseSimple(user.displayName), style: TextStyle(font: font, color: palette[role]))
    }

    func plain(_ text: String, font: CTFont, role: ColorRole) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            TextAttribute.font: font,
            TextAttribute.foregroundColor: palette[role],
            TextAttribute.language: "ja",
        ])
    }

    func concat(_ parts: NSAttributedString...) -> NSAttributedString {
        let result = NSMutableAttributedString()
        parts.forEach(result.append)
        return result
    }

    mutating func addBlock(_ frame: CGRect, _ ops: [DrawOp], time: TimePlacement? = nil) {
        guard !ops.isEmpty, frame.width > 0, frame.height > 0 else { return }
        let aligned = CGRect(
            x: frame.minX.pixelAligned(scale: scale),
            y: frame.minY.pixelAligned(scale: scale),
            width: frame.width.pixelCeil(scale: scale),
            height: frame.height.pixelCeil(scale: scale))
        blocks.append(RasterBlock(frame: aligned, ops: ops))
        if collectsLinks {
            for case .text(let layout, let origin) in ops {
                for link in layout.links {
                    targets.append(TapTarget(
                        frame: link.rect.offsetBy(dx: aligned.minX + origin.x, dy: aligned.minY + origin.y)
                            .insetBy(dx: -2, dy: -3),
                        action: .link(link.link)))
                }
            }
        }
        if let time {
            timeSlots.append(TimeSlot(
                kind: time.kind,
                prefix: time.prefix,
                origin: CGPoint(x: (aligned.minX + time.offset.x).pixelAligned(scale: scale),
                                y: (aligned.minY + time.offset.y).pixelAligned(scale: scale)),
                reservedWidth: time.reservedWidth,
                height: time.metrics.lineHeight,
                baseline: time.metrics.baseline,
                fontSize: time.fontSize,
                color: .secondaryText))
        }
    }

    mutating func addTextBlocks(_ text: TextLayout, at origin: CGPoint, width: CGFloat, metrics: LineMetrics) {
        let pieces = text.pieces(maxHeight: CGFloat(Rasterizer.maxPixelDimension / 4) / scale)
        let overlap = (metrics.lineHeight / 2).rounded(.up)
        for (index, piece) in pieces.enumerated() {
            let above = index > 0 ? overlap : 0
            let below = index < pieces.count - 1 ? overlap : 0
            addBlock(CGRect(x: origin.x, y: origin.y + piece.top - above, width: width,
                            height: above + piece.layout.size.height + below),
                     [.text(piece.layout, origin: CGPoint(x: 0, y: above))])
        }
    }

    mutating func build(_ outer: Note) -> NoteLayout {
        let note = outer.displayedNote
        let leading = context.safeAreaLeft + m.contentInsets.left
        let trailing = context.canvasWidth - context.safeAreaRight - m.contentInsets.right
        let headerX = leading + m.avatarSize + m.avatarSpacing
        let contentX = m.bodyBelowAvatar ? leading : headerX
        let contentWidth = max(40, trailing - contentX)
        var y = m.contentInsets.top

        if outer.isPureRenote {
            let label = concat(
                name(outer.user, font: typography.smallBold, role: .secondaryText),
                plain("がリノート", font: typography.smallBold, role: .secondaryText))
            let text = TextLayout.singleLine(label, maxWidth: trailing - headerX, metrics: smallMetrics)
            let height = text.size.height
            let iconSize = (CTFontGetSize(typography.small) * 1.05).rounded()
            let iconRect = CGRect(x: m.avatarSize - iconSize, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
            addBlock(CGRect(x: leading, y: y, width: trailing - leading, height: height), [
                .icon(.renoteBadge, rect: iconRect, color: .secondaryText),
                .text(text, origin: CGPoint(x: headerX - leading, y: 0)),
            ])
            targets.append(TapTarget(frame: CGRect(x: headerX, y: y, width: text.size.width, height: height)
                                        .insetBy(dx: -4, dy: -6),
                                     action: .user(outer.user.id)))
            y += height + 4
            accessibilityBeforeTime.append("\(outer.user.displayName)がリノート")
        }

        let rowTop = y
        let avatarFrame = CGRect(x: leading, y: rowTop, width: m.avatarSize, height: m.avatarSize)
        images.append(avatarSlot(note.user, avatarFrame))
        targets.append(TapTarget(frame: avatarFrame, action: .user(note.user.id)))

        let header = headerLine(note, width: trailing - headerX, compact: false, timeStyle: key.timeStyles.created)
        addBlock(CGRect(x: headerX, y: y, width: trailing - headerX, height: header.height), header.ops, time: header.time)
        targets.append(TapTarget(frame: CGRect(x: headerX, y: y, width: header.time.offset.x, height: header.height)
                                    .insetBy(dx: 0, dy: -4),
                                 action: .user(note.user.id)))
        let moreSize = m.actionIconSize
        targets.append(TapTarget(frame: CGRect(x: trailing - moreSize, y: y + (header.height - moreSize) / 2,
                                               width: moreSize, height: moreSize).insetBy(dx: -12, dy: -10),
                                 action: .more))
        y += header.height
        if m.bodyBelowAvatar {
            y = max(y, rowTop + m.avatarSize)
        }
        accessibilityBeforeTime.append(note.user.displayName)

        var cursor = y
        var placed = false
        func top(_ gap: CGFloat) -> CGFloat { placed ? cursor + gap : cursor + m.headerSpacing }

        if note.replyId != nil {
            let target = note.reply.map { $0.user.acct }
            let label = target.map {
                concat(plain("返信先: ", font: typography.small, role: .secondaryText),
                       plain($0, font: typography.small, role: .accent))
            } ?? plain("返信", font: typography.small, role: .secondaryText)
            let text = TextLayout.singleLine(label, maxWidth: contentWidth, metrics: smallMetrics)
            let t = top(0)
            addBlock(CGRect(x: contentX, y: t, width: contentWidth, height: text.size.height), [.text(text, origin: .zero)])
            if let replied = note.reply?.user {
                targets.append(TapTarget(frame: CGRect(x: contentX, y: t, width: text.size.width, height: text.size.height)
                                            .insetBy(dx: -4, dy: -4),
                                         action: .user(replied.id)))
            }
            cursor = t + text.size.height
            placed = true
        }

        var showsContent = true
        if let cw = note.cw {
            let cwText = TextLayout(richText(cw, .text(of: note), font: typography.body, role: .primaryText),
                                    width: contentWidth, metrics: bodyMetrics)
            let fileCount = note.files.count
            let pillLabel = TextLayout.singleLine(
                plain(item.state.cwExpanded ? "隠す" : (fileCount > 0 ? "もっと見る (\(fileCount)ファイル)" : "もっと見る"),
                      font: typography.smallBold, role: .primaryText),
                metrics: smallMetrics)
            let pill = CGRect(x: 0, y: cwText.size.height + 8, width: pillLabel.size.width + 24, height: smallMetrics.lineHeight + 10)
            let t = top(4)
            addBlock(CGRect(x: contentX, y: t, width: contentWidth, height: pill.maxY), [
                .text(cwText, origin: .zero),
                .roundedRect(pill, radius: pill.height / 2, fill: .chipBackground, stroke: nil),
                .text(pillLabel, origin: CGPoint(x: 12, y: pill.minY + 5)),
            ])
            targets.append(TapTarget(frame: pill.offsetBy(dx: contentX, dy: t).insetBy(dx: -8, dy: -8),
                                     action: .toggleCW))
            cursor = t + pill.maxY
            placed = true
            showsContent = item.state.cwExpanded
            accessibilityAfterTime.append("注意: \(cw)")
        }

        if showsContent {
            if let text = note.text, !text.isEmpty {
                let attributed = richText(text, .text(of: note), font: typography.body, role: .primaryText)
                let layout = TextLayout(attributed, width: contentWidth, metrics: bodyMetrics)
                let t = top(4)
                if !item.state.textExpanded && layout.lines.count > m.bodyCollapseLines {
                    let collapsed = TextLayout(attributed, width: contentWidth, metrics: bodyMetrics,
                                               maxLines: m.bodyCollapsedLines)
                    let more = TextLayout.singleLine(plain("続きを見る", font: typography.body, role: .accent), metrics: bodyMetrics)
                    let moreFrame = CGRect(origin: CGPoint(x: 0, y: collapsed.size.height), size: more.size)
                    addBlock(CGRect(x: contentX, y: t, width: contentWidth, height: moreFrame.maxY),
                             [.text(collapsed, origin: .zero), .text(more, origin: moreFrame.origin)])
                    targets.append(TapTarget(frame: moreFrame.offsetBy(dx: contentX, dy: t).insetBy(dx: -8, dy: -6),
                                             action: .expandText))
                    cursor = t + moreFrame.maxY
                } else {
                    addTextBlocks(layout, at: CGPoint(x: contentX, y: t), width: contentWidth, metrics: bodyMetrics)
                    cursor = t + layout.size.height
                }
                placed = true
                accessibilityAfterTime.append(text)
            }

            if let poll = note.poll {
                let (ops, height, time) = pollBlock(poll, note: note, width: contentWidth)
                let t = top(m.blockSpacing)
                addBlock(CGRect(x: contentX, y: t, width: contentWidth, height: height), ops, time: time)
                cursor = t + height
                placed = true
            }

            if !note.files.isEmpty {
                let t = top(m.blockSpacing)
                let height = mediaGrid(note.files, owner: .note, origin: CGPoint(x: contentX, y: t), width: contentWidth,
                                       outerCorners: .all, framed: true)
                cursor = t + height
                placed = true
                accessibilityAfterTime.append("添付ファイル\(note.files.count)件")
            }

            if let quoted = note.renote {
                let t = top(m.blockSpacing)
                let height = quoteBox(quoted, origin: CGPoint(x: contentX, y: t), width: contentWidth)
                cursor = t + height
                placed = true
            }
        }

        if !note.reactions.isEmpty && !note.isLikeOnly {
            let (ops, height, chips) = reactionsBlock(note, width: contentWidth)
            let t = top(m.blockSpacing)
            addBlock(CGRect(x: contentX, y: t, width: contentWidth, height: height), ops)
            for (key, chip) in chips {
                targets.append(TapTarget(frame: chip.offsetBy(dx: contentX, dy: t).insetBy(dx: 0, dy: -2),
                                         action: .reaction(key)))
            }
            cursor = t + height
            placed = true
        }

        if note.isRenotedByMe {
            accessibilityAfterTime.append("リノート済み")
        }
        if note.isBookmarked {
            accessibilityAfterTime.append("ブックマーク済み")
        }

        let barTop = top(m.blockSpacing)
        let (barOps, barTargets) = actionBar(note, width: contentWidth)
        addBlock(CGRect(x: contentX, y: barTop, width: contentWidth, height: m.actionBarHeight), barOps)
        for target in barTargets {
            targets.append(TapTarget(frame: target.frame.offsetBy(dx: contentX, dy: barTop), action: target.action))
        }
        cursor = barTop + m.actionBarHeight

        let height = (max(cursor, rowTop + m.avatarSize) + m.contentInsets.bottom).pixelCeil(scale: scale)
        var connectors: [CGRect] = []
        let lineX = (leading + m.avatarSize / 2 - 1).pixelAligned(scale: scale)
        if item.state.thread.contains(.above) {
            connectors.append(CGRect(x: lineX, y: 0, width: 2, height: max(0, rowTop - 4)))
        }
        if item.state.thread.contains(.below) {
            let top = rowTop + m.avatarSize + 4
            connectors.append(CGRect(x: lineX, y: top, width: 2, height: max(0, height - top)))
        }
        return NoteLayout(
            key: key,
            height: height,
            blocks: blocks,
            images: images,
            decorations: decorations,
            timeSlots: timeSlots,
            accessibility: AccessibilityText(beforeTime: accessibilityBeforeTime.joined(separator: "、"),
                                             date: note.createdAt,
                                             afterTime: accessibilityAfterTime.joined(separator: "、")),
            provisionalEmojis: sizer.provisional,
            targets: targets,
            connectors: connectors,
            showsSeparator: !item.state.thread.contains(.below))
    }

    func avatarSlot(_ user: User, _ frame: CGRect) -> ImageSlot {
        let frame = frame.pixelAligned(scale: scale)
        return ImageSlot(
            frame: frame,
            request: user.avatarUrl.map {
                ImageRequest(url: $0, size: frame.size, scale: scale, mode: .aspectFill, shape: .circle)
            },
            blurhash: user.avatarBlurhash,
            cornerRadius: frame.width / 2,
            corners: .all,
            overlay: nil)
    }

    private func headerLine(_ note: Note, width: CGFloat, compact: Bool, timeStyle: ElapsedStyle)
        -> (ops: [DrawOp], time: TimePlacement, height: CGFloat) {
        let nameFont = compact ? Typography.bold(typography.secondary) : typography.bodyBold
        let metrics = compact ? secondaryMetrics : bodyMetrics
        let accessoryWidth = compact ? 0 : m.accessoryWidth

        let visibilityIcon: Icon? = switch note.visibility {
        case "home": .visibilityHome
        case "followers": .visibilityFollowers
        case "specified": .visibilitySpecified
        default: nil
        }
        let iconSize = (CTFontGetSize(typography.secondary) * 0.8).rounded()
        let available = width - accessoryWidth - (visibilityIcon == nil ? 0 : iconSize + 6)

        let nameString = name(note.user, font: nameFont, role: .primaryText)
        let handleString = plain(" \(note.user.acct)", font: typography.secondary, role: .secondaryText)
        let timeFontSize = CTFontGetSize(typography.secondary)
        let fixed = TimeSlot.reservedWidth(for: .elapsed(timeStyle), prefix: Self.timePrefix, fontSize: timeFontSize)

        let nameWidth = TextLayout.width(of: nameString)
        let handleWidth = TextLayout.width(of: handleString)
        let minimumHandle: CGFloat = 48
        let nameLayout: TextLayout
        var handleLayout: TextLayout?
        if nameWidth + handleWidth + fixed <= available {
            nameLayout = .singleLine(nameString, metrics: metrics)
            handleLayout = .singleLine(handleString, metrics: metrics)
        } else if nameWidth + minimumHandle + fixed <= available {
            nameLayout = .singleLine(nameString, metrics: metrics)
            handleLayout = .singleLine(handleString, maxWidth: available - nameLayout.size.width - fixed, metrics: metrics)
        } else {
            nameLayout = .singleLine(nameString, maxWidth: max(24, available - fixed), metrics: metrics)
        }

        let height = metrics.lineHeight
        var ops: [DrawOp] = [.text(nameLayout, origin: .zero)]
        var x = nameLayout.size.width
        if let handleLayout {
            ops.append(.text(handleLayout, origin: CGPoint(x: x, y: 0)))
            x += handleLayout.size.width
        }
        if let visibilityIcon {
            ops.append(.icon(visibilityIcon, rect: CGRect(x: width - accessoryWidth - iconSize, y: (height - iconSize) / 2,
                                                          width: iconSize, height: iconSize),
                             color: .secondaryText))
        }
        let time = TimePlacement(kind: .since(note.createdAt, timeStyle), offset: CGPoint(x: x, y: 0), reservedWidth: fixed,
                                 metrics: metrics, fontSize: timeFontSize)
        return (ops, time, height)
    }

    private mutating func mediaGrid(
        _ files: [DriveFile],
        owner: MediaOwner,
        origin: CGPoint,
        width: CGFloat,
        outerCorners: CornerMask,
        framed: Bool
    ) -> CGFloat {
        let visual = files.filter { $0.isImage || $0.isVideo }
        let others = files.filter { !($0.isImage || $0.isVideo) }
        var height: CGFloat = 0

        if !visual.isEmpty {
            let tiles = MediaGrid.frames(count: min(visual.count, 4), width: width, gap: m.mediaSpacing,
                                        firstAspect: visual[0].aspectRatio)
            let revealed = context.revealsSensitiveMedia || item.state.sensitiveRevealed
            let gridHeight = tiles.map(\.maxY).max() ?? 0
            for (index, tile) in tiles.enumerated() {
                let file = visual[index]
                let hidden = file.isSensitive && !revealed
                let frame = tile.offsetBy(dx: origin.x, dy: origin.y).pixelAligned(scale: scale)
                var overlay: MediaOverlay?
                if index == 3 && visual.count > 4 {
                    overlay = .more(visual.count - 4)
                } else if hidden {
                    overlay = .sensitive
                } else if file.isVideo {
                    overlay = .play
                } else if file.isGIF {
                    overlay = .gif
                }
                var corners: CornerMask = []
                if tile.minX <= 0 && tile.minY <= 0 { corners.insert(.topLeft) }
                if tile.maxX >= width - 0.5 && tile.minY <= 0 { corners.insert(.topRight) }
                if tile.minX <= 0 && tile.maxY >= gridHeight - 0.5 { corners.insert(.bottomLeft) }
                if tile.maxX >= width - 0.5 && tile.maxY >= gridHeight - 0.5 { corners.insert(.bottomRight) }
                let url = hidden ? nil : MediaRequestPolicy.previewURL(for: file)
                let media = MediaRef(owner: owner, index: index)
                images.append(ImageSlot(
                    frame: frame,
                    request: url.map { ImageRequest(url: $0, size: frame.size, scale: scale) },
                    blurhash: file.blurhash,
                    cornerRadius: m.mediaCornerRadius,
                    corners: corners.intersection(outerCorners),
                    overlay: overlay,
                    media: media))
                targets.append(TapTarget(frame: frame, action: hidden ? .revealSensitive : .media(media)))
            }
            if framed {
                decorations.append(Decoration(
                    frame: CGRect(x: origin.x, y: origin.y, width: width, height: gridHeight).pixelAligned(scale: scale),
                    cornerRadius: m.mediaCornerRadius,
                    border: .border))
            }
            height = gridHeight
        }

        for file in others {
            if height > 0 { height += 6 }
            let rowHeight = smallMetrics.lineHeight + 16
            let label = TextLayout.singleLine(plain(file.name, font: typography.small, role: .primaryText),
                                              maxWidth: width - 48, metrics: smallMetrics)
            let rect = CGRect(x: 0, y: 0, width: width, height: rowHeight)
            addBlock(CGRect(x: origin.x, y: origin.y + height, width: width, height: rowHeight), [
                .roundedRect(rect.insetBy(dx: 0.5, dy: 0.5), radius: 10, fill: nil, stroke: .border),
                .icon(.file, rect: CGRect(x: 12, y: (rowHeight - 18) / 2, width: 18, height: 18), color: .secondaryText),
                .text(label, origin: CGPoint(x: 38, y: 8)),
            ])
            if collectsLinks, let url = file.url {
                targets.append(TapTarget(frame: rect.offsetBy(dx: origin.x, dy: origin.y + height), action: .link(url)))
            }
            height += rowHeight
        }
        return height
    }

    private mutating func quoteBox(_ quoted: Note, origin: CGPoint, width: CGFloat) -> CGFloat {
        let targetIndex = targets.count
        collectsLinks = false
        defer { collectsLinks = true }
        let pad = m.quotePadding
        let innerX = origin.x + pad
        let innerWidth = width - pad * 2
        var y = origin.y + pad

        let avatar = m.quoteAvatarSize
        let header = headerLine(quoted, width: innerWidth - avatar - 6, compact: true,
                                timeStyle: key.timeStyles.quoted ?? .relative)
        images.append(avatarSlot(quoted.user, CGRect(x: innerX, y: y + (header.height - avatar) / 2,
                                                     width: avatar, height: avatar)))
        addBlock(CGRect(x: innerX + avatar + 6, y: y, width: innerWidth - avatar - 6, height: header.height), header.ops,
                 time: header.time)
        targets.append(TapTarget(frame: CGRect(x: innerX, y: y, width: avatar + 6 + header.time.offset.x,
                                               height: header.height).insetBy(dx: -4, dy: -4),
                                 action: .user(quoted.user.id)))
        y += header.height

        if let body = quoted.cw ?? quoted.text, !body.isEmpty {
            let text = TextLayout(richText(body, .text(of: quoted), font: typography.body, role: .primaryText),
                                  width: innerWidth, metrics: bodyMetrics, maxLines: m.quoteMaxLines)
            y += 2
            addBlock(CGRect(x: innerX, y: y, width: innerWidth, height: text.size.height), [.text(text, origin: .zero)])
            y += text.size.height
        } else if quoted.renote != nil {
            let text = TextLayout.singleLine(plain("RN", font: typography.small, role: .secondaryText), metrics: smallMetrics)
            addBlock(CGRect(x: innerX, y: y, width: innerWidth, height: text.size.height), [.text(text, origin: .zero)])
            y += text.size.height
        }

        var bottomPadding = pad
        if quoted.cw == nil && !quoted.files.isEmpty {
            y += 8
            y += mediaGrid(quoted.files, owner: .quote, origin: CGPoint(x: origin.x, y: y), width: width,
                           outerCorners: [.bottomLeft, .bottomRight], framed: false)
            bottomPadding = 0
        }
        let height = y + bottomPadding - origin.y
        let frame = CGRect(x: origin.x, y: origin.y, width: width, height: height).pixelAligned(scale: scale)
        decorations.append(Decoration(frame: frame, cornerRadius: m.mediaCornerRadius, border: .border))
        targets.insert(TapTarget(frame: frame, action: .quote), at: targetIndex)
        return height
    }

    private func pollBlock(_ poll: Poll, note: Note, width: CGFloat) -> ([DrawOp], CGFloat, TimePlacement?) {
        let total = poll.choices.reduce(0) { $0 + $1.votes }
        let rowHeight = (smallMetrics.lineHeight + 16).rounded()
        var ops: [DrawOp] = []
        var y: CGFloat = 0
        for choice in poll.choices {
            let rect = CGRect(x: 0, y: y, width: width, height: rowHeight)
            ops.append(.roundedRect(rect, radius: 8, fill: .chipBackground, stroke: nil))
            let ratio = total > 0 ? CGFloat(choice.votes) / CGFloat(total) : 0
            if ratio > 0 {
                ops.append(.roundedRect(CGRect(x: 0, y: y, width: max(16, width * ratio), height: rowHeight),
                                        radius: 8, fill: .chipReactedBackground, stroke: nil))
            }
            let percent = TextLayout.singleLine(
                plain("\(Int((ratio * 100).rounded()))%", font: typography.smallBold, role: .secondaryText),
                metrics: smallMetrics)
            var labelX: CGFloat = 12
            if choice.isVoted == true {
                ops.append(.icon(.check, rect: CGRect(x: 10, y: y + (rowHeight - 16) / 2, width: 16, height: 16), color: .accent))
                labelX = 32
            }
            let label = TextLayout.singleLine(
                richText(choice.text, .text(of: note), font: typography.small, role: .primaryText)
                    .firstLine(),
                maxWidth: width - labelX - percent.size.width - 20, metrics: smallMetrics)
            ops.append(.text(label, origin: CGPoint(x: labelX, y: y + 8)))
            ops.append(.text(percent, origin: CGPoint(x: width - 12 - percent.size.width, y: y + 8)))
            y += rowHeight + 6
        }
        let footerMetrics = typography.lineMetrics(for: typography.caption)
        let footer = TextLayout.singleLine(plain("\(total)票", font: typography.caption, role: .secondaryText),
                                           metrics: footerMetrics)
        ops.append(.text(footer, origin: CGPoint(x: 0, y: y)))
        let fontSize = CTFontGetSize(typography.caption)
        let time = poll.expiresAt.map {
            TimePlacement(kind: .until($0), offset: CGPoint(x: footer.size.width, y: y),
                          reservedWidth: TimeSlot.reservedWidth(for: .remaining, prefix: Self.timePrefix, fontSize: fontSize),
                          metrics: footerMetrics, fontSize: fontSize)
        }
        return (ops, y + footerMetrics.lineHeight, time)
    }

    private func reactionsBlock(_ note: Note, width: CGFloat) -> ([DrawOp], CGFloat, [(String, CGRect)]) {
        let entries = note.reactions.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        let chipHeight = m.reactionChipHeight
        let spacing = m.reactionChipSpacing
        let padding: CGFloat = 9
        let emojiHeight: CGFloat = 20
        let unicodeFont = Typography.system((CTFontGetSize(typography.body) * 1.05).rounded())
        let unicodeMetrics = typography.lineMetrics(for: unicodeFont)

        var ops: [DrawOp] = []
        var chips: [(String, CGRect)] = []
        var x: CGFloat = 0
        var row = 0
        for (index, (key, count)) in entries.enumerated() {
            let reacted = key == note.myReaction
            let countText = TextLayout.singleLine(
                plain(CountLabel.format(count), font: typography.small, role: reacted ? .accent : .secondaryText),
                metrics: smallMetrics)

            var content: DrawOp
            var contentWidth: CGFloat
            switch resolver.reaction(key, reactionEmojis: note.reactionEmojis) {
            case .custom(let name, let url):
                if let url, let aspect = sizer.aspectRatio(of: url) {
                    contentWidth = (emojiHeight * min(3, max(0.6, aspect))).rounded()
                    content = .emoji(url: url, rect: CGRect(x: 0, y: (chipHeight - emojiHeight) / 2,
                                                            width: contentWidth, height: emojiHeight))
                } else {
                    let text = TextLayout.singleLine(plain(":\(name):", font: typography.small, role: .secondaryText),
                                                     maxWidth: 120, metrics: smallMetrics)
                    contentWidth = text.size.width
                    content = .text(text, origin: CGPoint(x: 0, y: (chipHeight - text.size.height) / 2))
                }
            case .unicode(let emoji):
                let text = TextLayout.singleLine(plain(emoji, font: unicodeFont, role: .primaryText), metrics: unicodeMetrics)
                contentWidth = text.size.width
                content = .text(text, origin: CGPoint(x: 0, y: (chipHeight - text.size.height) / 2))
            }

            let chipWidth = padding + contentWidth + 5 + countText.size.width + padding
            if x > 0 && x + chipWidth > width {
                if row + 1 >= m.reactionMaxRows {
                    let rest = TextLayout.singleLine(
                        plain("+\(entries.count - index)", font: typography.smallBold, role: .secondaryText),
                        metrics: smallMetrics)
                    if x + rest.size.width <= width {
                        let rowY = CGFloat(row) * (chipHeight + spacing)
                        ops.append(.text(rest, origin: CGPoint(x: x, y: rowY + (chipHeight - rest.size.height) / 2)))
                    }
                    break
                }
                row += 1
                x = 0
            }
            let rowY = CGFloat(row) * (chipHeight + spacing)
            let chip = CGRect(x: x, y: rowY, width: chipWidth, height: chipHeight)
            chips.append((key, chip))
            ops.append(.roundedRect(reacted ? chip.insetBy(dx: 0.5, dy: 0.5) : chip, radius: chipHeight / 2,
                                    fill: reacted ? .chipReactedBackground : .chipBackground,
                                    stroke: reacted ? .accent : nil))
            ops.append(content.offset(dx: x + padding, dy: rowY))
            ops.append(.text(countText, origin: CGPoint(x: x + padding + contentWidth + 5,
                                                        y: rowY + (chipHeight - countText.size.height) / 2)))
            x += chipWidth + spacing
        }
        return (ops, CGFloat(row + 1) * chipHeight + CGFloat(row) * spacing, chips)
    }

    private func actionBar(_ note: Note, width: CGFloat) -> ([DrawOp], [TapTarget]) {
        let size = m.actionIconSize
        let height = m.actionBarHeight
        let iconY = (height - size) / 2
        var ops: [DrawOp] = []
        var targets: [TapTarget] = []
        let react = Icon.reactButton(for: note)
        let bookmarked = note.isBookmarked
        let iconXs = m.actionIconXs(for: width)
        let items: [(Icon, Int?, ColorRole, NoteTapAction)] = [
            (.reply, note.repliesCount, .secondaryText, .reply),
            (.renote, note.renoteCount, note.isRenotedByMe ? .renote : .secondaryText, .renote),
            (react.icon, note.reactionTotal, react.color, .react),
            (bookmarked ? .bookmarked : .bookmark, nil, bookmarked ? .accent : .secondaryText, .bookmark),
            (.share, nil, .secondaryText, .share),
        ]
        for (index, (icon, count, role, action)) in items.enumerated() {
            let x = iconXs[index]
            ops.append(.icon(icon, rect: CGRect(x: x, y: iconY, width: size, height: size), color: role))
            var labelWidth: CGFloat = 0
            if let count, count > 0, index + 1 < iconXs.count {
                let text = TextLayout.singleLine(plain(CountLabel.format(count), font: typography.small, role: role),
                                                 maxWidth: max(0, iconXs[index + 1] - x - size - 9), metrics: smallMetrics)
                ops.append(.text(text, origin: CGPoint(x: x + size + 5, y: (height - text.size.height) / 2)))
                labelWidth = 5 + text.size.width
            }
            targets.append(TapTarget(frame: Self.buttonTarget(x: x, width: size + labelWidth, height: height),
                                     action: action))
        }
        return (ops, targets)
    }

    private static func buttonTarget(x: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        let padding: CGFloat = 10
        let targetWidth = max(44, width + padding * 2)
        return CGRect(x: x - padding, y: -padding, width: targetWidth, height: height + padding * 2)
    }
}

extension DrawOp {
    func offset(dx: CGFloat, dy: CGFloat) -> DrawOp {
        switch self {
        case .text(let layout, let origin): .text(layout, origin: CGPoint(x: origin.x + dx, y: origin.y + dy))
        case .emoji(let url, let rect): .emoji(url: url, rect: rect.offsetBy(dx: dx, dy: dy))
        case .icon(let icon, let rect, let color): .icon(icon, rect: rect.offsetBy(dx: dx, dy: dy), color: color)
        case .roundedRect(let rect, let radius, let fill, let stroke):
            .roundedRect(rect.offsetBy(dx: dx, dy: dy), radius: radius, fill: fill, stroke: stroke)
        }
    }
}

private extension NSAttributedString {
    func firstLine() -> NSAttributedString {
        let newline = (string as NSString).range(of: "\n").location
        return newline == NSNotFound ? self : attributedSubstring(from: NSRange(location: 0, length: newline))
    }
}

enum MediaGrid {
    static func frames(count: Int, width: CGFloat, gap: CGFloat, firstAspect: Double?) -> [CGRect] {
        let half = (width - gap) / 2
        switch count {
        case 1:
            let ratio = firstAspect.map { min(1.25, max(0.5, 1 / $0)) } ?? 0.5625
            return [CGRect(x: 0, y: 0, width: width, height: (width * ratio).rounded())]
        case 2:
            let h = (width * 0.5625).rounded()
            return [CGRect(x: 0, y: 0, width: half, height: h), CGRect(x: half + gap, y: 0, width: half, height: h)]
        case 3:
            let h = (width * 0.5625).rounded()
            let small = (h - gap) / 2
            return [
                CGRect(x: 0, y: 0, width: half, height: h),
                CGRect(x: half + gap, y: 0, width: half, height: small),
                CGRect(x: half + gap, y: small + gap, width: half, height: small),
            ]
        default:
            let h = (width * 0.5625).rounded()
            let small = (h - gap) / 2
            return [
                CGRect(x: 0, y: 0, width: half, height: small),
                CGRect(x: half + gap, y: 0, width: half, height: small),
                CGRect(x: 0, y: small + gap, width: half, height: small),
                CGRect(x: half + gap, y: small + gap, width: half, height: small),
            ]
        }
    }
}
