import CoreGraphics
import Foundation
import Testing
@testable import hibari

@Suite("Note layout")
struct NoteLayoutTests {
    @Test func everySampleNoteLaysOutInsideTheCanvas() {
        let engine = Samples.engine()
        let context = Samples.context()
        let layouts = engine.layouts(for: Samples.items, context: context)
        #expect(layouts.count == Samples.allNotes.count)
        for layout in layouts {
            #expect(layout.height.isFinite && layout.height > context.metrics.avatarSize)
            let rects = layout.blocks.map(\.frame) + layout.images.map(\.frame) + layout.decorations.map(\.frame)
            for rect in rects {
                #expect(rect.minX >= 0 && rect.maxX <= context.canvasWidth + 0.5, "\(layout.key.noteID) \(rect)")
                #expect(rect.minY >= 0 && rect.maxY <= layout.height + 0.5, "\(layout.key.noteID) \(rect)")
                #expect(rect.width > 0 && rect.height > 0)
            }
        }
    }

    @Test func framesArePixelAligned() {
        let engine = Samples.engine()
        let context = Samples.context()
        for layout in engine.layouts(for: Array(Samples.items.prefix(100)), context: context) {
            for rect in layout.blocks.map(\.frame) + layout.images.map(\.frame) {
                for value in [rect.minX, rect.minY, rect.width, rect.height] {
                    let pixels = value * context.displayScale
                    #expect(abs(pixels - pixels.rounded()) < 0.01, "\(rect) is not on the pixel grid")
                }
            }
            #expect(abs(layout.height * 3 - (layout.height * 3).rounded()) < 0.01)
        }
    }

    @Test func layoutIsDeterministic() {
        let items = Array(Samples.items.prefix(80))
        let context = Samples.context()
        let a = Samples.engine().layouts(for: items, context: context)
        let b = Samples.engine().layouts(for: items, context: context)
        #expect(a.map(\.height) == b.map(\.height))
        #expect(a.map { $0.blocks.map(\.frame) } == b.map { $0.blocks.map(\.frame) })
    }

    @Test func cacheReturnsTheSameResultForTheSameKey() throws {
        let engine = Samples.engine()
        let item = try #require(Samples.items.first)
        let context = Samples.context()
        #expect(engine.cachedLayout(for: item, context: context) == nil)
        let first = engine.layout(for: item, context: context)
        let cached = try #require(engine.cachedLayout(for: item, context: context))
        #expect(cached.key == first.key)
        #expect(engine.cachedLayout(for: item, context: Samples.context(width: 375)) == nil)
    }

    @Test func keyChangesWithEverythingThatAffectsLayout() throws {
        let item = try #require(Samples.items.first)
        let engine = Samples.engine()
        let base = engine.key(for: item, context: Samples.context())
        #expect(base != engine.key(for: item, context: Samples.context(width: 440)))
        #expect(base != engine.key(for: item, context: Samples.context(fontScale: 1.2)))
        #expect(base != engine.key(for: item, context: Samples.context(style: .light)))
        var expanded = item
        expanded.state.textExpanded = true
        #expect(base != engine.key(for: expanded, context: Samples.context()))
    }

    @Test func themeDoesNotChangeGeometry() {
        let items = Array(Samples.items.prefix(60))
        let dark = Samples.engine().layouts(for: items, context: Samples.context(style: .dark))
        let light = Samples.engine().layouts(for: items, context: Samples.context(style: .light))
        #expect(dark.map(\.height) == light.map(\.height))
    }

    @Test func largerTextMakesTheTimelineTaller() {
        let items = Array(Samples.items.prefix(60))
        let normal = Samples.engine().layouts(for: items, context: Samples.context())
        let large = Samples.engine().layouts(for: items, context: Samples.context(fontScale: 1.35))
        #expect(large.map(\.height).reduce(0, +) > normal.map(\.height).reduce(0, +))
    }

    @Test func narrowerCanvasNeverMakesNotesShorter() {
        let items = Samples.items
            .filter { $0.note?.files.isEmpty == true && $0.note?.renote == nil }
            .map { item in
                var item = item
                item.state.textExpanded = true
                return item
            }
        #expect(items.count > 20)
        let wide = Samples.engine().layouts(for: items, context: Samples.context(width: 440))
        let narrow = Samples.engine().layouts(for: items, context: Samples.context(width: 375))
        for (w, n) in zip(wide, narrow) {
            #expect(n.height >= w.height - 0.5, "\(w.key.noteID)")
        }
    }

    @Test func longNotesCollapse() throws {
        let context = Samples.context()
        let engine = Samples.engine()
        let long = TimelineItem(note: try Samples.makeNote(text: (1...40).map { "\($0)行目" }.joined(separator: "\n")))
        var expanded = long
        expanded.state.textExpanded = true
        let collapsed = engine.layout(for: long, context: context)
        let full = engine.layout(for: expanded, context: context)
        let lineHeight = Typography.shared(fontScale: 1, lineHeightMultiple: context.metrics.lineHeightMultiple)
            .lineMetrics(for: Typography.system(16)).lineHeight
        #expect(full.height - collapsed.height > lineHeight * 28)

        let short = TimelineItem(note: try Samples.makeNote(text: "短い"))
        var shortExpanded = short
        shortExpanded.state.textExpanded = true
        #expect(engine.layout(for: short, context: context).height == engine.layout(for: shortExpanded, context: context).height)
    }

    @Test func expandedLongNotesAreDrawnInPieces() throws {
        let context = Samples.context(fontScale: 3)
        let text = (1...300).map { "\($0) @u\($0)" }.joined(separator: "\n")
        var item = TimelineItem(note: try Samples.makeNote(text: text))
        item.state.textExpanded = true
        let layout = Samples.engine().layout(for: item, context: context)
        #expect(layout.height * 3 > CGFloat(Rasterizer.maxPixelDimension))
        for block in layout.blocks {
            #expect(Rasterizer.render(block, palette: context.palette, scale: 3) { _ in nil } != nil)
        }
        var baselines: [CGFloat] = []
        for block in layout.blocks {
            for case .text(let text, let origin) in block.ops where !text.links.isEmpty {
                baselines += text.lines.map { block.frame.minY + origin.y + $0.origin.y }
            }
        }
        let typography = Typography.shared(fontScale: 3, lineHeightMultiple: context.metrics.lineHeightMultiple)
        let lineHeight = typography.lineMetrics(for: typography.body).lineHeight
        #expect(baselines.count == 300)
        #expect(zip(baselines, baselines.dropFirst()).allSatisfy { abs($1 - $0 - lineHeight) < 1 })
        let links = layout.targets.compactMap { target -> String? in
            if case .link(let link) = target.action { link } else { nil }
        }
        #expect(Set(links).count == 300)
    }

    @Test func contentWarningHidesTheBody() throws {
        let context = Samples.context()
        let engine = Samples.engine()
        let item = TimelineItem(note: try Samples.makeNote(text: String(repeating: "本文\n", count: 8), cw: "ネタバレ"))
        var expanded = item
        expanded.state.cwExpanded = true
        #expect(engine.layout(for: item, context: context).height < engine.layout(for: expanded, context: context).height)
        #expect(engine.layout(for: item, context: context).accessibility.label(at: Samples.now).contains("ネタバレ"))
    }

    @Test func sensitiveMediaIsNotRequestedUntilRevealed() throws {
        let note = try #require(Samples.firstNote {
            !$0.isPureRenote && $0.cw == nil && $0.files.prefix(3).contains(where: \.isSensitive)
        })
        let item = TimelineItem(note: note)
        let hidden = Samples.engine().layout(for: item, context: Samples.context())
        let revealed = Samples.engine().layout(for: item, context: Samples.context(revealsSensitiveMedia: true))
        #expect(hidden.images.contains { $0.overlay == .sensitive && $0.request == nil })
        #expect(!revealed.images.contains { $0.overlay == .sensitive })
        #expect(revealed.imageRequests.count > hidden.imageRequests.count)
    }

    @Test func pureRenoteShowsTheRenotedAuthor() throws {
        let note = try #require(Samples.firstNote { $0.isPureRenote })
        let layout = Samples.engine().layout(for: TimelineItem(note: note), context: Samples.context())
        let avatar = try #require(layout.images.first)
        #expect(avatar.request?.url == note.renote?.user.avatarUrl)
        #expect(avatar.request?.shape == .circle)
        #expect(layout.accessibility.label(at: Samples.now).contains("がリノート"))
    }

    @Test func quoteBoxWrapsTheQuotedNote() throws {
        let note = try #require(Samples.firstNote {
            $0.renote != nil && !$0.isPureRenote && $0.files.isEmpty && $0.cw == nil
        })
        let layout = Samples.engine().layout(for: TimelineItem(note: note), context: Samples.context())
        let box = try #require(layout.decorations.last)
        let quoteAvatar = try #require(layout.images.dropFirst().first)
        #expect(box.frame.contains(quoteAvatar.frame))
    }

    @Test func mediaGrid() {
        let width: CGFloat = 326
        func frames(_ count: Int, aspect: Double? = nil) -> [CGRect] {
            MediaGrid.frames(count: count, width: width, gap: 2, firstAspect: aspect)
        }
        #expect(frames(1, aspect: 2).first?.height == (width * 0.5).rounded())
        #expect(frames(1, aspect: 0.2).first?.height == (width * 1.25).rounded())
        #expect(frames(2).count == 2)
        let three = frames(3)
        #expect(three[0].height == three[1].height + three[2].height + 2)
        let four = frames(4)
        #expect(four.map(\.maxX).max()! <= width + 0.001)
        #expect(Set(four.map(\.width)).count == 1)
    }

    @Test func emojiLaidOutWithAGuessedSizeIsRedoneOnceTheSizeIsKnown() throws {
        let (name, url) = try #require(Samples.emojis.first)
        let sizes = FakeMediaSizes()
        let engine = NoteLayoutEngine(emojiResolver: EmojiResolver(localEmojis: [name: url], mediaProxy: nil), sizes: sizes)
        let item = TimelineItem(note: try Samples.makeNote(text: "猫 :\(name): です"))
        let context = Samples.context()
        func emojiWidth(_ layout: NoteLayout) -> CGFloat? {
            layout.blocks.lazy.flatMap(\.ops).compactMap { op -> CGFloat? in
                guard case .text(let text, _) = op else { return nil }
                return text.emojis.first?.rect.width
            }.first
        }

        let guessed = engine.layout(for: item, context: context)
        #expect(guessed.provisionalEmojis == [url])
        #expect(engine.emojiSizesAreCurrent(in: guessed))
        #expect(engine.layout(for: item, context: context).serial == guessed.serial, "cached while still unknown")

        sizes.set(.known(CGSize(width: 300, height: 100)), for: url)
        #expect(!engine.emojiSizesAreCurrent(in: guessed))
        let exact = engine.layout(for: item, context: context)
        #expect(exact.key == guessed.key && exact.serial != guessed.serial)
        #expect(exact.provisionalEmojis.isEmpty)
        let guessedWidth = try #require(emojiWidth(guessed))
        #expect(try #require(emojiWidth(exact)) > guessedWidth * 2)
    }

    @Test func headerAlwaysKeepsTheTimestampVisible() throws {
        let note = try #require(Samples.firstNote { !$0.isPureRenote && $0.user.displayName.count > 12 })
        let context = Samples.context(width: 320)
        let layout = Samples.engine().layout(for: TimelineItem(note: note), context: context)
        let header = try #require(layout.blocks.first)
        var textEnd: CGFloat = 0
        for op in header.ops {
            if case .text(let text, let origin) = op {
                textEnd = max(textEnd, header.frame.minX + origin.x + text.size.width)
            }
        }
        let time = try #require(layout.timeSlots.first)
        #expect(time.origin.x >= textEnd - 0.5, "after the name and handle")
        #expect(time.origin.x + time.reservedWidth <= header.frame.maxX + 0.5)
    }

    @Test func relativeTimesAreSlotsOutsideTheBlocks() throws {
        let note = try #require(Samples.firstNote { $0.renote != nil && !$0.isPureRenote })
        let layout = Samples.engine().layout(for: TimelineItem(note: note), context: Samples.context())
        #expect(layout.timeSlots.count >= 2, "the note and its quote")
        let header = try #require(layout.blocks.first { $0.frame.minY <= layout.timeSlots[0].origin.y })
        #expect(layout.timeSlots[0].origin.y == header.frame.minY)
        let created = note.createdAt
        #expect(layout.timeSlots[0].text(at: created.addingTimeInterval(300)) == " · 5分")
        #expect(layout.timeSlots[0].text(at: created.addingTimeInterval(7200)) == " · 2時間")
        #expect(layout.timeSlots[0].nextChange(after: created.addingTimeInterval(300)) == created.addingTimeInterval(360))
        #expect(layout.timeSlots[0].text(at: created.addingTimeInterval(8 * 86400 + 60)) == " · 8日")
    }

    @Test func emojiThatCannotLoadIsShownAsItsName() throws {
        let (name, url) = try #require(Samples.emojis.first)
        let sizes = FakeMediaSizes()
        sizes.set(.unavailable, for: url)
        let engine = NoteLayoutEngine(emojiResolver: EmojiResolver(localEmojis: [name: url], mediaProxy: nil), sizes: sizes)
        let layout = engine.layout(for: TimelineItem(note: try Samples.makeNote(text: "猫 :\(name): です")),
                                   context: Samples.context())
        #expect(layout.emojiRequests.isEmpty)
        #expect(layout.provisionalEmojis.isEmpty)
    }

    @Test func customEmojisCoverEveryEmojiALayoutSizes() {
        let sizes = FakeMediaSizes()
        let engine = NoteLayoutEngine(
            emojiResolver: EmojiResolver(localEmojis: Samples.emojis, mediaProxy: Samples.mediaProxy), sizes: sizes)
        let items = Samples.items
        let usage = engine.customEmojis(in: items)
        #expect(!usage.text.isEmpty && !usage.reactions.isEmpty)
        for url in usage.text.union(usage.reactions) {
            sizes.set(.known(CGSize(width: 64, height: 64)), for: url)
        }
        let layouts = engine.layouts(for: items, context: Samples.context())
        #expect(layouts.allSatisfy { $0.provisionalEmojis.isEmpty })
    }
}
