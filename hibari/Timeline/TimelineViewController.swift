import UIKit

protocol TimelineScrollObserver: AnyObject {
    func timelineWillBeginDragging(_ scrollView: UIScrollView)
    func timelineDidScroll(_ scrollView: UIScrollView)
    func timelineDidEndScrolling(_ scrollView: UIScrollView)
    /// The timeline moved its content to keep the notes on screen in place (notes came in
    /// above them): not the user's scrolling.
    func timelineDidMoveContent(_ scrollView: UIScrollView)
}

extension TimelineScrollObserver {
    func timelineWillBeginDragging(_ scrollView: UIScrollView) {}

    func timelineDidMoveContent(_ scrollView: UIScrollView) {
        timelineDidScroll(scrollView)
    }
}

struct TimelineDisplayStats: Codable, Sendable {
    var cellsDisplayed = 0
    var renderLate = 0
    var imagesLate = 0
}

final class TimelineViewController: UIViewController {
    let timelineID: String
    private let source: any TimelineSource
    let services: NoteServices
    private let engine: NoteLayoutEngine
    private let renderer: NoteRenderer
    private let imagePipeline: ImagePipeline
    private let clock: TimelineClock

    weak var scrollObserver: TimelineScrollObserver?
    var contentInsets: UIEdgeInsets = .zero {
        didSet { applyInsets() }
    }
    /// Where the scroll indicator runs, when not within `contentInsets`.
    var indicatorInsets: UIEdgeInsets? {
        didSet { applyInsets() }
    }
    var minimumContentHeight: CGFloat {
        get { listLayout.minimumContentHeight }
        set { listLayout.minimumContentHeight = newValue }
    }
    /// Off when the screen around the timeline shows the pull itself (the profile's
    /// banner); it calls `refresh(completion:)` then. Set before the view loads.
    var allowsPullToRefresh = true
    var emptyMessage = "まだノートがありません"
    /// Loads nothing until `activate()` (the pager's timelines, until they show). Set
    /// before the view loads.
    var waitsForActivation = false
    /// Where the top of the list is kept across launches. Set before the view loads.
    var snapshotStore: TimelineSnapshotStore?
    /// The user whose profile the list is: their notes stay when the account mutes or
    /// blocks them, as the server's list does.
    var profileUserID: String?

    private(set) var displayStats = TimelineDisplayStats()
    private(set) lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: listLayout)
    private let listLayout = TimelineCollectionLayout()

    /// What the list holds. Every change lands here at once, and what the list decides on
    /// (what it has, what to fetch next) reads it.
    private var entries: TimelineEntries
    /// What the collection view shows: `entries` as `presentEntries()` last showed them,
    /// behind while the list is held. What is about the screen (rows, positions, cells)
    /// reads it. It is what the data source answers, and UIKit reads the rows an update
    /// starts from when it likes (a reload no layout has taken up yet, as in a list off
    /// screen, only then): rows come and go in it only where UIKit is told at once, right
    /// before `reloadData()` or inside the batch update saying which rows came and went
    /// (`reloadData(showing:)`, `updateRows(to:removing:inserting:layout:)`).
    private var presented: TimelineEntries
    /// Keeps the rows still while a button's answer to a tap plays on one.
    let listHold = ListHold()
    private var presentation = Presentation()
    /// The refresh under way puts new notes above the screen.
    private var refreshKeepsPosition = false
    /// A refresh asked for while one was under way (or the list was being restored): what it
    /// is for may have come after that one started, so it follows.
    private var nextRefresh: RefreshRequest?

    private struct RefreshRequest {
        var startingOver = false
        var keepingPosition = false
        var waiters: [() -> Void] = []
    }
    private lazy var sensitiveMedia = services.sensitiveMedia
    private var context: LayoutContext?
    private var clockTime: Date
    private var clockTimer: Timer?
    private var isRelayingOut = false
    private var deferredNoteIDs: Set<String> = []
    private var prefetchedRange = 0..<0

    private var isActivated = false
    private var hasStarted = false
    private var isRestoring = false
    private var cursor: String?
    private var newestID: String?
    private var shownBefore: [String: Date] = [:]
    private var fillingGapID: Int?
    private var isAdjustingPosition = false
    private lazy var newNotesButton = NewNotesButton(imagePipeline: imagePipeline)
    private var reachedEnd = false
    private var isLoadingPage = false
    private var isRefreshing = false
    private var generation = 0
    private var retryAfter: Date?
    private var failures = 0
    private var pageWaiters: [() -> Void] = []
    private var refreshWaiters: [() -> Void] = []
    private var footerState = TimelineFooterView.State.loading
    private var pullToRefresh: PullToRefresh?

    /// The server rejected the token.
    var onAuthenticationFailure: (() -> Void)?

    private let pageSize = AppSettings.timelinePageSize
    private let loadMoreThreshold = 5
    private let gapFillThreshold = 15
    private let lookahead = 10
    private static let textEmojiTimeout: Duration = .seconds(10)
    private static let reactionEmojiTimeout: Duration = .milliseconds(1500)

    init(timelineID: String, source: any TimelineSource, services: NoteServices) {
        self.timelineID = timelineID
        self.source = source
        self.services = services
        engine = services.engine
        clock = services.clock
        renderer = services.renderer
        imagePipeline = services.imagePipeline
        clockTime = clock.now()
        entries = TimelineEntries(accountUserID: services.account.userID)
        presented = entries
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isLoaded: Bool { !entries.isEmpty }
    var hasMorePages: Bool { !reachedEnd }
    var noteCount: Int { entries.count }
    var gapCount: Int { entries.gaps.count }

    #if PERF
    struct PositionStats: Sendable {
        var reloads = 0
        var totalReloadMs: Double = 0
        var maxReloadMs: Double = 0
        var maxJumpPoints: Double = 0
        var reloadsWhileDecelerating = 0
        var interruptedDecelerations = 0
    }

    private(set) var positionStats = PositionStats()

    var isFillingGap: Bool { fillingGapID != nil }

    /// Puts the top of the screen `count` notes below the first gap.
    func scrollBelowFirstGap(by count: Int) {
        guard let gap = presented.gaps.first else { return }
        let index = min(presented.count - 1, presented.position(of: gap) + 1 + count)
        guard let offset = listLayout.offset(ofItem: index) else { return }
        collectionView.contentOffset.y = offset - collectionView.adjustedContentInset.top
    }
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .hibari(.background)
        collectionView.backgroundColor = .hibari(.background)
        collectionView.register(NoteCell.self, forCellWithReuseIdentifier: NoteCell.reuseIdentifier)
        collectionView.register(TimelineFooterView.self, forSupplementaryViewOfKind: TimelineCollectionLayout.footerKind,
                                withReuseIdentifier: TimelineFooterView.reuseIdentifier)
        collectionView.register(TimelineGapView.self, forSupplementaryViewOfKind: TimelineCollectionLayout.gapKind,
                                withReuseIdentifier: TimelineGapView.reuseIdentifier)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.contentInsetAdjustmentBehavior = .never
        // `contentInsets` already include the safe area; the system would add it again.
        collectionView.automaticallyAdjustsScrollIndicatorInsets = false
        collectionView.alwaysBounceVertical = true
        collectionView.accessibilityIdentifier = "timeline.\(timelineID)"
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(collectionView)
        listLayout.footerHeight = footerState.height
        if allowsPullToRefresh {
            let pull = PullToRefresh(scrollView: collectionView)
            pull.onRefresh = { [weak self] in self?.refresh() }
            pull.onInsetChange = { [weak self] in self?.applyInsets() }
            pullToRefresh = pull
        }
        listHold.onRelease = { [weak self] in self?.presentEntries() }
        newNotesButton.isHidden = true
        newNotesButton.addAction(UIAction { [weak self] _ in
            self?.hideNewNotesButton()
            self?.scrollToTop(animated: true)
        }, for: .touchUpInside)
        view.addSubview(newNotesButton)
        applyInsets()

        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self,
                                 UITraitDisplayScale.self]) { (self: Self, _) in
            self.updateContextIfNeeded()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(rendererDidRedraw(_:)),
                                               name: NoteRenderer.didRedraw, object: renderer)
        NotificationCenter.default.addObserver(self, selector: #selector(mediaSizesDidChange(_:)),
                                               name: ImagePipeline.mediaSizesDidChange, object: imagePipeline)
        NotificationCenter.default.addObserver(self, selector: #selector(noteDidChange(_:)),
                                               name: ReactionController.didChange, object: services.reactions)
        NotificationCenter.default.addObserver(self, selector: #selector(noteDidChange(_:)),
                                               name: RenoteController.didChange, object: services.renotes)
        NotificationCenter.default.addObserver(self, selector: #selector(noteDidChange(_:)),
                                               name: BookmarkController.didChange, object: services.bookmarks)
        NotificationCenter.default.addObserver(self, selector: #selector(noteDidChange(_:)),
                                               name: PollController.didChange, object: services.polls)
        NotificationCenter.default.addObserver(self, selector: #selector(didDeleteNote(_:)),
                                               name: NoteServices.didDeleteNote, object: services)
        NotificationCenter.default.addObserver(self, selector: #selector(didHideUser(_:)),
                                               name: NoteServices.didHideUser, object: services)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsDidChange),
                                               name: AppSettings.didChange, object: nil)
        if snapshotStore != nil {
            NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
                                                   name: UIApplication.didEnterBackgroundNotification, object: nil)
        }
    }

    func activate() {
        guard !isActivated else { return }
        isActivated = true
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard !hasStarted, context != nil, isActivated || !waitsForActivation else { return }
        hasStarted = true
        if let snapshotStore {
            restore(from: snapshotStore)
        } else {
            loadNextPage()
        }
    }

    @objc private func settingsDidChange() {
        updateContextIfNeeded()
        let hidden = sensitiveMedia == .hide
        sensitiveMedia = services.sensitiveMedia
        if hidden != (sensitiveMedia == .hide) { refresh(startingOver: true) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateContextIfNeeded()
        layoutNewNotesButton()
    }

    private func applyInsets() {
        guard isViewLoaded else { return }
        var insets = contentInsets
        insets.top += pullToRefresh?.inset ?? 0
        collectionView.contentInset = insets
        collectionView.verticalScrollIndicatorInsets = indicatorInsets ?? contentInsets
        layoutNewNotesButton()
    }

    private func layoutNewNotesButton() {
        let size = newNotesButton.sizeThatFits(view.bounds.size)
        newNotesButton.bounds = CGRect(origin: .zero, size: size)
        newNotesButton.center = CGPoint(x: view.bounds.midX, y: contentInsets.top + 12 + size.height / 2)
    }

    private func updateContextIfNeeded() {
        let width = view.bounds.width
        guard width > 0 else { return }
        let newContext = LayoutContext(width: width, safeAreaInsets: view.safeAreaInsets, traits: traitCollection,
                                       revealsSensitiveMedia: services.sensitiveMedia == .show)
        guard newContext != context else { return }
        let isFirst = context == nil
        context = newContext
        if isFirst {
            startIfNeeded()
        } else {
            relayoutStale()
        }
    }

    private func relayoutStale() {
        guard let context, !isRelayingOut else { return }
        let engine = self.engine
        let clockTime = self.clockTime
        let stale = entries.staleIndices(
            onScreen: onScreenIndices,
            expectedKey: { engine.key(for: $0, context: context, now: clockTime) },
            emojiSizesAreCurrent: engine.emojiSizesAreCurrent(in:))
        deferredNoteIDs = Set(stale.deferred.map { entries.items[$0].id })
        guard !stale.now.isEmpty else { return }
        isRelayingOut = true
        let items = stale.now.map { entries.items[$0] }
        let nearby = Set(prefetchWindow(around: visibleItemRange).map { presented.items[$0].id })
        let onScreen = Set(items.lazy.map(\.id).filter(nearby.contains))
        let renderer = self.renderer
        Task.detached(priority: .userInitiated) {
            let layouts = engine.layouts(for: items, context: context, now: clockTime)
            for layout in layouts where onScreen.contains(layout.key.noteID) {
                renderer.renderSynchronously(layout)
            }
            await self.finishRelayout(layouts)
        }
    }

    private func finishRelayout(_ fresh: [NoteLayout]) {
        isRelayingOut = false
        if let context {
            let engine = self.engine
            let clockTime = self.clockTime
            let changed = entries.integrate(fresh, onScreen: onScreenIndices) {
                engine.key(for: $0, context: context, now: clockTime)
            }
            if !changed.isEmpty { presentEntries() }
        }
        relayoutStale()
    }

    /// How `presentEntries()` moves the list for what changed since it last ran.
    private struct Presentation {
        /// The list was replaced: it shows from the top again, unless `keepsPosition`.
        var startsOver = false
        /// Notes that came in above the screen stay above it, also at the top ("新しいノート"
        /// shows); a replaced list stays at the note at the top of the screen if it is still
        /// there.
        var keepsPosition = false
    }

    /// Shows `entries` as they are now: the only place the rows on screen change. While the
    /// list is held only what rows show changes in place, and the hold's end runs it again.
    private func presentEntries() {
        guard !listHold.isHeld else { return showContentInPlace() }
        let old = presented
        let new = entries
        let presentation = self.presentation
        self.presentation = Presentation()
        guard isViewLoaded else {
            // No data source yet: it reads `presented` from the start.
            presented = new
            return
        }
        if old.revision == new.revision {
            showContentChanges(from: old, to: new)
        } else {
            showRowChanges(from: old, to: new, presentation)
        }
        updateFooter()
        updateGapViews()
        prefetchedRange = 0..<0
        prefetchAround(visible: visibleItemRange)
        loadMoreIfNeeded()
        fillGapsIfNeeded()
    }

    /// While the list is held: rows laid out again at the same height show what changed (a
    /// count next to the button playing); nothing moves.
    private func showContentInPlace() {
        guard isViewLoaded else { return }
        var changed = false
        for index in presented.items.indices {
            guard let latest = entries.index(of: presented.items[index].id) else { continue }
            let layout = entries.layouts[latest]
            guard layout.serial != presented.layouts[index].serial,
                  layout.height == presented.layouts[index].height
            else { continue }
            presented.update(at: index, item: entries.items[latest], layout: layout)
            changed = true
        }
        if changed { configureChangedCells() }
    }

    /// The same rows: the cells whose rows were laid out again change, or the whole list
    /// is laid out again around the screen if heights changed.
    private func showContentChanges(from old: TimelineEntries, to new: TimelineEntries) {
        if zip(old.layouts, new.layouts).contains(where: { $0.height != $1.height }) {
            reload(showing: new, keeping: captureAnchor(in: old, keptIn: new))
        } else {
            // The same rows: UIKit has nothing to start from that this changes.
            presented = new
            configureChangedCells()
        }
    }

    private func showRowChanges(from old: TimelineEntries, to new: TimelineEntries, _ presentation: Presentation) {
        if old.isEmpty || presentation.startsOver && !presentation.keepsPosition {
            reloadData(showing: new)
            if presentation.startsOver {
                showFromTop()
                hideNewNotesButton()
            }
            return
        }
        let rows = RowChanges(from: old, to: new)
        let reveals = isAtTop && !presentation.keepsPosition
        let keepsGaps = old.gaps.map(\.id) == new.gaps.map(\.id)
        let simple = keepsGaps && !rows.reshapes
        if simple && rows.inserted.isEmpty {
            updateRows(to: new, removing: rows.removed)
        } else if simple && rows.removed.isEmpty && rows.inserted.first == old.count {
            UIView.performWithoutAnimation {
                updateRows(to: new, inserting: rows.inserted) {
                    self.listLayout.appendHeights(new.layouts[old.count...].map(\.height))
                }
            }
        } else if simple && reveals && rows.removed.isEmpty && rows.inserted.count == rows.insertedAbove {
            updateRows(to: new, inserting: rows.inserted)
        } else {
            let anchor = reveals && rows.insertedAbove > 0 ? nil : captureAnchor(in: old, keptIn: new)
            reload(showing: new, keeping: anchor)
            if presentation.startsOver && anchor == nil { showFromTop() }
        }
        if presentation.startsOver {
            hideNewNotesButton()
        } else if rows.insertedAbove > 0 && !reveals {
            showNewNotesButton(for: presented.items.prefix(rows.insertedAbove))
        }
    }

    /// How the rows went from one list to the next.
    private struct RowChanges {
        /// Where the rows that went were, in order.
        private(set) var removed: [Int] = []
        /// Where the rows that came are, in order.
        private(set) var inserted: [Int] = []
        /// How many came in above every row that stayed.
        private(set) var insertedAbove = 0
        /// Rows that stayed changed order or height.
        private(set) var reshapes = false

        init(from old: TimelineEntries, to new: TimelineEntries) {
            removed = old.items.indices.filter { !new.contains(old.items[$0].id) }
            var previous: Int?
            for (index, item) in new.items.enumerated() {
                guard let oldIndex = old.index(of: item.id) else {
                    inserted.append(index)
                    if previous == nil { insertedAbove += 1 }
                    continue
                }
                if oldIndex < previous ?? -1 || old.layouts[oldIndex].height != new.layouts[index].height {
                    reshapes = true
                }
                previous = oldIndex
            }
        }
    }

    /// Shows `new` by the rows that went and came, in one batch update. UIKit takes the
    /// rows it starts from before the block runs (taking up a reload still waiting for
    /// layout then), so `presented` changes in it, and the layout too: the rows that stay
    /// move from where they are.
    private func updateRows(to new: TimelineEntries, removing removed: [Int] = [], inserting inserted: [Int] = [],
                            layout: (() -> Void)? = nil) {
        collectionView.performBatchUpdates {
            presented = new
            if let layout { layout() } else { updateListLayout() }
            collectionView.deleteItems(at: removed.map { IndexPath(item: $0, section: 0) })
            collectionView.insertItems(at: inserted.map { IndexPath(item: $0, section: 0) })
        }
        configureChangedCells()
    }

    /// Shows `new` from scratch: UIKit reads every row again, when it next needs them.
    private func reloadData(showing new: TimelineEntries) {
        presented = new
        updateListLayout()
        collectionView.reloadData()
    }

    /// Gives the cells on screen their row's layout where it changed.
    private func configureChangedCells() {
        for indexPath in collectionView.indexPathsForVisibleItems where indexPath.item < presented.count {
            guard let cell = collectionView.cellForItem(at: indexPath) as? NoteCell,
                  cell.layoutSerial != presented.layouts[indexPath.item].serial
            else { continue }
            configure(cell, at: indexPath.item)
        }
    }

    private struct Anchor {
        let noteID: String
        let delta: CGFloat
        #if PERF
        let middle: (noteID: String, y: CGFloat)?
        let wasDecelerating: Bool
        #endif
    }

    /// The row at the top of the screen (in `old`, what showed until now) and how far into
    /// it the screen starts. If that row is not in `new`, the first one on screen below it
    /// that is.
    private func captureAnchor(in old: TimelineEntries, keptIn new: TimelineEntries) -> Anchor? {
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let bottom = collectionView.contentOffset.y + collectionView.bounds.height
        guard var index = listLayout.firstItem(endingBelow: top) else { return nil }
        while index < old.count, let offset = listLayout.offset(ofItem: index), offset < bottom {
            let noteID = old.items[index].id
            guard new.contains(noteID) else {
                index += 1
                continue
            }
            #if PERF
            let middleY = collectionView.contentOffset.y + collectionView.bounds.height / 2
            let middle = listLayout.firstItem(endingBelow: middleY).flatMap { index -> (String, CGFloat)? in
                guard index < old.count, let offset = listLayout.offset(ofItem: index) else { return nil }
                return (old.items[index].id, offset - collectionView.contentOffset.y)
            }
            return Anchor(noteID: noteID, delta: top - offset, middle: middle,
                          wasDecelerating: collectionView.isDecelerating)
            #else
            return Anchor(noteID: noteID, delta: top - offset)
            #endif
        }
        return nil
    }

    /// Shows `new` from scratch, with `anchor`'s row where it was on screen.
    private func reload(showing new: TimelineEntries, keeping anchor: Anchor?) {
        #if PERF
        let started = CACurrentMediaTime()
        #endif
        isAdjustingPosition = true
        reloadData(showing: new)
        collectionView.layoutIfNeeded()
        if let anchor, let index = presented.index(of: anchor.noteID), let offset = listLayout.offset(ofItem: index) {
            let delta = min(anchor.delta, presented.layouts[index].height)
            collectionView.contentOffset.y = offset + delta - collectionView.adjustedContentInset.top
            collectionView.layoutIfNeeded()
        }
        isAdjustingPosition = false
        scrollObserver?.timelineDidMoveContent(collectionView)
        updateGapViews()
        #if PERF
        let ms = (CACurrentMediaTime() - started) * 1000
        positionStats.reloads += 1
        positionStats.totalReloadMs += ms
        positionStats.maxReloadMs = max(positionStats.maxReloadMs, ms)
        if let middle = anchor?.middle, let index = presented.index(of: middle.noteID),
           let offset = listLayout.offset(ofItem: index) {
            let jump = abs(offset - collectionView.contentOffset.y - middle.y)
            positionStats.maxJumpPoints = max(positionStats.maxJumpPoints, Double(jump))
        }
        if anchor?.wasDecelerating == true {
            positionStats.reloadsWhileDecelerating += 1
            if !collectionView.isDecelerating { positionStats.interruptedDecelerations += 1 }
        }
        #endif
    }

    private func updateListLayout() {
        listLayout.setHeights(presented.layouts.map(\.height), gaps: presented.gapPlacements)
    }

    /// The rows on screen, by where they are in `entries`.
    private var onScreenIndices: Set<Int> {
        Set(collectionView.indexPathsForVisibleItems.compactMap { indexPath in
            indexPath.item < presented.count ? entries.index(of: presented.items[indexPath.item].id) : nil
        })
    }

    private func scheduleClockTick() {
        clockTimer?.invalidate()
        clockTimer = nil
        guard !clock.isFrozen else { return }
        let clockTime = self.clockTime
        guard let next = entries.layouts.lazy.flatMap(\.timeSlots).map({ $0.nextChange(after: clockTime) }).min(),
              next < .distantFuture
        else { return }
        let timer = Timer(timeInterval: max(1, next.timeIntervalSince(clock.now())), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.clockTime = self.clock.now()
                for case let cell as NoteCell in self.collectionView.visibleCells {
                    cell.updateTimes(at: self.clockTime)
                }
                self.relayoutStale()
                self.scheduleClockTick()
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    @objc private func mediaSizesDidChange(_ notification: Notification) {
        relayoutStale()
    }

    @objc private func noteDidChange(_ notification: Notification) {
        guard let change = notification.userInfo?["change"] as? any NoteChange, entries.apply(change) else { return }
        relayoutStale()
    }

    @objc private func didDeleteNote(_ notification: Notification) {
        guard let noteID = notification.userInfo?["noteID"] as? String else { return }
        remove { $0.remove(deleted: noteID) }
    }

    @objc private func didHideUser(_ notification: Notification) {
        guard let userID = notification.userInfo?["userID"] as? String, userID != profileUserID else { return }
        remove { $0.remove(involving: userID) }
    }

    private func remove(_ removal: (inout TimelineEntries) -> [Int]) {
        let idsBefore = entries.items.map(\.id)
        let removed = removal(&entries)
        guard !removed.isEmpty else { return }
        deferredNoteIDs.subtract(removed.map { idsBefore[$0] })
        absorbTrailingGap()
        presentEntries()
    }

    @objc private func rendererDidRedraw(_ notification: Notification) {
        guard let rendered = notification.userInfo?["note"] as? RenderedNote else { return }
        for case let cell as NoteCell in collectionView.visibleCells {
            cell.applyRendered(rendered)
        }
    }

    /// Fetches and lays out the next page off the main thread. `completion` runs once it
    /// is in the timeline (right away at the end of the timeline).
    func loadNextPage(completion: (() -> Void)? = nil) {
        if let completion { pageWaiters.append(completion) }
        guard !reachedEnd else {
            flushPageWaiters()
            return
        }
        guard !isLoadingPage, let context else { return }
        isLoadingPage = true
        setFooter(.loading)
        let source = self.source
        let cursor = self.cursor
        let limit = pageSize
        let known = entries
        let filter = entryFilter()
        let generation = self.generation
        let prepare = layoutPreparation(context: context)
        Task.detached(priority: .userInitiated) {
            do {
                let page = try await source.page(until: cursor, limit: limit)
                let items = filter.newItems(in: page.entries, excluding: known)
                let layouts = await prepare(items)
                await self.appendPage(items, layouts: layouts, newest: page.entries.first?.id, cursor: page.cursor,
                                      isEnd: page.cursor == nil, generation: generation)
            } catch {
                await self.pageFailed(error, generation: generation)
            }
        }
    }

    #if PERF
    func loadAllPages(completion: @escaping () -> Void) {
        guard hasMorePages else {
            completion()
            return
        }
        loadNextPage { [weak self] in
            self?.loadAllPages(completion: completion)
        }
    }
    #endif

    /// Replaces the list with the newest page by default. With `preserveHistory`, merges
    /// new entries above fetched history, leaving a gap if the page does not reach it.
    /// At the top new entries show; otherwise, or with `keepingPosition`, they go above
    /// the screen and "新しいノート" shows; a replaced list then stays where it is too.
    /// `startingOver` also resets history timelines. Asked for while one is under way, it
    /// runs after it. `completion` runs when it is done (or failed).
    func refresh(startingOver: Bool = false, keepingPosition: Bool = false, completion: (() -> Void)? = nil) {
        guard !isRefreshing, !isRestoring else {
            var next = nextRefresh ?? RefreshRequest()
            next.startingOver = next.startingOver || startingOver
            next.keepingPosition = next.keepingPosition || keepingPosition
            if let completion { next.waiters.append(completion) }
            nextRefresh = next
            return
        }
        if let completion { refreshWaiters.append(completion) }
        guard hasStarted, let context else {
            pullToRefresh?.endRefreshing()
            flushRefreshWaiters()
            return
        }
        isRefreshing = true
        refreshKeepsPosition = keepingPosition
        let preservesHistory = source.refreshPolicy == .preserveHistory
        if startingOver, preservesHistory { rememberShown() }
        let replaces = startingOver || !preservesHistory
        let source = self.source
        let limit = pageSize
        let known = replaces ? TimelineEntries() : entries
        let newest = replaces ? nil : newestID ?? entries.items.first?.id
        let filter = entryFilter()
        let prepare = layoutPreparation(context: context)
        Task.detached(priority: .userInitiated) {
            do {
                let page = try await source.page(until: nil, limit: limit)
                let entries = page.entries
                let update: RefreshUpdate
                if let newest {
                    let split = entries.firstIndex { $0.id <= newest } ?? entries.endIndex
                    let reached = page.cursor.map { $0 <= newest } ?? true
                    let items = filter.newItems(in: entries[..<split], excluding: known)
                    update = RefreshUpdate(items: items, layouts: await prepare(items),
                                           changed: filter.changed(in: entries[split...], known: known),
                                           replacing: false, gapBelow: reached ? nil : page.cursor.map { ($0, newest) })
                } else {
                    let items = filter.newItems(in: entries, excluding: TimelineEntries())
                    update = RefreshUpdate(items: items, layouts: await prepare(items),
                                           changed: [], replacing: true, gapBelow: nil)
                }
                await self.waitForSpinner()
                await self.finishRefresh(update, newest: entries.first?.id, cursor: page.cursor,
                                         isEnd: page.cursor == nil)
            } catch {
                await self.refreshFailed(error)
            }
        }
    }

    func contains(noteID: String) -> Bool {
        entries.contains(noteID)
    }

    func remove(noteID: String) {
        remove { $0.remove(noteID: noteID) }
    }

    func retry() {
        retryAfter = nil
        loadNextPage()
    }

    private func entryFilter() -> EntryFilter {
        EntryFilter(sensitiveMedia: sensitiveMedia, marks: services.marks, shownBefore: shownBefore,
                    accountUserID: services.account.userID)
    }

    private func layoutPreparation(context: LayoutContext) -> @Sendable ([TimelineItem]) async -> [NoteLayout] {
        let engine = self.engine
        let imagePipeline = self.imagePipeline
        let clockTime = self.clockTime
        let textEmojiTimeout = Self.textEmojiTimeout
        let reactionEmojiTimeout = Self.reactionEmojiTimeout
        return { items in
            let emojis = engine.customEmojis(in: items)
            async let textReady: Void = imagePipeline.prepareSizes(of: emojis.text, timeout: textEmojiTimeout)
            async let reactionsReady: Void = imagePipeline.prepareSizes(of: emojis.reactions,
                                                                        timeout: reactionEmojiTimeout)
            _ = await (textReady, reactionsReady)
            return engine.layouts(for: items, context: context, now: clockTime)
        }
    }

    private func loadMoreIfNeeded() {
        guard !reachedEnd, !isLoadingPage, retryAfter.map({ Date() >= $0 }) ?? true else { return }
        guard !pageWaiters.isEmpty || visibleItemRange.upperBound + loadMoreThreshold >= presented.count else { return }
        loadNextPage()
    }

    private func appendPage(_ newItems: [TimelineItem], layouts newLayouts: [NoteLayout], newest: String?,
                            cursor next: String?, isEnd: Bool, generation: Int) {
        guard generation == self.generation else { return }
        isLoadingPage = false
        retryAfter = nil
        failures = 0
        if let next { cursor = next }
        if newestID == nil { newestID = newest }
        entries.append(newItems, layouts: newLayouts)
        if isEnd { reachedEnd = true }
        services.learn(from: newItems.compactMap(\.note))
        presentEntries()
        didChangeEntries()
        flushPageWaiters()
        loadMoreIfNeeded()
    }

    private struct RefreshUpdate: Sendable {
        let items: [TimelineItem]
        let layouts: [NoteLayout]
        let changed: [TimelineItem]
        let replacing: Bool
        let gapBelow: (newerID: String, olderID: String)?
    }

    private func finishRefresh(_ update: RefreshUpdate, newest: String?, cursor next: String?, isEnd: Bool) {
        isRefreshing = false
        pullToRefresh?.endRefreshing(foundNew: update.replacing || !update.items.isEmpty || !update.changed.isEmpty)
        if refreshKeepsPosition { presentation.keepsPosition = true }
        defer { didFinishRefresh() }
        if update.replacing {
            generation += 1
            entries.replaceAll(with: update.items, layouts: update.layouts)
            newestID = newest
            cursor = next
            reachedEnd = isEnd
            isLoadingPage = false
            fillingGapID = nil
            retryAfter = nil
            failures = 0
            presentation.startsOver = true
        } else {
            if let newest, newest > newestID ?? "" { newestID = newest }
            entries.replace(update.changed)
            entries.prepend(update.items, layouts: update.layouts, gapBelow: update.gapBelow)
            absorbTrailingGap()
        }
        services.learn(from: update.items.compactMap(\.note))
        presentEntries()
        didChangeEntries()
    }

    private func refreshFailed(_ error: any Error) {
        isRefreshing = false
        pullToRefresh?.endRefreshing()
        didFinishRefresh()
        if (error as? MisskeyAPIError)?.isAuthenticationFailure == true {
            onAuthenticationFailure?()
        }
        Toast.show(Self.message(for: error), in: view.window)
    }

    /// Notes came in or changed: lays out what needs it and times the labels' next change.
    private func didChangeEntries() {
        relayoutStale()
        scheduleClockTick()
    }

    private func pageFailed(_ error: any Error, generation: Int) {
        guard generation == self.generation else { return }
        isLoadingPage = false
        let apiError = error as? MisskeyAPIError
        if apiError?.isAuthenticationFailure == true {
            onAuthenticationFailure?()
        }
        failures += 1
        setFooter(.failed(Self.message(for: error)))
        guard apiError?.isTransient ?? true else {
            retryAfter = .distantFuture
            return
        }
        let seconds = min(60, 3 * Double(1 << min(failures - 1, 5)))
        retryAfter = Date(timeIntervalSinceNow: seconds)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.loadMoreIfNeeded()
        }
    }

    private static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "読み込めませんでした"
    }

    /// Calls back who waited for the refresh, and starts the one asked for meanwhile.
    private func didFinishRefresh() {
        flushRefreshWaiters()
        guard let next = nextRefresh else { return }
        nextRefresh = nil
        refreshWaiters = next.waiters
        refresh(startingOver: next.startingOver, keepingPosition: next.keepingPosition)
    }

    private func flushRefreshWaiters() {
        let waiters = refreshWaiters
        refreshWaiters.removeAll()
        waiters.forEach { $0() }
    }

    private func flushPageWaiters() {
        let waiters = pageWaiters
        pageWaiters.removeAll()
        waiters.forEach { $0() }
    }

    private func fillGapsIfNeeded() {
        guard fillingGapID == nil, !presented.gaps.isEmpty else { return }
        let visible = visibleItemRange
        guard !visible.isEmpty else { return }
        for gap in presented.gaps where entries.gap(gap.id)?.failed == false {
            let position = presented.position(of: gap)
            guard position + 1 + gapFillThreshold >= visible.lowerBound,
                  position < visible.upperBound + gapFillThreshold
            else { continue }
            fillGap(gap.id)
            return
        }
    }

    private func fillGap(_ gapID: Int) {
        guard fillingGapID == nil, let gap = entries.gap(gapID), let context else { return }
        fillingGapID = gapID
        entries.setFailed(false, gap: gapID)
        updateGapViews()
        let visible = visibleItemRange
        let position = presented.gap(gapID).map(presented.position(of:)) ?? entries.position(of: gap)
        let fromNewer = position + 1 > (visible.lowerBound + visible.upperBound) / 2
        let source = self.source
        let limit = pageSize
        let known = entries
        let filter = entryFilter()
        let generation = self.generation
        let prepare = layoutPreparation(context: context)
        Task.detached(priority: .userInitiated) {
            do {
                let fill = try await Self.fetch(in: gap, fromNewer: fromNewer, source: source, limit: limit)
                let items = filter.newItems(in: fill.entries, excluding: known)
                let layouts = await prepare(items)
                await self.finishFill(gapID, items: items, layouts: layouts, fromNewer: fill.fromNewer,
                                      edge: fill.edge, closes: fill.closes, generation: generation)
            } catch {
                await self.fillFailed(gapID, error: error, generation: generation)
            }
        }
    }

    nonisolated private static func fetch(in gap: TimelineGap, fromNewer: Bool, source: any TimelineSource,
                                          limit: Int) async throws
        -> (entries: [TimelineEntry], fromNewer: Bool, edge: String?, closes: Bool)
    {
        if !fromNewer, let page = try await source.page(after: gap.olderID, limit: limit) {
            let inside = page.entries.filter { $0.id < gap.newerID }
            return (inside.reversed(), false, page.cursor, page.cursor.map { $0 >= gap.newerID } ?? true)
        }
        let page = try await source.page(until: gap.newerID, limit: limit)
        let inside = page.entries.filter { $0.id > gap.olderID }
        return (inside, true, page.cursor, page.cursor.map { $0 <= gap.olderID } ?? true)
    }

    private func finishFill(_ gapID: Int, items: [TimelineItem], layouts: [NoteLayout], fromNewer: Bool,
                            edge: String?, closes: Bool, generation: Int) {
        guard generation == self.generation else { return }
        fillingGapID = nil
        guard entries.gap(gapID) != nil else {
            fillGapsIfNeeded()
            return
        }
        entries.fill(gapID, with: items, layouts: layouts, fromNewer: fromNewer, edge: edge, closes: closes)
        services.learn(from: items.compactMap(\.note))
        presentEntries()
        didChangeEntries()
    }

    private func fillFailed(_ gapID: Int, error: any Error, generation: Int) {
        guard generation == self.generation else { return }
        fillingGapID = nil
        if (error as? MisskeyAPIError)?.isAuthenticationFailure == true {
            onAuthenticationFailure?()
        }
        entries.setFailed(true, gap: gapID)
        updateGapViews()
    }

    private func absorbTrailingGap() {
        guard let trailing = entries.removeTrailingGap() else { return }
        cursor = trailing.newerID
        reachedEnd = false
    }

    /// As the list knows it now, also for a gap that still shows after it closed.
    private func gapState(_ gapID: Int) -> TimelineGapView.State? {
        guard let gap = entries.gap(gapID) ?? presented.gap(gapID) else { return nil }
        if fillingGapID == gapID { return .loading }
        return gap.failed ? .failed : .idle
    }

    private func updateGapViews() {
        let kind = TimelineCollectionLayout.gapKind
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
            guard let state = gapState(indexPath.item),
                  let view = collectionView.supplementaryView(forElementKind: kind, at: indexPath) as? TimelineGapView
            else { continue }
            view.apply(state)
        }
    }

    private var showsNewNotes = false
    private var newNotesAuthors: [User] = []

    /// The account's own renotes are not news to it: alone, they do not show the button.
    private func showNewNotesButton(for newItems: ArraySlice<TimelineItem>) {
        guard !isAtTop else { return }
        let news = newItems.filter { item in
            guard let note = item.note else { return true }
            return !(note.isPureRenote && services.isAccount(note.user))
        }
        guard !news.isEmpty else { return }
        var seen = Set<String>()
        let authors = news.compactMap { $0.note?.user ?? $0.notification?.users.first } + newNotesAuthors
        newNotesAuthors = Array(authors.filter { seen.insert($0.id).inserted }.prefix(NewNotesButton.maxUsers))
        newNotesButton.loadAvatars(of: newNotesAuthors) { [weak self] users in
            self?.revealNewNotesButton(showing: users)
        }
    }

    private func revealNewNotesButton(showing users: [User]) {
        newNotesButton.users = users
        guard !showsNewNotes else {
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.layoutNewNotesButton()
                self.newNotesButton.layoutIfNeeded()
            }
            return
        }
        layoutNewNotesButton()
        showsNewNotes = true
        newNotesButton.isHidden = false
        newNotesButton.alpha = 0
        newNotesButton.transform = CGAffineTransform(translationX: 0, y: -12)
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.newNotesButton.alpha = 1
            self.newNotesButton.transform = .identity
        }
    }

    private func hideNewNotesButton() {
        newNotesAuthors = []
        newNotesButton.cancelLoading()
        guard showsNewNotes else { return }
        showsNewNotes = false
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.newNotesButton.alpha = 0
        } completion: { _ in
            if !self.showsNewNotes { self.newNotesButton.isHidden = true }
        }
    }

    private func hideNewNotesButtonIfReached() {
        guard showsNewNotes || newNotesButton.isLoadingAvatars else { return }
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        if isAtTop || listLayout.firstItem(endingBelow: top) == 0 { hideNewNotesButton() }
    }

    private func restore(from store: TimelineSnapshotStore) {
        guard let context else { return }
        isRestoring = true
        isLoadingPage = true
        setFooter(.loading)
        let filter = entryFilter()
        let prepare = layoutPreparation(context: context)
        Task.detached(priority: .userInitiated) {
            let snapshot = store.load()
            let items = snapshot.map { filter.newItems(in: $0.notes.map(TimelineEntry.note), excluding: TimelineEntries()) }
            let layouts = await prepare(items ?? [])
            await self.finishRestore(snapshot, items: items ?? [], layouts: layouts)
        }
    }

    private func finishRestore(_ snapshot: TimelineSnapshot?, items: [TimelineItem], layouts: [NoteLayout]) {
        isRestoring = false
        isLoadingPage = false
        let cutoff = Date(timeIntervalSinceNow: -TimelineSnapshotStore.shownLifetime)
        shownBefore = snapshot?.shown.filter { $0.value > cutoff } ?? [:]
        guard let snapshot, !items.isEmpty else {
            loadNextPage()
            pullToRefresh?.endRefreshing()
            // The first page is the newest: no refresh asked for meanwhile is left to do.
            refreshWaiters += nextRefresh?.waiters ?? []
            nextRefresh = nil
            flushRefreshWaiters()
            return
        }
        entries.restore(items, layouts: layouts, gaps: snapshot.gaps.map { ($0.newerID, $0.olderID) })
        newestID = snapshot.newestID ?? items.first?.id
        cursor = snapshot.cursor ?? items.last?.id
        absorbTrailingGap()
        services.learn(from: items.compactMap(\.note))
        presentEntries()
        didChangeEntries()
        refresh(keepingPosition: true)
        loadMoreIfNeeded()
    }

    @objc private func didEnterBackground() {
        saveSnapshot()
    }

    func saveSnapshot() {
        guard let snapshotStore, hasStarted, !isRestoring, !entries.isEmpty else { return }
        let kept = min(entries.count, TimelineSnapshotStore.noteLimit)
        let notes = entries.items.prefix(kept).compactMap(\.note)
        let gaps = entries.gaps.filter { entries.position(of: $0) < kept - 1 }
            .map { TimelineSnapshot.Gap(newerID: $0.newerID, olderID: $0.olderID) }
        let now = Date()
        let cutoff = now.addingTimeInterval(-TimelineSnapshotStore.shownLifetime)
        var shown = shownBefore.filter { $0.value > cutoff }
        for id in entries.shownNotes where shown[id] == nil {
            shown[id] = now
        }
        let snapshot = TimelineSnapshot(notes: notes, gaps: gaps, newestID: newestID,
                                        cursor: entries.items[kept - 1].id, shown: shown)
        let task = UIApplication.shared.beginBackgroundTask(withName: "TimelineSnapshot")
        Task.detached(priority: .utility) {
            snapshotStore.save(snapshot)
            guard task != .invalid else { return }
            await UIApplication.shared.endBackgroundTask(task)
        }
    }

    private func rememberShown() {
        let now = Date()
        for id in entries.shownNotes where shownBefore[id] == nil {
            shownBefore[id] = now
        }
    }

    /// Scrolled to the top (or not scrolled yet).
    var isAtTop: Bool {
        collectionView.contentOffset.y <= -collectionView.adjustedContentInset.top + 1
    }

    /// Refreshes with the pull-to-refresh spinner showing, as if pulled.
    func refreshShowingSpinner() {
        guard let pullToRefresh else { return refresh() }
        pullToRefresh.beginRefreshing()
    }

    /// Waits while the spinner of a tapped refresh is held, so its update lands as it goes away.
    private func waitForSpinner() async {
        guard let wait = pullToRefresh?.holdsUntil.timeIntervalSinceNow, wait > 0 else { return }
        try? await Task.sleep(for: .seconds(wait))
    }

    func scrollToTop(animated: Bool) {
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: animated)
    }

    /// A list that started over shows from its top. Already there (or pulled past it, which
    /// the finger may still hold), it stays as it is.
    private func showFromTop() {
        guard !isAtTop else { return }
        scrollToTop(animated: false)
    }

    private func updateFooter() {
        if !reachedEnd {
            setFooter(isLoadingPage || retryAfter == nil ? .loading : footerState)
        } else {
            setFooter(presented.isEmpty ? .empty : .hidden)
        }
    }

    private func setFooter(_ state: TimelineFooterView.State) {
        footerState = state
        listLayout.footerHeight = state.height
        let footer = collectionView.visibleSupplementaryViews(ofKind: TimelineCollectionLayout.footerKind).first
        (footer as? TimelineFooterView)?.apply(state)
    }

    private func prefetchWindow(around visible: Range<Int>) -> Range<Int> {
        let lower = max(0, visible.lowerBound - lookahead / 2)
        let upper = min(presented.count, visible.upperBound + lookahead)
        return lower..<max(lower, upper)
    }

    private func prefetchAround(visible: Range<Int>) {
        guard !presented.isEmpty else { return }
        let wanted = prefetchWindow(around: visible)
        guard wanted != prefetchedRange else { return }
        let fresh = wanted.filter { !prefetchedRange.contains($0) }
        prefetchedRange = wanted
        prefetch(fresh.map { presented.layouts[$0] })
    }

    private func prefetch(_ layouts: [NoteLayout]) {
        guard !layouts.isEmpty else { return }
        imagePipeline.prefetch(layouts.flatMap(\.emojiRequests))
        renderer.prefetch(layouts)
        imagePipeline.prefetch(layouts.flatMap(\.imageRequests))
        Blurhash.prefetch(layouts.flatMap(\.blurhashes))
        TimeLabelRenderer.prefetch(layouts.flatMap { $0.timeLabelRequests(at: clockTime) })
    }

    var visibleItemRange: Range<Int> {
        let visible = CGRect(origin: collectionView.contentOffset, size: collectionView.bounds.size)
        return listLayout.itemRange(in: visible)
    }

    private func configure(_ cell: NoteCell, at index: Int) {
        let layout = presented.layouts[index]
        let rendered = renderer.cached(layout)
        cell.apply(layout, rendered: rendered, imagePipeline: imagePipeline, now: clockTime)
        cell.accessibilityIdentifier = "note.\(presented.items[index].id)"
        if cell.customActionsProvider == nil {
            cell.customActionsProvider = { [weak self] in self?.accessibilityActions(for: $0) ?? [] }
            cell.menuProvider = { [weak self] in self?.menuElements(for: $0) ?? [] }
        }
        if rendered == nil {
            renderer.render(layout) { [weak cell] rendered in
                cell?.applyRendered(rendered)
            }
        }
    }

    func indexPath(forNote noteID: String) -> IndexPath? {
        presented.index(of: noteID).map { IndexPath(item: $0, section: 0) }
    }

    /// As the list has it now, or as it shows while its row waits to go.
    func item(forNote noteID: String) -> TimelineItem? {
        if let index = entries.index(of: noteID) { return entries.items[index] }
        return presented.index(of: noteID).map { presented.items[$0] }
    }

    /// A display state change (CW, long text, sensitive media): laid out right away.
    func updateState(ofNote noteID: String, _ update: (inout NoteDisplayState) -> Void) {
        guard let index = entries.index(of: noteID) else { return }
        entries.updateState(at: index, update)
        relayoutStale()
    }
}

extension TimelineViewController: NoteListHost {}

private struct EntryFilter: Sendable {
    let sensitiveMedia: SensitiveMediaDisplay
    let marks: NoteMarks
    let shownBefore: [String: Date]
    let accountUserID: String

    /// The entries of a response that can be shown and are not in the list yet, with the
    /// account's renotes and bookmarks marked. Notifications shown as notes are left out
    /// like notes. A note shows once (see `TimelineEntries`); a renote of a note shown
    /// before a restart is left out too, while the note itself shows where it is.
    func newItems(in entries: some Collection<TimelineEntry>, excluding known: TimelineEntries) -> [TimelineItem] {
        var seen = Set<String>()
        var shown = Set<String>()
        return entries.compactMap { entry -> TimelineItem? in
            guard !known.contains(entry.id), seen.insert(entry.id).inserted else { return nil }
            let note: Note
            switch entry {
            case .note(let entryNote):
                note = entryNote
            case .notification(let notification):
                guard notification.isShownAsNote, let notificationNote = notification.note else {
                    return TimelineItem(notification: notification)
                }
                note = notificationNote
            }
            guard !note.isUnavailableRenote, sensitiveMedia.shows(note) else { return nil }
            let item = TimelineItem(id: entry.id, note: marks.apply(to: note))
            if let noteID = item.shownNoteID(accountUserID: accountUserID) {
                guard !known.showsNote(of: item), !(note.isPureRenote && shownBefore[noteID] != nil),
                      shown.insert(noteID).inserted
                else { return nil }
            }
            return item
        }
    }

    /// Entries shown already that have changed: notes whose counts or reactions moved,
    /// and a notification group at the top that more reactions (or renotes) joined (it
    /// keeps its id, Misskey's is the oldest one's).
    func changed(in entries: some Collection<TimelineEntry>, known: TimelineEntries) -> [TimelineItem] {
        entries.compactMap { entry in
            guard let index = known.index(of: entry.id) else { return nil }
            let item: TimelineItem
            switch entry {
            case .note(let note):
                guard !note.isUnavailableRenote, sensitiveMedia.shows(note) else { return nil }
                item = TimelineItem(note: marks.apply(to: note))
            case .notification(let notification):
                guard !notification.isShownAsNote else { return nil }
                item = TimelineItem(notification: notification)
            }
            return item.contentHash == known.items[index].contentHash ? nil : item
        }
    }
}

extension TimelineViewController: UICollectionViewDataSource, UICollectionViewDelegate,
    UICollectionViewDataSourcePrefetching
{
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        presented.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: NoteCell.reuseIdentifier, for: indexPath) as! NoteCell
        configure(cell, at: indexPath.item)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> UICollectionReusableView {
        if kind == TimelineCollectionLayout.gapKind {
            let view = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind, withReuseIdentifier: TimelineGapView.reuseIdentifier, for: indexPath) as! TimelineGapView
            let gapID = indexPath.item
            view.onTap = { [weak self] in self?.fillGap(gapID) }
            if let state = gapState(gapID) { view.apply(state) }
            return view
        }
        let footer = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind, withReuseIdentifier: TimelineFooterView.reuseIdentifier, for: indexPath) as! TimelineFooterView
        footer.onRetry = { [weak self] in self?.retry() }
        footer.emptyMessage = emptyMessage
        footer.apply(footerState)
        return footer
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard indexPath.item < presented.count else { return }
        let cell = collectionView.cellForItem(at: indexPath) as? NoteCell
        let row = presented.items[indexPath.item]
        perform(cell?.tappedAction, on: item(forNote: row.id) ?? row, cell: cell)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        guard let cell = cell as? NoteCell else { return }
        cell.updateTimes(at: clockTime)
        displayStats.cellsDisplayed += 1
        if cell.isAwaitingRender { displayStats.renderLate += 1 }
        if cell.hasPendingImages { displayStats.imagesLate += 1 }
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        guard let noteID = (cell as? NoteCell)?.layout?.key.noteID, deferredNoteIDs.contains(noteID) else { return }
        Task { self.relayoutStale() }
    }

    func collectionView(_ collectionView: UICollectionView, willDisplaySupplementaryView view: UICollectionReusableView,
                        forElementKind elementKind: String, at indexPath: IndexPath) {
        (view as? TimelineFooterView)?.apply(footerState)
        if let view = view as? TimelineGapView, let state = gapState(indexPath.item) {
            view.apply(state)
        }
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        prefetch(indexPaths.compactMap { $0.item < presented.count ? presented.layouts[$0.item] : nil })
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        pullToRefresh?.scrollViewDidScroll(scrollView)
        guard !isAdjustingPosition else { return }
        scrollObserver?.timelineDidScroll(scrollView)
        prefetchAround(visible: visibleItemRange)
        loadMoreIfNeeded()
        fillGapsIfNeeded()
        hideNewNotesButtonIfReached()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        pullToRefresh?.scrollViewWillBeginDragging(scrollView)
        scrollObserver?.timelineWillBeginDragging(scrollView)
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        pullToRefresh?.scrollViewWillEndDragging(scrollView)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { scrollObserver?.timelineDidEndScrolling(scrollView) }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scrollObserver?.timelineDidEndScrolling(scrollView)
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        scrollObserver?.timelineDidEndScrolling(scrollView)
    }
}

final class TimelineFooterView: UICollectionReusableView {
    static let reuseIdentifier = "TimelineFooter"

    enum State: Equatable {
        case loading
        case failed(String)
        case empty
        case hidden

        var height: CGFloat {
            switch self {
            case .loading: 64
            case .failed: 132
            case .empty: 160
            case .hidden: 0
            }
        }
    }

    var onRetry: (() -> Void)?
    var emptyMessage = "まだノートがありません"

    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()
    private let retryButton = UIButton(configuration: .bordered())

    override init(frame: CGRect) {
        super.init(frame: frame)
        spinner.color = .hibari(.secondaryText)
        spinner.accessibilityIdentifier = "timeline.loadingMore"
        addSubview(spinner)
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .hibari(.secondaryText)
        label.textAlignment = .center
        label.numberOfLines = 2
        label.accessibilityIdentifier = "timeline.footerMessage"
        addSubview(label)
        var configuration = UIButton.Configuration.bordered()
        configuration.title = "再試行"
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = .hibari(.primaryText)
        retryButton.configuration = configuration
        retryButton.accessibilityIdentifier = "timeline.retry"
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)
        addSubview(retryButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ state: State) {
        switch state {
        case .loading:
            spinner.startAnimating()
            label.isHidden = true
            retryButton.isHidden = true
        case .failed(let message):
            spinner.stopAnimating()
            label.isHidden = false
            label.text = message
            retryButton.isHidden = false
        case .empty:
            spinner.stopAnimating()
            label.isHidden = false
            label.text = emptyMessage
            retryButton.isHidden = true
        case .hidden:
            spinner.stopAnimating()
            label.isHidden = true
            retryButton.isHidden = true
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        spinner.center = CGPoint(x: bounds.midX, y: 32)
        let width = bounds.width - 48
        let labelHeight = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let buttonSize = retryButton.isHidden ? .zero : retryButton.sizeThatFits(bounds.size)
        let total = labelHeight + (retryButton.isHidden ? 0 : 12 + buttonSize.height)
        let top = ((bounds.height - total) / 2).rounded()
        label.frame = CGRect(x: 24, y: top, width: width, height: labelHeight)
        retryButton.frame = CGRect(x: ((bounds.width - buttonSize.width) / 2).rounded(), y: label.frame.maxY + 12,
                                   width: buttonSize.width, height: buttonSize.height)
    }
}
