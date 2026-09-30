import CoreGraphics
import CoreText
import Foundation

/// One typeset line. `origin.y` is the baseline, measured from the top of the layout.
struct TextLine: @unchecked Sendable {
    let line: CTLine
    let origin: CGPoint
    /// Where the line's box starts, measured the same way.
    let top: CGFloat
}

struct EmojiPlacement: Sendable {
    let url: String
    let rect: CGRect
}

struct StrikePlacement: @unchecked Sendable {
    let rect: CGRect
    let color: CGColor
}

/// Where a link (`TextAttribute.link`) sits, one rect per line it spans.
struct LinkPlacement: Sendable {
    let link: String
    let rect: CGRect
}

struct TextLayout: Sendable {
    private(set) var lines: [TextLine] = []
    private(set) var emojis: [EmojiPlacement] = []
    private(set) var strikes: [StrikePlacement] = []
    private(set) var links: [LinkPlacement] = []
    private(set) var size: CGSize = .zero
    private(set) var isTruncated = false

    private init() {}

    /// Multi-line layout. With `maxLines`, the last line ends in "…".
    init(_ string: NSAttributedString, width: CGFloat, metrics: LineMetrics, maxLines: Int? = nil) {
        let length = string.length
        guard length > 0, width > 0 else { return }
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        let nsString = string.string as NSString
        var start = 0
        var y: CGFloat = 0
        var maxX: CGFloat = 0

        while start < length {
            let indent = string.attribute(TextAttribute.indent, at: start, effectiveRange: nil) as? CGFloat ?? 0
            let flush = string.attribute(TextAttribute.flush, at: start, effectiveRange: nil) as? CGFloat ?? 0
            let available = max(1, width - indent)
            var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(available))
            if count <= 0 { count = 1 }
            let newline = nsString.range(of: "\n", options: .literal,
                                         range: NSRange(location: start, length: count)).location
            if newline != NSNotFound { count = newline - start + 1 }
            let hasMore = start + count < length

            let line: CTLine
            if let maxLines, lines.count == maxLines - 1, hasMore {
                line = Self.truncatedLine(string, nsString: nsString, typesetter: typesetter, start: start,
                                          tokenStyleIndex: start + count - 1, width: available)
                isTruncated = true
            } else {
                line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            }

            let (height, baseline) = Self.lineBox(line, metrics: metrics)
            let penOffset = flush > 0 ? CGFloat(CTLineGetPenOffsetForFlush(line, flush, Double(available))) : 0
            let origin = CGPoint(x: indent + penOffset, y: y + baseline)
            append(line, origin: origin, top: y)
            maxX = max(maxX, origin.x + Self.visibleWidth(line))
            y += height
            start += count
            if isTruncated { break }
        }
        size = CGSize(width: maxX.rounded(.up), height: y.rounded(.up))
    }

    /// One line, truncated with "…" when wider than `maxWidth`.
    static func singleLine(_ string: NSAttributedString, maxWidth: CGFloat? = nil, metrics: LineMetrics) -> TextLayout {
        var layout = TextLayout()
        guard string.length > 0 else { return layout }
        var line = CTLineCreateWithAttributedString(string)
        if let maxWidth, visibleWidth(line) > maxWidth {
            let token = CTLineCreateWithAttributedString(truncationToken(for: string, at: string.length - 1))
            line = CTLineCreateTruncatedLine(line, Double(max(1, maxWidth)), .end, token) ?? line
            layout.isTruncated = true
        }
        let (height, baseline) = lineBox(line, metrics: metrics)
        layout.append(line, origin: CGPoint(x: 0, y: baseline), top: 0)
        layout.size = CGSize(width: visibleWidth(line).rounded(.up), height: height.rounded(.up))
        return layout
    }

    /// The layout cut between lines into pieces at most `maxHeight` tall (a line taller
    /// than that is a piece of its own), each measured from its own top, with where that
    /// top is in this layout. Emojis, strikes and links go with the line they are on.
    func pieces(maxHeight: CGFloat) -> [(layout: TextLayout, top: CGFloat)] {
        guard size.height > maxHeight, lines.count > 1 else { return [(self, 0)] }
        var tops: [CGFloat] = [0]
        for (index, line) in lines.enumerated() where index > 0 {
            let bottom = index + 1 < lines.count ? lines[index + 1].top : size.height
            if bottom - tops[tops.count - 1] > maxHeight {
                tops.append(line.top)
            }
        }
        var pieces = [TextLayout](repeating: TextLayout(), count: tops.count)
        func piece(at y: CGFloat) -> Int { tops.lastIndex { $0 <= y } ?? 0 }
        func moved(_ rect: CGRect, _ index: Int) -> CGRect { rect.offsetBy(dx: 0, dy: -tops[index]) }
        for line in lines {
            let index = piece(at: line.top)
            pieces[index].lines.append(TextLine(line: line.line,
                                                origin: CGPoint(x: line.origin.x, y: line.origin.y - tops[index]),
                                                top: line.top - tops[index]))
        }
        for emoji in emojis {
            let index = piece(at: emoji.rect.midY)
            pieces[index].emojis.append(EmojiPlacement(url: emoji.url, rect: moved(emoji.rect, index)))
        }
        for strike in strikes {
            let index = piece(at: strike.rect.midY)
            pieces[index].strikes.append(StrikePlacement(rect: moved(strike.rect, index), color: strike.color))
        }
        for link in links {
            let index = piece(at: link.rect.midY)
            pieces[index].links.append(LinkPlacement(link: link.link, rect: moved(link.rect, index)))
        }
        for index in pieces.indices {
            let bottom = index + 1 < tops.count ? tops[index + 1] : size.height
            pieces[index].size = CGSize(width: size.width, height: bottom - tops[index])
        }
        pieces[pieces.count - 1].isTruncated = isTruncated
        return pieces.indices.map { (pieces[$0], tops[$0]) }
    }

    /// Where the last line's visible text ends, for putting something after it.
    var lastLineWidth: CGFloat {
        lines.last.map { $0.origin.x + Self.visibleWidth($0.line) } ?? 0
    }

    static func width(of string: NSAttributedString) -> CGFloat {
        guard string.length > 0 else { return 0 }
        return visibleWidth(CTLineCreateWithAttributedString(string))
    }

    private static func visibleWidth(_ line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
    }

    private static func lineBox(_ line: CTLine, metrics: LineMetrics) -> (height: CGFloat, baseline: CGFloat) {
        var a: CGFloat = 0
        var d: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &a, &d, nil)
        let ascent = a > metrics.ascent * 1.2 ? a : metrics.ascent
        let descent = d > metrics.descent * 1.6 ? d : metrics.descent
        let gap = metrics.lineHeight - metrics.ascent - metrics.descent
        let height = max(metrics.lineHeight, ascent + descent + gap)
        return (height, (height - ascent - descent) / 2 + ascent)
    }

    private static func truncationToken(for string: NSAttributedString, at index: Int) -> NSAttributedString {
        let nsString = string.string as NSString
        var index = max(0, min(index, string.length - 1))
        while index > 0 && nsString.character(at: index) == 0x0A { index -= 1 }
        var attrs = string.attributes(at: index, effectiveRange: nil)
        if let emoji = attrs[TextAttribute.emoji] as? EmojiAttachment {
            attrs[TextAttribute.foregroundColor] = emoji.textColor
        }
        attrs[TextAttribute.runDelegate] = nil
        attrs[TextAttribute.emoji] = nil
        attrs[TextAttribute.link] = nil
        return NSAttributedString(string: "…", attributes: attrs)
    }

    private static func truncatedLine(
        _ string: NSAttributedString,
        nsString: NSString,
        typesetter: CTTypesetter,
        start: Int,
        tokenStyleIndex: Int,
        width: CGFloat
    ) -> CTLine {
        let searchRange = NSRange(location: start, length: string.length - start)
        let newline = nsString.range(of: "\n", options: [], range: searchRange).location
        let paragraphEnd = newline == NSNotFound ? string.length : newline
        let token = truncationToken(for: string, at: tokenStyleIndex)
        let tokenLine = CTLineCreateWithAttributedString(token)
        let rest = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: max(1, paragraphEnd - start)))
        if visibleWidth(rest) > width {
            return CTLineCreateTruncatedLine(rest, Double(width), .end, tokenLine) ?? rest
        }
        let combined = NSMutableAttributedString(
            attributedString: string.attributedSubstring(from: NSRange(location: start, length: paragraphEnd - start)))
        combined.append(token)
        let line = CTLineCreateWithAttributedString(combined)
        if visibleWidth(line) > width {
            return CTLineCreateTruncatedLine(line, Double(width), .end, tokenLine) ?? line
        }
        return line
    }

    private mutating func append(_ line: CTLine, origin: CGPoint, top: CGFloat) {
        lines.append(TextLine(line: line, origin: origin, top: top))
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return }
        for run in runs {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else { continue }
            if let emoji = attrs[TextAttribute.emoji.rawValue] as? EmojiAttachment {
                var positions = [CGPoint](repeating: .zero, count: glyphCount)
                CTRunGetPositions(run, CFRange(location: 0, length: glyphCount), &positions)
                for position in positions {
                    emojis.append(EmojiPlacement(
                        url: emoji.url,
                        rect: CGRect(x: origin.x + position.x, y: origin.y - emoji.ascent,
                                     width: emoji.width, height: emoji.height)))
                }
            }
            if let link = attrs[TextAttribute.link.rawValue] as? String {
                var position = CGPoint.zero
                CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &ascent, &descent, nil))
                let rect = CGRect(x: origin.x + position.x, y: origin.y - ascent, width: width, height: ascent + descent)
                if let last = links.last, last.link == link, abs(last.rect.maxX - rect.minX) < 1,
                   abs(last.rect.midY - rect.midY) < 4 {
                    links[links.count - 1] = LinkPlacement(link: link, rect: last.rect.union(rect))
                } else {
                    links.append(LinkPlacement(link: link, rect: rect))
                }
            }
            if attrs[TextAttribute.strikethrough.rawValue] != nil {
                var position = CGPoint.zero
                CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
                let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil))
                let font = attrs[TextAttribute.font.rawValue].map { $0 as! CTFont }
                let xHeight = font.map(CTFontGetXHeight) ?? 8
                let color = attrs[TextAttribute.foregroundColor.rawValue].map { $0 as! CGColor }
                strikes.append(StrikePlacement(
                    rect: CGRect(x: origin.x + position.x, y: origin.y - xHeight / 2 - 0.5, width: width, height: 1),
                    color: color ?? CGColor(gray: 0.5, alpha: 1)))
            }
        }
    }
}
