import CoreGraphics
import Foundation
import Testing
@testable import hibari

@Suite("Note layout")
struct NoteLayoutTests {
    @Test func sampleNotesStayInsideTheCanvasAndOnThePixelGrid() {
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
            for rect in layout.blocks.map(\.frame) + layout.images.map(\.frame) {
                for value in [rect.minX, rect.minY, rect.width, rect.height] {
                    let pixels = value * context.displayScale
                    #expect(abs(pixels - pixels.rounded()) < 0.01, "\(rect) is not on the pixel grid")
                }
            }
            #expect(abs(layout.height * 3 - (layout.height * 3).rounded()) < 0.01)
        }
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

    @Test func longNotesCollapseAndRespectTheTextScale() throws {
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
        #expect(engine.layout(for: expanded, context: Samples.context(fontScale: 1.35)).height > full.height)

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
        let hidden = engine.layout(for: item, context: context)
        let revealed = engine.layout(for: expanded, context: context)
        #expect(hidden.height < revealed.height)
        #expect(hidden.accessibility.label(at: Samples.now).contains("ネタバレ"))
        #expect(hidden.targets.contains { $0.action == .toggleCW })
        #expect(revealed.targets.contains { $0.action == .toggleCW })
    }

    @Test func pollChoicesTakeVotesAndHideResultsUntilAsked() throws {
        let context = Samples.context()
        let engine = Samples.engine()
        func layout(_ voted: [Bool], multiple: Bool = false, expiresIn: TimeInterval? = 3600,
                    peeking: Bool = false) throws -> NoteLayout {
            let formatter = ISO8601DateFormatter()
            var poll: [String: Any] = [
                "multiple": multiple,
                "choices": voted.enumerated().map { ["text": "選択肢\($0)", "votes": $1 ? 3 : 1, "isVoted": $1] },
            ]
            if let expiresIn { poll["expiresAt"] = formatter.string(from: Samples.now.addingTimeInterval(expiresIn)) }
            var item = TimelineItem(note: try Samples.makeNote(text: "どれ？", poll: poll))
            item.state.pollResultsShown = peeking
            return engine.layout(for: item, context: context, now: Samples.now)
        }
        func votes(_ layout: NoteLayout) -> [Int] {
            layout.targets.compactMap { if case .vote(let index) = $0.action { index } else { nil } }
        }
        func toggles(_ layout: NoteLayout) -> Bool { layout.targets.contains { $0.action == .togglePollResults } }

        let fresh = try layout([false, false, false])
        #expect(votes(fresh) == [0, 1, 2] && toggles(fresh))
        let peeking = try layout([false, false, false], peeking: true)
        #expect(votes(peeking) == [0, 1, 2] && toggles(peeking), "results can be seen before voting")
        #expect(peeking.height == fresh.height, "showing the results does not move the note")

        let voted = try layout([false, true, false])
        #expect(votes(voted).isEmpty && !toggles(voted))
        let votedMultiple = try layout([false, true, false], multiple: true)
        #expect(votes(votedMultiple) == [0, 2] && !toggles(votedMultiple))
        let ended = try layout([false, false, false], expiresIn: -60)
        #expect(votes(ended).isEmpty && !toggles(ended))
        let open = try layout([false, false], expiresIn: nil)
        #expect(votes(open) == [0, 1])
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
        #expect(engine.isCurrent(guessed))
        #expect(engine.layout(for: item, context: context).serial == guessed.serial, "cached while still unknown")

        sizes.set(.known(CGSize(width: 300, height: 100)), for: url)
        #expect(!engine.isCurrent(guessed))
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
