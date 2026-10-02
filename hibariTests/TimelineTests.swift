import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import hibari

@Suite("Timeline")
struct TimelineTests {

    @Test func relativeTimeChangesExactlyWhenPredicted() {
        let created = Date(timeIntervalSinceReferenceDate: 0)
        for age: TimeInterval in [0, 5.5, 59, 60, 61, 3599, 3600, 7300, 86399, 86400, 6 * 86400 + 5] {
            let now = created.addingTimeInterval(age)
            let next = RelativeTime.nextChange(created, now: now)
            #expect(next > now)
            let label = RelativeTime.format(created, now: now)
            #expect(RelativeTime.format(created, now: next.addingTimeInterval(-0.01)) == label, "age \(age)")
            #expect(RelativeTime.format(created, now: next) != label, "age \(age)")
        }
        #expect(RelativeTime.nextChange(created, now: created.addingTimeInterval(8 * 86400)) == .distantFuture)
    }

    @Test func pollDurationChangesExactlyWhenPredicted() {
        for remaining: TimeInterval in [30, 119, 120, 150, 3599, 3600, 5000, 86400, 200_000] {
            let wait = RelativeTime.durationNextChange(remaining)
            let label = RelativeTime.duration(remaining)
            let change = remaining - wait
            #expect(RelativeTime.duration(change + 0.01) == label, "remaining \(remaining)")
            #expect(change <= 0 || RelativeTime.duration(change - 0.01) != label, "remaining \(remaining)")
        }
    }

    @Test func layoutKeysDoNotFollowTheClock() throws {
        let engine = Samples.engine()
        let context = Samples.context()
        let item = TimelineItem(note: try Samples.makeNote(text: "a"))
        let created = try #require(item.note).createdAt
        let key = engine.key(for: item, context: context, now: created.addingTimeInterval(30))
        for later: TimeInterval in [59, 3600, 86400, 6 * 86400] {
            #expect(engine.key(for: item, context: context, now: created.addingTimeInterval(later)) == key)
        }
        let asDate = engine.key(for: item, context: context, now: created.addingTimeInterval(8 * 86400))
        #expect(asDate != key && asDate.timeStyles.created == .date)
        #expect(!asDate.requiresImmediateRelayout(from: key))
        let nextYear = try #require(Calendar(identifier: .gregorian).date(byAdding: .year, value: 1, to: created))
        #expect(engine.key(for: item, context: context, now: nextYear).timeStyles.created == .dateWithYear)
    }

    private func layouts(_ items: [TimelineItem], width: CGFloat = 402) -> [NoteLayout] {
        Samples.engine().layouts(for: items, context: Samples.context(width: width))
    }

    @Test func prependingPutsNewNotesFirst() {
        let items = Array(Samples.distinctItems.prefix(6))
        var entries = TimelineEntries()
        entries.append(Array(items[2...]), layouts: layouts(Array(items[2...])))
        let known = entries.layouts[0]
        let fresh = Array(items.prefix(3))
        #expect(entries.prepend(fresh, layouts: layouts(fresh)) == 2)
        #expect(entries.items.map(\.id) == items.map(\.id))
        #expect(entries.layouts[2].serial == known.serial)
        #expect(entries.contains(items[0].id))
        #expect(entries.prepend(fresh, layouts: layouts(fresh)) == 0, "nothing new")

        let engine = Samples.engine()
        let wider = Samples.context(width: 440)
        let relaid = engine.layouts(for: Array(items[2...]), context: wider)
        let expected = { (item: TimelineItem) in engine.key(for: item, context: wider) }
        #expect(entries.integrate(relaid, onScreen: [], expectedKey: expected) == Array(2..<6))

        entries.replaceAll(with: Array(items.prefix(2)), layouts: layouts(Array(items.prefix(2))))
        #expect(entries.items.map(\.id) == items.prefix(2).map(\.id) && !entries.contains(items[3].id))
    }

    @Test func freshLayoutsAreIntegratedByKeyAndStaleOnesIgnored() {
        let items = Array(Samples.distinctItems.prefix(8))
        var entries = TimelineEntries()
        entries.append(Array(items.prefix(5)), layouts: layouts(Array(items.prefix(5)), width: 375))
        let relaid = layouts(Array(items.prefix(5)), width: 402)
        entries.append(Array(items.suffix(3)), layouts: layouts(Array(items.suffix(3)), width: 402))

        let engine = Samples.engine()
        let context = Samples.context(width: 402)
        let expected = { (item: TimelineItem) in engine.key(for: item, context: context) }
        #expect(entries.integrate(relaid, onScreen: [], expectedKey: expected) == Array(0..<5))
        #expect(zip(entries.items, entries.layouts).allSatisfy { $1.key == expected($0) })

        #expect(entries.integrate(layouts(items, width: 440), onScreen: [], expectedKey: expected).isEmpty)
        #expect(entries.integrate(relaid, onScreen: [], expectedKey: expected).isEmpty, "already applied")
    }

    @Test func onScreenNotesKeepTheirLayoutUntilTheyLeave() throws {
        let (name, url) = try #require(Samples.emojis.first)
        let sizes = FakeMediaSizes()
        let engine = NoteLayoutEngine(emojiResolver: EmojiResolver(localEmojis: [name: url], mediaProxy: nil), sizes: sizes)
        let items = try (0..<3).map { _ in TimelineItem(note: try Samples.makeNote(text: "猫 :\(name): です")) }
        let context = Samples.context()
        var entries = TimelineEntries()
        entries.append(items, layouts: engine.layouts(for: items, context: context))
        let expected = { (item: TimelineItem) in engine.key(for: item, context: context) }
        func stale(_ expectedKey: (TimelineItem) -> LayoutKey) -> (now: [Int], deferred: [Int]) {
            entries.staleIndices(onScreen: [1], expectedKey: expectedKey, emojiSizesAreCurrent: engine.emojiSizesAreCurrent(in:))
        }
        #expect(stale(expected).now.isEmpty && stale(expected).deferred.isEmpty)

        sizes.set(.known(CGSize(width: 300, height: 100)), for: url)
        #expect(stale(expected).now == [0, 2] && stale(expected).deferred == [1])
        let relaid = engine.layouts(for: items, context: context)
        #expect(entries.integrate(relaid, onScreen: [1], expectedKey: expected) == [0, 2], "note 1 is on screen")
        #expect(entries.integrate(relaid, onScreen: [], expectedKey: expected) == [1], "note 1 left the screen")

        let wider = Samples.context(width: 440)
        let widerKey = { (item: TimelineItem) in engine.key(for: item, context: wider) }
        #expect(stale(widerKey).now == [0, 1, 2] && stale(widerKey).deferred.isEmpty)
        #expect(entries.integrate(engine.layouts(for: items, context: wider), onScreen: [1], expectedKey: widerKey) == [0, 1, 2])
    }

    private func renote(_ id: String, of note: Note) throws -> TimelineItem {
        let object: [String: Any] = [
            "id": id, "createdAt": "2026-09-23T15:00:00.000Z",
            "user": ["id": "r", "username": "renoter"], "renoteId": note.id,
            "renote": try JSONSerialization.jsonObject(with: MisskeyJSON.encoder().encode(note)),
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return TimelineItem(note: try MisskeyJSON.decoder().decode(Note.self, from: data))
    }

    @Test func aNoteShowsOnceWhereItCameFirst() throws {
        let notes = Samples.distinctItems.compactMap(\.note).filter { $0.renote == nil }
        let (a, b, c) = (notes[5], notes[6], notes[7])
        let renoteOfB = try renote("x-1", of: b)
        var entries = TimelineEntries()
        let batch = [renoteOfB, TimelineItem(note: b), TimelineItem(note: c)]
        entries.append(batch, layouts: layouts(batch))
        #expect(entries.items.map(\.id) == ["x-1", c.id])
        #expect(entries.showsNote(of: TimelineItem(note: b)))

        let fresh = [TimelineItem(note: a), try renote("x-2", of: b)]
        #expect(entries.prepend(fresh, layouts: layouts(fresh)) == 1)
        #expect(entries.items.map(\.id) == [a.id, "x-1", c.id])

        _ = entries.remove(deleted: "x-1")
        #expect(!entries.showsNote(of: TimelineItem(note: b)))
        entries.append([TimelineItem(note: b)], layouts: layouts([TimelineItem(note: b)]))
        #expect(entries.items.map(\.id) == [a.id, c.id, b.id])
    }

    private func entries(_ ids: [Int]) -> (TimelineEntries, [TimelineItem]) {
        let all = Samples.distinctItems
        let items = ids.map { all[$0] }
        var entries = TimelineEntries()
        entries.append(items, layouts: layouts(items))
        return (entries, all)
    }

    @Test func gapsSitBetweenTheirEdgesAndCloseWhenFilled() throws {
        var (entries, all) = entries(Array(20..<25))
        let top = Array(all[0..<3])
        #expect(entries.prepend(top, layouts: layouts(top), gapBelow: (all[2].id, all[20].id)) == 3)
        let gap = try #require(entries.gaps.first)
        #expect(entries.position(of: gap) == 2)
        #expect(entries.gapPlacements == [.init(id: gap.id, afterItem: 2)])

        let upper = Array(all[3..<6])
        #expect(entries.fill(gap.id, with: upper, layouts: layouts(upper), fromNewer: true, edge: all[5].id,
                             closes: false) == 3..<6)
        #expect(entries.position(of: try #require(entries.gap(gap.id))) == 5)
        let lower = Array(all[15..<20])
        #expect(entries.fill(gap.id, with: lower, layouts: layouts(lower), fromNewer: false, edge: all[15].id,
                             closes: false) == 6..<11)
        let shrunk = try #require(entries.gap(gap.id))
        #expect(entries.position(of: shrunk) == 5 && shrunk.newerID == all[5].id && shrunk.olderID == all[15].id)
        let rest = [all[1]] + Array(all[6..<15]) + [all[22]]
        #expect(entries.fill(gap.id, with: rest, layouts: layouts(rest), fromNewer: true, edge: all[14].id,
                             closes: true) == 6..<15)
        #expect(entries.gaps.isEmpty)
        #expect(entries.items.map(\.id) == all[0..<25].map(\.id))
    }

    @Test func gapsWithNothingBetweenThemMergeAndOnesWithNothingBelowGo() throws {
        var (entries, all) = entries(Array(20..<23))
        entries.prepend([], layouts: [], gapBelow: (all[15].id, all[20].id))
        #expect(entries.gapPlacements.map(\.afterItem) == [-1])
        entries.prepend([], layouts: [], gapBelow: (all[5].id, all[10].id))
        let merged = try #require(entries.gaps.first)
        #expect(entries.gaps.count == 1 && merged.newerID == all[5].id && merged.olderID == all[20].id)

        let top = Array(all[0..<2])
        entries.prepend(top, layouts: layouts(top), gapBelow: (all[1].id, all[2].id))
        #expect(entries.gapPlacements.map(\.afterItem) == [1])
        #expect(entries.gaps.first?.newerID == all[1].id && entries.gaps.first?.olderID == all[20].id)

        for item in all[20..<23] { _ = entries.remove(deleted: item.id) }
        let removed = entries.removeTrailingGap()
        let trailing = try #require(removed)
        #expect(trailing.newerID == all[1].id && entries.gaps.isEmpty)
    }

    @MainActor
    @Test func theListLayoutLeavesRoomForGaps() {
        let layout = TimelineCollectionLayout()
        layout.setHeights([100, 50, 80], gaps: [.init(id: 7, afterItem: -1), .init(id: 9, afterItem: 1)])
        let gap = TimelineCollectionLayout.gapHeight
        #expect(layout.frame(ofGap: 7)?.minY == 0)
        #expect(layout.offset(ofItem: 0) == gap)
        #expect(layout.offset(ofItem: 2) == gap + 150 + gap)
        #expect(layout.frame(ofGap: 9)?.minY == gap + 150)
        #expect(layout.firstItem(endingBelow: gap + 160) == 2)
        #expect(layout.firstItem(endingBelow: 10_000) == nil)
        layout.appendHeights([40])
        #expect(layout.offset(ofItem: 3) == gap + 150 + gap + 80)
        #expect(layout.gapIDs == [7, 9])
    }

    @MainActor
    @Test func newNotesAvatarsAreLoadedBeforeTheyShow() async throws {
        let pipeline = ImagePipeline(source: DownloadingMediaSource(base: SampleMediaSource(), delay: .milliseconds(50)),
                                     diskDirectory: TestData.temporaryDirectory())
        let button = NewNotesButton(imagePipeline: pipeline)
        func user(_ id: String, _ avatarUrl: String) -> User {
            User(id: id, name: nil, username: id, host: nil, avatarUrl: avatarUrl)
        }
        let a = user("a", "https://media.example/a.png?w=96&h=96")
        let missing = user("b", "https://missing.example/b.png")
        let c = user("c", "https://media.example/c.png?w=64&h=64")
        let d = user("d", "https://media.example/d.png?w=64&h=64")
        button.loadAvatars(of: [d]) { _ in Issue.record("a replaced load called back") }
        let ready = await withCheckedContinuation { continuation in
            button.loadAvatars(of: [a, missing, c, d]) { continuation.resume(returning: $0) }
        }
        #expect(ready.map(\.id) == ["a", "c"])
        #expect(!button.isLoadingAvatars)
        let scale = button.traitCollection.displayScale > 0 ? button.traitCollection.displayScale : 3
        let size = CGSize(width: NewNotesButton.avatarSize, height: NewNotesButton.avatarSize)
        for user in ready {
            let request = AvatarView.request(url: try #require(user.avatarUrl), size: size, scale: scale)
            #expect(pipeline.cachedImage(for: request) != nil)
        }
    }

    @Test func snapshotsKeepNotesAsTheyWere() throws {
        let notes = Samples.allNotes.prefix(40)
        let directory = TestData.temporaryDirectory()
        let store = TimelineSnapshotStore(accountID: "me@misskey.example", timelineID: "home", directory: directory)
        let seen = Date(timeIntervalSinceReferenceDate: 812_000_000.25)
        store.save(TimelineSnapshot(notes: Array(notes), gaps: [.init(newerID: "n00100", olderID: "n00090")],
                                    newestID: "n00119", cursor: "n00080", shown: ["n00050": seen]))
        let loaded = try #require(store.load())
        #expect(loaded.notes.map { TimelineItem(note: $0).contentHash } == notes.map { TimelineItem(note: $0).contentHash })
        #expect(zip(loaded.notes, notes).allSatisfy { $0.createdAt == $1.createdAt && $0.files.count == $1.files.count })
        #expect(loaded.gaps.first?.olderID == "n00090" && loaded.newestID == "n00119" && loaded.cursor == "n00080")
        #expect(loaded.shown["n00050"] == seen)

        TimelineSnapshotStore.removeAll(accountID: "me@misskey.example", directory: directory)
        #expect(store.load() == nil)
    }
}
