import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import hibari

@Suite("Reactions")
struct ReactionModelTests {
    @Test func reactionsAreStoredTheWayMisskeyStoresThem() {
        #expect(ReactionKey.stored("❤️") == "❤")
        #expect(ReactionKey.stored("👍") == "👍")
        #expect(ReactionKey.stored("❤️‍🔥") == "❤️‍🔥")
        #expect(ReactionKey.stored(":blobcat:") == ":blobcat@.:")
        #expect(ReactionKey.stored(":ai@remote.example:") == ":ai@remote.example:")
        #expect(ReactionKey.customName(":blobcat@.:") == "blobcat")
        #expect(ReactionKey.customName("👍") == nil)
        #expect(ReactionKey.isRemote(":ai@remote.example:"))
        #expect(!ReactionKey.isRemote(":blobcat@.:") && !ReactionKey.isRemote("👍"))
    }

    @Test func reactingMovesTheUsersCount() {
        let start = ReactionChange(noteID: "n", reactions: ["👍": 2, "❤": 1], reactionEmojis: [:], myReaction: nil)
        let liked = start.reacting("❤")
        #expect(liked.reactions == ["👍": 2, "❤": 2] && liked.myReaction == "❤")
        let switched = liked.reacting("🎉")
        #expect(switched.reactions == ["👍": 2, "❤": 1, "🎉": 1] && switched.myReaction == "🎉")
        let removed = switched.reacting(nil)
        #expect(removed.reactions == ["👍": 2, "❤": 1] && removed.myReaction == nil)
        #expect(removed.reacting(nil) == removed)
    }

    @Test func changesReachEveryCopyOfTheNote() throws {
        let renote = try #require(Samples.firstNote { $0.isPureRenote })
        let target = try #require(renote.renote)
        let change = ReactionChange(target).reacting("👍")

        let updated = renote.applying(change)
        #expect(updated !== renote)
        #expect(updated.renote?.myReaction == "👍")
        #expect(updated.renote?.reactions["👍"] == (target.reactions["👍"] ?? 0) + 1)
        #expect(updated.id == renote.id && updated.text == renote.text)
        #expect(updated.contains(noteID: target.id))

        let unrelated = try #require(Samples.firstNote { !$0.contains(noteID: target.id) })
        #expect(unrelated.applying(change) === unrelated)
    }

    @Test func timelineEntriesPickUpReactionsAndKeepTheirState() throws {
        let items = Array(Samples.items.prefix(12))
        var entries = TimelineEntries()
        entries.append(items, layouts: Samples.engine().layouts(for: items, context: Samples.context()))
        entries.updateState(at: 2) { $0.cwExpanded = true }
        let note = try #require(entries.items[2].note).displayedNote
        let before = entries.items[2].contentHash

        let changed = entries.apply(ReactionChange(note).reacting("🎉"))
        #expect(changed)
        #expect(entries.items[2].note?.displayedNote.myReaction == "🎉")
        #expect(entries.items[2].state.cwExpanded, "display state survives")
        #expect(entries.items[2].contentHash != before, "the layout goes out of date")
        let unrelated = entries.apply(ReactionChange(noteID: "nope", reactions: [:], reactionEmojis: [:], myReaction: nil))
        #expect(!unrelated)
    }
}

@Suite("Renotes")
struct RenoteTests {
    private func renoteIcon(_ layout: NoteLayout) -> ColorRole? {
        layout.blocks.flatMap(\.ops).lazy.compactMap { op -> ColorRole? in
            if case .icon(.renote, _, let color) = op { return color }
            return nil
        }.first
    }

    @Test func aRenoteShowsOnTheButtonAndItsCount() throws {
        let plain = try #require(Samples.firstNote { !$0.isPureRenote && !$0.isRenotedByMe })
        let engine = Samples.engine()
        let before = engine.layout(for: TimelineItem(note: plain), context: Samples.context())
        #expect(renoteIcon(before) == .secondaryText)

        let renoted = plain.applying(RenoteChange(noteID: plain.id, isRenoted: true, renoteCount: plain.renoteCount + 1))
        #expect(renoted.isRenotedByMe && renoted.renoteCount == plain.renoteCount + 1)
        #expect(TimelineItem(note: renoted).contentHash != TimelineItem(note: plain).contentHash)
        let after = engine.layout(for: TimelineItem(note: renoted), context: Samples.context())
        #expect(renoteIcon(after) == .renote)
        #expect(after.accessibility.label(at: Date()).contains("リノート済み"))

        let back = renoted.applying(RenoteChange(noteID: plain.id, isRenoted: false, renoteCount: nil))
        #expect(!back.isRenotedByMe && back.renoteCount == plain.renoteCount + 1)
        #expect(back.applying(RenoteChange(noteID: plain.id, isRenoted: false, renoteCount: nil)) === back)

        let uncounted = try #require(Samples.firstNote { !$0.isPureRenote && $0.renoteCount == 0 })
        #expect(uncounted.with(isRenotedByMe: true).renoteCount == 1)
    }

    @MainActor
    @Test func theControllerLearnsTheAccountsRenotesFromTimelines() throws {
        let renote = try #require(Samples.firstNote { $0.isPureRenote && $0.user.host == nil })
        let target = try #require(renote.renote)
        let controller = RenoteController(accountUserID: renote.user.id)
        #expect(!controller.isRenoted(target))
        controller.learn(from: [renote])
        #expect(controller.isRenoted(target))
        #expect(controller.state(of: target.id) == .renoted(renote.id), "known by id: it can be taken back")
        #expect(controller.marked(target).isRenotedByMe)

        controller.set(.deleting(renote.id), for: target.id, renoteCount: nil)
        #expect(!controller.isRenoted(target.with(isRenotedByMe: true)), "copies that say otherwise are out of date")
        #expect(controller.isBusy(target))
        controller.set(.notRenoted, for: target.id, renoteCount: nil)
        controller.learn(from: [renote])
        #expect(!controller.isRenoted(target), "what the app did wins over what came in")
    }

    @Test func aDeletedNoteTakesItsRenotesAndRepliesAlong() throws {
        let items = Samples.items
        let renoteIDs = items.compactMap { $0.note?.renoteId }
        let renoted = try #require(renoteIDs.first)
        var entries = TimelineEntries()
        entries.append(items, layouts: Samples.engine().layouts(for: items, context: Samples.context()))
        let gone = entries.items.filter { $0.isGone(afterDeleting: renoted) }
        let count = entries.count
        #expect(!gone.isEmpty)
        let removed = entries.remove(deleted: renoted)
        #expect(removed.count == gone.count && removed == removed.sorted())
        #expect(entries.count == count - gone.count)
        #expect(gone.allSatisfy { !entries.contains($0.id) })
    }
}

@Suite("Tap targets")
struct TapTargetTests {
    private func layout(_ note: Note, state: NoteDisplayState = NoteDisplayState()) -> NoteLayout {
        Samples.engine().layout(for: TimelineItem(note: note, state: state), context: Samples.context())
    }

    @Test func mediaTilesOpenTheirOwnFile() throws {
        let note = try #require(Samples.firstNote { $0.visualFiles.count >= 3 && !$0.files.contains(where: \.isSensitive) })
        let layout = layout(note)
        for index in 0..<min(4, note.visualFiles.count) {
            let media = MediaRef(owner: .note, index: index)
            let slot = try #require(layout.slotIndex(of: media).map { layout.images[$0] })
            #expect(layout.action(at: CGPoint(x: slot.frame.midX, y: slot.frame.midY)) == .media(media))
        }
        #expect(layout.images[0].media == nil)
    }

    @Test func hiddenSensitiveMediaRevealsFirst() throws {
        let note = try #require(Samples.firstNote { $0.files.first?.isSensitive == true && $0.cw == nil })
        let hidden = layout(note)
        let slot = try #require(hidden.slotIndex(of: MediaRef(owner: .note, index: 0)).map { hidden.images[$0] })
        let center = CGPoint(x: slot.frame.midX, y: slot.frame.midY)
        #expect(hidden.action(at: center) == .revealSensitive)
        var revealed = NoteDisplayState()
        revealed.sensitiveRevealed = true
        #expect(layout(note, state: revealed).action(at: center) == .media(MediaRef(owner: .note, index: 0)))
    }

    @Test func actionBarButtonsAndChipsAreTappable() throws {
        let note = try #require(Samples.firstNote { $0.reactions.count >= 2 && !$0.isPureRenote })
        let layout = layout(note)
        let actions = Set(layout.targets.map(\.action))
        for action in [NoteTapAction.reply, .renote, .react, .bookmark, .share, .more] {
            #expect(actions.contains(action), "\(action)")
        }
        for key in note.reactions.keys {
            let chip = try #require(layout.targets.first { $0.action == .reaction(key) })
            #expect(layout.action(at: CGPoint(x: chip.frame.midX, y: chip.frame.midY)) == .reaction(key))
        }
        let react = try #require(layout.targets.first { $0.action == .react })
        #expect(react.frame.width >= 44 && react.frame.height >= 36)
    }

    private func icons(_ layout: NoteLayout) -> [Icon] {
        layout.blocks.flatMap(\.ops).compactMap { op in
            if case .icon(let icon, _, _) = op { return icon }
            return nil
        }
    }

    @Test func aNoteThatTakesLikesOnlyHasAHeartAndNoChips() throws {
        var object = TestData.note(id: "n1")
        object["reactions"] = ["❤": 2, "🎉": 1]
        object["reactionAcceptance"] = "likeOnly"
        let note = try MisskeyJSON.decoder().decode(Note.self, from: JSONSerialization.data(withJSONObject: object))
        let plain = layout(note)
        #expect(!plain.targets.contains { if case .reaction = $0.action { true } else { false } })
        #expect(icons(plain).contains(.like) && !icons(plain).contains(.reaction))
        #expect(icons(layout(note.applying(ReactionChange(note).reacting(ReactionKey.like)))).contains(.liked))
        let saved = try MisskeyJSON.decoder().decode(Note.self, from: MisskeyJSON.encoder().encode(note))
        #expect(saved.isLikeOnly)
    }

    @Test func quotesOpenExceptForTheirMedia() throws {
        let note = try #require(Samples.firstNote { note in
            guard let quoted = note.renote, !note.isPureRenote else { return false }
            return quoted.cw == nil && !quoted.visualFiles.isEmpty && !quoted.files.contains(where: \.isSensitive)
        })
        let layout = layout(note)
        let box = try #require(layout.targets.first { $0.action == .quote })
        #expect(layout.action(at: CGPoint(x: box.frame.minX + 4, y: box.frame.minY + 4)) == .quote)
        let media = MediaRef(owner: .quote, index: 0)
        let slot = try #require(layout.slotIndex(of: media).map { layout.images[$0] })
        #expect(layout.action(at: CGPoint(x: slot.frame.midX, y: slot.frame.midY)) == .media(media))
    }

    @Test func linksMentionsAndHashtagsInTheText() throws {
        let note = try Samples.makeNote(text: "#hibari と @alice と https://example.com/page")
        let links = Set(layout(note).targets.compactMap { target -> String? in
            if case .link(let link) = target.action { return link }
            return nil
        })
        #expect(links == ["hashtag:hibari", "mention:@alice", "https://example.com/page"])
    }
}

@Suite("Emoji catalog")
struct EmojiCatalogTests {
    private let catalog = EmojiCatalog(entries: [
        .init(name: "blobcat_happy", url: "u1", aliases: ["ねこ"], category: "Blob"),
        .init(name: "cat", url: "u2", aliases: [""], category: "Animals"),
        .init(name: "blobcat", url: "u3", aliases: [], category: "Blob"),
        .init(name: "ok", url: "u4", aliases: [], category: nil),
    ])

    @Test func searchPutsExactThenPrefixMatchesFirst() {
        #expect(catalog.search("cat").map(\.name) == ["cat", "blobcat_happy", "blobcat"])
        #expect(catalog.search("blob").map(\.name) == ["blobcat_happy", "blobcat"])
        #expect(catalog.search("ねこ").map(\.name) == ["blobcat_happy"])
        #expect(catalog.search("  ").isEmpty)
    }

    @Test func chipsReactWithTheLocalEmoji() throws {
        #expect(try ReactionController.reaction(forKey: "👍", emojis: catalog) == "👍")
        #expect(try ReactionController.reaction(forKey: ":blobcat@.:", emojis: catalog) == ":blobcat:")
        #expect(try ReactionController.reaction(forKey: ":cat@remote.example:", emojis: catalog) == ":cat:")
        #expect(throws: ReactionController.Refusal.self) {
            try ReactionController.reaction(forKey: ":unknown@remote.example:", emojis: catalog)
        }
    }
}

@Suite("Emoji picker")
@MainActor
struct EmojiPickerTests {
    private let metrics = EmojiPickerLayout.Metrics(width: 402)

    @Test func anEmojiThatDoesNotFitStartsTheNextRow() {
        let frames = metrics.itemFrames(aspects: [0, 0, 0, 0, 0, 0, 4, 0])
        let cell = metrics.cellWidth
        #expect(frames[5] == CGRect(x: 8 + 5 * cell, y: 0, width: cell, height: cell))
        #expect(frames[6] == CGRect(x: 8, y: cell, width: 3 * cell, height: cell))
        #expect(frames[7] == CGRect(x: 8 + 3 * cell, y: cell, width: cell, height: cell))
    }

    @Test func wideEmojisThatLoadKeepTheFirstVisibleOneInPlace() throws {
        let grid = Grid(sections: [400, 400])
        let collectionView = grid.collectionView
        collectionView.contentOffset.y = 2000
        collectionView.layoutIfNeeded()
        let first = try #require(collectionView.indexPathsForVisibleItems.min())
        let before = try #require(grid.layout.layoutAttributesForItem(at: first)).frame.minY

        var changes = Dictionary(uniqueKeysWithValues: (0..<8).map { (IndexPath(item: $0, section: 0), Float(6)) })
        changes[IndexPath(item: 10, section: 1)] = 6
        grid.layout.updateAspects(changes)
        collectionView.layoutIfNeeded()
        let after = try #require(grid.layout.layoutAttributesForItem(at: first)).frame.minY
        #expect(after - before == 6 * metrics.cellWidth)
        #expect(abs(collectionView.contentOffset.y - (2000 + after - before)) < 0.34)
    }

    @Test func atTheTopTheContentGrowsDownward() throws {
        let grid = Grid(sections: [40, 40])
        let before = grid.collectionView.contentSize.height
        grid.layout.updateAspects([IndexPath(item: 0, section: 0): 6])
        grid.collectionView.layoutIfNeeded()
        #expect(grid.collectionView.contentOffset.y == 0)
        #expect(grid.collectionView.contentSize.height == before + metrics.cellWidth)
        #expect(try #require(grid.layout.layoutAttributesForItem(at: IndexPath(item: 4, section: 0))).frame.minY
            == EmojiPickerLayout.Metrics.headerHeight + metrics.cellWidth)
    }

    @Test func sensitiveEmojisCanBeLeftOut() {
        let catalog = EmojiCatalog(entries: [
            .init(name: "ok", url: "u1", aliases: [], category: "A"),
            .init(name: "nsfw", url: "u2", aliases: [], category: "A", isSensitive: true),
            .init(name: "nsfw2", url: "u3", aliases: [], category: "B", isSensitive: true),
        ])
        func itemCounts(hidesSensitive: Bool) -> [Int] {
            let picker = EmojiPickerViewController(
                emojis: catalog, recent: [":nsfw:"],
                imagePipeline: ImagePipeline(source: SampleMediaSource(), diskDirectory: TestData.temporaryDirectory()),
                aspects: EmojiAspectStore(file: TestData.temporaryDirectory().appending(path: "aspects.plist")),
                hidesSensitive: hidesSensitive) { _ in }
            picker.loadViewIfNeeded()
            let view = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
            return (0..<picker.numberOfSections(in: view)).map { picker.collectionView(view, numberOfItemsInSection: $0) }
        }
        let common = EmojiPickerViewController.commonEmojis.count
        #expect(itemCounts(hidesSensitive: false) == [1, common, 2, 1])
        #expect(itemCounts(hidesSensitive: true) == [common, 1])
    }

    private final class Grid: NSObject, UICollectionViewDataSource {
        let layout = EmojiPickerLayout()
        let collectionView: UICollectionView
        private let counts: [Int]

        init(sections counts: [Int]) {
            self.counts = counts
            collectionView = UICollectionView(frame: CGRect(x: 0, y: 0, width: 402, height: 600), collectionViewLayout: layout)
            super.init()
            collectionView.contentInsetAdjustmentBehavior = .never
            collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
            collectionView.register(UICollectionReusableView.self,
                                    forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                    withReuseIdentifier: "header")
            collectionView.dataSource = self
            layout.setAspects(counts.map { Array(repeating: 0, count: $0) })
            collectionView.layoutIfNeeded()
        }

        func numberOfSections(in collectionView: UICollectionView) -> Int { counts.count }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            counts[section]
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
        }

        func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                            at indexPath: IndexPath) -> UICollectionReusableView {
            collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "header", for: indexPath)
        }
    }
}

@Suite("Reaction controller")
@MainActor
struct ReactionControllerTests {
    private final class Log: Sendable {
        let entries = Locked<[String]>([])
        var all: [String] { entries.withLock { $0 } }
    }

    private let account = Account(server: TestData.server, me: MeDetailed(
        id: "me", username: "me", name: nil, avatarUrl: nil, policies: nil, followingCount: nil, followersCount: nil))

    private func controller(log: Log, failing: Set<String> = [], serverNote: [String: Any]? = nil,
                            emojis: EmojiCatalog = EmojiCatalog(entries: [])) -> ReactionController {
        let serverNote = serverNote.map { try! JSONSerialization.data(withJSONObject: $0) }
        let session = StubURLProtocol.session { request, body in
            let endpoint = request.url!.path().replacingOccurrences(of: "/api/", with: "")
            log.entries.withLock { $0.append([endpoint, body["reaction"] as? String].compactMap { $0 }.joined(separator: " ")) }
            if failing.contains(endpoint) {
                return .json(["error": ["code": "INTERNAL_ERROR", "message": "boom"]], status: 500)
            }
            if endpoint == "notes/show", let serverNote { return StubURLProtocol.Response(body: serverNote) }
            return StubURLProtocol.Response(status: 204)
        }
        return ReactionController(client: MisskeyClient(server: TestData.server, token: "T", session: session),
                                  emojis: emojis,
                                  recentReactions: RecentReactions(account: account,
                                                                   defaults: UserDefaults(suiteName: "ReactionControllerTests")!))
    }

    private func note(reactions: [String: Int] = ["👍": 3], mine: String? = nil, acceptance: String? = nil) throws -> Note {
        var object = TestData.note(id: "n1")
        object["reactions"] = reactions
        object["myReaction"] = mine
        object["reactionAcceptance"] = acceptance
        return try MisskeyJSON.decoder().decode(Note.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func changes(count: Int, during body: () throws -> Void) async throws -> [ReactionChange] {
        let received = Locked<[ReactionChange]>([])
        let observer = NotificationCenter.default.addObserver(forName: ReactionController.didChange, object: nil,
                                                              queue: nil) { notification in
            if let change = notification.userInfo?["change"] as? ReactionChange {
                received.withLock { $0.append(change) }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try body()
        for _ in 0..<200 where received.withLock({ $0.count }) < count {
            try await Task.sleep(for: .milliseconds(10))
        }
        return received.withLock { $0 }
    }

    @Test func reactingShowsAtOnceAndSendsTheRequest() async throws {
        let log = Log()
        let controller = controller(log: log)
        let note = try note()
        let posted = try await changes(count: 1) { try controller.react(with: "❤️", to: note) }
        #expect(posted.first?.myReaction == "❤")
        #expect(posted.first?.reactions == ["👍": 3, "❤": 1])
        #expect(controller.state(of: note).myReaction == "❤", "pending state until the request lands")
        for _ in 0..<100 where log.all.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(log.all == ["notes/reactions/create ❤️"])
    }

    @Test func aNoteThatTakesLikesOnlyGetsALike() async throws {
        let log = Log()
        let controller = controller(log: log)
        let note = try note(reactions: ["❤": 3], acceptance: "likeOnly")
        let posted = try await changes(count: 1) { try controller.react(with: "🎉", to: note) }
        #expect(posted.first?.myReaction == "❤" && posted.first?.reactions == ["❤": 4])
        for _ in 0..<100 where log.all.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(log.all == ["notes/reactions/create ❤"])
    }

    @Test func sensitiveEmojisAreRefusedWhereTheNoteDoesNotTakeThem() throws {
        let emojis = EmojiCatalog(entries: [.init(name: "nsfw", url: "u", aliases: [], category: nil, isSensitive: true)])
        let controller = controller(log: Log(), emojis: emojis)
        for acceptance in ["nonSensitiveOnly", "nonSensitiveOnlyForLocalLikeOnlyForRemote"] {
            let note = try note(acceptance: acceptance)
            #expect(throws: ReactionController.Refusal.sensitiveEmoji) { try controller.react(with: ":nsfw:", to: note) }
        }
    }

    @Test func switchingTakesTheOldReactionBackFirst() async throws {
        let log = Log()
        let controller = controller(log: log)
        let note = try note(mine: "👍")
        _ = try await changes(count: 1) { try controller.react(with: "🎉", to: note) }
        for _ in 0..<100 where log.all.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(log.all == ["notes/reactions/delete", "notes/reactions/create 🎉"])
    }

    @Test func tappingTheUsersChipTakesItBack() async throws {
        let log = Log()
        let controller = controller(log: log)
        let note = try note(mine: "👍")
        let posted = try await changes(count: 1) {
            let hasIt = try controller.toggle("👍", on: note)
            #expect(!hasIt)
        }
        #expect(posted.first?.myReaction == nil && posted.first?.reactions == ["👍": 2])
    }

    @Test func aFailedRequestShowsTheServersState() async throws {
        let log = Log()
        var server = TestData.note(id: "n1")
        server["reactions"] = ["👍": 3]
        let controller = controller(log: log, failing: ["notes/reactions/create"], serverNote: server)
        let note = try note()
        let posted = try await changes(count: 2) { try controller.react(with: "😆", to: note) }
        #expect(posted.map(\.myReaction) == ["😆", nil])
        #expect(posted.last?.reactions == ["👍": 3])
    }
}

@Suite("Poll controller")
@MainActor
struct PollControllerTests {
    private func controller(log: Locked<[String]>, failing: Bool = false,
                            serverPoll: [String: Any]? = nil) -> PollController {
        var serverNote = TestData.note(id: "n1")
        serverNote["poll"] = serverPoll
        let serverData = try! JSONSerialization.data(withJSONObject: serverNote)
        let session = StubURLProtocol.session { request, body in
            let endpoint = request.url!.path().replacingOccurrences(of: "/api/", with: "")
            log.withLock { $0.append([endpoint, (body["choice"] as? Int).map(String.init)].compactMap { $0 }.joined(separator: " ")) }
            if endpoint == "notes/show" { return StubURLProtocol.Response(body: serverData) }
            if failing { return .json(["error": ["code": "INTERNAL_ERROR", "message": "boom"]], status: 500) }
            return StubURLProtocol.Response(status: 204)
        }
        return PollController(client: MisskeyClient(server: TestData.server, token: "T", session: session))
    }

    private static func poll(_ voted: [Bool], multiple: Bool = false) -> [String: Any] {
        ["multiple": multiple, "expiresAt": NSNull(),
         "choices": voted.map { ["text": "c", "votes": $0 ? 1 : 0, "isVoted": $0] }]
    }

    private func note(_ poll: [String: Any]) throws -> Note {
        var object = TestData.note(id: "n1")
        object["poll"] = poll
        return try MisskeyJSON.decoder().decode(Note.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func changes(count: Int, during body: () -> Void) async throws -> [PollChange] {
        let received = Locked<[PollChange]>([])
        let observer = NotificationCenter.default.addObserver(forName: PollController.didChange, object: nil,
                                                              queue: nil) { notification in
            if let change = notification.userInfo?["change"] as? PollChange {
                received.withLock { $0.append(change) }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        body()
        for _ in 0..<200 where received.withLock({ $0.count }) < count {
            try await Task.sleep(for: .milliseconds(10))
        }
        return received.withLock { $0 }
    }

    @Test func votingShowsAtOnceAndSendsTheChoice() async throws {
        let log = Locked<[String]>([])
        let controller = controller(log: log)
        let note = try note(Self.poll([false, false]))
        let posted = try await changes(count: 1) { #expect(controller.vote(for: 1, in: note)) }
        #expect(posted.first?.poll.choices.map(\.isVoted) == [false, true])
        #expect(!controller.vote(for: 0, in: note), "a single-choice poll takes one vote, also while it is sent")
        for _ in 0..<100 where log.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(log.withLock { $0 } == ["notes/polls/vote 1"])
    }

    @Test func aMultipleChoicePollTakesTheOtherChoices() async throws {
        let log = Locked<[String]>([])
        let controller = controller(log: log)
        let note = try note(Self.poll([false, false, false], multiple: true))
        _ = try await changes(count: 2) {
            controller.vote(for: 0, in: note)
            controller.vote(for: 2, in: note)
        }
        #expect(controller.poll(of: note)?.choices.map(\.isVoted) == [true, false, true])
        for _ in 0..<100 where log.withLock({ $0.count }) < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(log.withLock { $0 } == ["notes/polls/vote 0", "notes/polls/vote 2"])
    }

    @Test func aFailedVoteShowsTheServersPoll() async throws {
        let log = Locked<[String]>([])
        let controller = controller(log: log, failing: true, serverPoll: Self.poll([false, false]))
        let note = try note(Self.poll([false, false]))
        let posted = try await changes(count: 2) { controller.vote(for: 0, in: note) }
        #expect(posted.map { $0.poll.hasVoted } == [true, false])
    }
}

@Suite("Note API")
struct NoteAPITests {
    @Test func repliesPageForwardFromTheNote() async throws {
        let session = StubURLProtocol.session { request, body in
            #expect(request.url?.path() == "/api/notes/replies")
            #expect(body["noteId"] as? String == "n1" && body["sinceId"] as? String == "n1")
            #expect(body["untilId"] == nil)
            return .json([TestData.note(id: "n3"), TestData.note(id: "n2")])
        }
        let client = MisskeyClient(server: TestData.server, token: "T", session: session)
        let replies = try await client.replies(to: "n1", since: "n1", limit: 30)
        #expect(replies.map(\.id) == ["n2", "n3"], "oldest first")
    }
}

@Suite("Post screen text")
@MainActor
struct UIKitRichTextTests {
    private func builder() -> UIKitRichText {
        UIKitRichText(resolver: EmojiResolver(localEmojis: Samples.emojis, mediaProxy: nil),
                      imagePipeline: ImagePipeline(source: SampleMediaSource(), diskDirectory: TestData.temporaryDirectory()),
                      palette: .dark, scale: 3, linkURL: { URL(string: $0.hasPrefix("http") ? $0 : "https://x.example/") })
    }

    @Test func emojisBecomeAttachmentsThatCopyAsTheirNames() throws {
        let result = builder().build("やあ :blobcat: と :hibari_wide:", emojis: EmojiContext(host: nil, remoteEmojis: [:]),
                                     font: Typography.system(18), color: .primaryText)
        var attachments: [NSTextAttachment] = []
        result.text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: result.text.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { attachments.append(attachment) }
        }
        #expect(attachments.count == 2)
        let wide = try #require(attachments.last)
        #expect(abs(wide.bounds.width / wide.bounds.height - 4) < 0.2)
        #expect(UIKitRichText.plainText(of: result.text) == "やあ :blobcat: と :hibari_wide:")
        #expect(result.provisionalEmojis.isEmpty)
    }
}

@Suite("Post screen reactions")
@MainActor
struct ReactionChipsTests {
    private func chip(_ key: String, _ imagePipeline: ImagePipeline) throws -> (width: CGFloat, provisional: Set<String>) {
        let note = try Samples.makeNote(text: "").with(reactions: [key: 2], reactionEmojis: [:], myReaction: nil)
        let view = ReactionChipsView()
        view.configure(note, resolver: EmojiResolver(localEmojis: Samples.emojis, mediaProxy: nil),
                       imagePipeline: imagePipeline, scale: 3)
        let chip = try #require(view.subviews.first)
        return (chip.intrinsicContentSize.width, view.provisionalEmojis)
    }

    @Test func anEmojiNotOnTheDeviceIsASquareUntilItsSizeIsKnown() async throws {
        let local = ImagePipeline(source: SampleMediaSource(), diskDirectory: TestData.temporaryDirectory())
        let square = try chip(":blobcat@.:", local)
        #expect(square.provisional.isEmpty)
        #expect(try chip(":gone@.:", local).width > square.width)

        let pipeline = ImagePipeline(source: DownloadingMediaSource(base: SampleMediaSource(), delay: .milliseconds(10)),
                                     diskDirectory: TestData.temporaryDirectory())
        let guessed = try chip(":hibari_wide@.:", pipeline)
        #expect(guessed.width == square.width, "a square emoji, not \":hibari_wide:\"")
        #expect(guessed.provisional == [Samples.emojis["hibari_wide"]!])

        await pipeline.prepareSizes(of: guessed.provisional, timeout: .seconds(5))
        let exact = try chip(":hibari_wide@.:", pipeline)
        #expect(exact.provisional.isEmpty)
        #expect(exact.width == square.width + 44, "4:1, at most three squares wide")
    }
}

@Suite("Muting, blocking and reporting")
@MainActor
struct ModerationTests {
    private static func user(_ id: String) -> [String: Any] {
        ["id": id, "username": id]
    }

    private static func note(_ id: String, by author: String, text: String? = "hi", reply: [String: Any]? = nil,
                             renote: [String: Any]? = nil) -> [String: Any] {
        var note: [String: Any] = ["id": id, "createdAt": "2026-09-23T15:00:00.000Z", "user": user(author)]
        note["text"] = text ?? NSNull()
        if let reply {
            note["reply"] = reply
            note["replyId"] = reply["id"]
        }
        if let renote {
            note["renote"] = renote
            note["renoteId"] = renote["id"]
        }
        return note
    }

    private static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    @Test func mutingOrBlockingTakesOutWhatMisskeyLeavesOut() throws {
        let theirs = Self.note("n1", by: "mallory")
        let notes = try MisskeyJSON.decodeNotes(from: Self.json([
            Self.note("n9", by: "bob"),
            theirs,
            Self.note("n8", by: "bob", text: nil, renote: Self.note("n2", by: "mallory")),
            Self.note("n7", by: "carol", reply: theirs),
            Self.note("n6", by: "carol", text: "quote", renote: Self.note("n3", by: "mallory")),
            Self.note("n5", by: "carol", text: nil,
                      renote: Self.note("n4", by: "dave", reply: Self.note("n0", by: "mallory"))),
        ]))
        let (notifications, _) = try MisskeyJSON.decodeNotifications(from: Self.json([
            ["id": "f1", "createdAt": "2026-09-23T14:00:00.000Z", "type": "follow", "user": Self.user("mallory")],
            ["id": "g1", "createdAt": "2026-09-23T14:00:00.000Z", "type": "reaction:grouped",
             "note": Self.note("mine", by: "me"),
             "reactions": [["user": Self.user("mallory"), "reaction": "👍"], ["user": Self.user("bob"), "reaction": "👍"]]],
        ]))
        let items = notes.map { TimelineItem(note: $0) } + notifications.map { TimelineItem(notification: $0) }
        #expect(items.filter { $0.involves(user: "mallory") }.map(\.id) == ["n1", "n8", "n7", "n6", "f1"],
                "their notes, renotes and quotes of them, replies to them, what only they did")

        var entries = TimelineEntries()
        entries.append(items, layouts: Samples.engine().layouts(for: items, context: Samples.context()))
        #expect(entries.remove(involving: "mallory") == [1, 2, 3, 4, 6])
        #expect(entries.items.map(\.id) == ["n9", "n5", "g1"])
        #expect(entries.index(of: "g1") == 2 && entries.layouts[2].key.noteID == "g1")
        #expect(entries.remove(involving: "mallory").isEmpty)
    }

    @Test func reportsOfANoteStartWithItsLink() async throws {
        let sent = Locked<[String: Any]>([:])
        let session = StubURLProtocol.session { request, body in
            #expect(request.url?.path() == "/api/users/report-abuse")
            sent.withLock { $0 = body }
            return StubURLProtocol.Response(status: 204)
        }
        let client = MisskeyClient(server: TestData.server, token: "T", session: session)
        let user = User(id: "u9", name: nil, username: "mallory", host: "remote.example", avatarUrl: nil)
        let note = try #require(try MisskeyJSON.decodeNotes(from: Self.json([Self.note("n1", by: "u9", text: "spam\nspam")])).first)
        let model = ReportModel(user: user, note: note, noteURL: URL(string: "https://misskey.example/notes/n1"),
                                client: client, server: "misskey.example")
        #expect(model.notePreview == "spam spam")
        #expect(model.canSend, "the link says which note, as on the web")
        model.reason = "  広告です\n"
        #expect(model.comment == "Note: https://misskey.example/notes/n1\n-----\n広告です")

        let outcome = await withCheckedContinuation { continuation in
            model.onFinish = { continuation.resume(returning: $0) }
            model.send()
        }
        #expect(outcome == .sent)
        #expect(sent.withLock { $0["userId"] as? String } == "u9")
        #expect(sent.withLock { $0["comment"] as? String } == model.comment && sent.withLock { $0["i"] as? String } == "T")
    }

    @Test func reportsOfAUserNeedAReasonThatFits() async throws {
        let session = StubURLProtocol.session { _, _ in
            .json(["error": ["code": "CANNOT_REPORT_THE_ADMIN", "message": "Cannot report the admin."]], status: 400)
        }
        let client = MisskeyClient(server: TestData.server, token: "T", session: session)
        let user = User(id: "admin", name: nil, username: "admin", host: nil, avatarUrl: nil)
        let model = ReportModel(user: user, note: nil, noteURL: nil, client: client, server: "misskey.example")
        #expect(!model.canSend)
        model.reason = " \n"
        #expect(!model.canSend, "blank is no reason")
        model.reason = String(repeating: "👍", count: MisskeyClient.maxReportLength + 1)
        #expect(model.isTooLong && !model.canSend)
        model.reason = String(repeating: "👍", count: MisskeyClient.maxReportLength)
        #expect(!model.isTooLong, "counted in code points, as Misskey does")

        model.reason = "荒らし"
        model.send()
        #expect(model.isSending && !model.canSend)
        for _ in 0..<500 where model.isSending { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.message == "サーバーの管理者は通報できません")
        #expect(model.canSend, "it can be sent again")
    }
}
