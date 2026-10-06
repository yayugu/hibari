import UIKit

final class NoteDetailViewController: UIViewController {
    let services: NoteServices
    private(set) lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: listLayout)
    private let listLayout = TimelineCollectionLayout()
    private let focusedView: FocusedNoteView
    private let moreButton = ChromeButton.plain("ellipsis", label: "その他", identifier: "noteDetail.more")
    private lazy var header = NavigationHeaderView(title: "ノート", identifier: "noteDetail", trailingButton: moreButton)
    private var note: Note
    /// The note's author, for the follow button.
    private var author: UserDetailed?

    /// What the thread holds: changes land here at once.
    private var ancestors: [TimelineItem] = []
    private var replies: [TimelineItem] = []
    /// What the rows show: laid out from `ancestors` and `replies`, behind while the list is
    /// held.
    private var shown = Shown()
    /// Laid out and waiting for the hold to end.
    private var waiting: Shown?
    private var needsHeights = false
    /// Keeps the rows still while a button's answer to a tap plays on one.
    let listHold = ListHold()

    private struct Shown {
        var ancestors: [TimelineItem] = []
        var ancestorLayouts: [NoteLayout] = []
        var replies: [TimelineItem] = []
        var replyLayouts: [NoteLayout] = []
    }

    private var context: LayoutContext?
    private var layoutGeneration = 0
    private var focusedHeight: CGFloat = 0
    private var didPlaceFocused = false

    private var repliesCursor: String
    private var repliesReachedEnd = false
    private var isLoadingReplies = false
    private var footerState = TimelineFooterView.State.loading
    private var clockTimer: Timer?

    private static let repliesPageSize = 30

    init(note: Note, services: NoteServices) {
        self.note = note
        self.services = services
        focusedView = FocusedNoteView(note: note, services: services)
        repliesCursor = note.id
        super.init(nibName: nil, bundle: nil)
        if let parent = note.reply, services.sensitiveMedia.shows(parent) {
            ancestors = [TimelineItem(note: parent)]
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .hibari(.background)

        collectionView.backgroundColor = .hibari(.background)
        collectionView.register(NoteCell.self, forCellWithReuseIdentifier: NoteCell.reuseIdentifier)
        collectionView.register(FocusedNoteCell.self, forCellWithReuseIdentifier: FocusedNoteCell.reuseIdentifier)
        collectionView.register(TimelineFooterView.self, forSupplementaryViewOfKind: TimelineCollectionLayout.footerKind,
                                withReuseIdentifier: TimelineFooterView.reuseIdentifier)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.accessibilityIdentifier = "noteDetail"
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(collectionView)
        listLayout.footerHeight = footerState.height
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.menu = services.menu(for: note, from: self)
        header.install(in: self)

        configureFocusedView()
        listHold.onRelease = { [weak self] in self?.showWaiting() }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self,
                                 UITraitDisplayScale.self]) { (self: Self, _) in
            self.updateContextIfNeeded()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(noteDidChange(_:)),
                                               name: ReactionController.didChange, object: services.reactions)
        NotificationCenter.default.addObserver(self, selector: #selector(noteDidChange(_:)),
                                               name: RenoteController.didChange, object: services.renotes)
        NotificationCenter.default.addObserver(self, selector: #selector(noteDidChange(_:)),
                                               name: BookmarkController.didChange, object: services.bookmarks)
        NotificationCenter.default.addObserver(self, selector: #selector(noteDidChange(_:)),
                                               name: PollController.didChange, object: services.polls)
        NotificationCenter.default.addObserver(self, selector: #selector(layoutInputDidLoad),
                                               name: ImagePipeline.mediaSizesDidChange, object: services.imagePipeline)
        if let linkPreviews = services.engine.linkPreviews as? LinkPreviewStore {
            NotificationCenter.default.addObserver(self, selector: #selector(layoutInputDidLoad),
                                                   name: LinkPreviewStore.didLoad, object: linkPreviews)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(rendererDidRedraw(_:)),
                                               name: NoteRenderer.didRedraw, object: services.renderer)
        NotificationCenter.default.addObserver(self, selector: #selector(didPostNote(_:)),
                                               name: NoteServices.didPostNote, object: services)
        NotificationCenter.default.addObserver(self, selector: #selector(didDeleteNote(_:)),
                                               name: NoteServices.didDeleteNote, object: services)
        NotificationCenter.default.addObserver(self, selector: #selector(didHideUser(_:)),
                                               name: NoteServices.didHideUser, object: services)
        NotificationCenter.default.addObserver(self, selector: #selector(relationDidChange(_:)),
                                               name: NoteServices.didChangeRelation, object: services)
        load()
        loadAuthor()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startClock()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        clockTimer?.invalidate()
        clockTimer = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateContextIfNeeded()
        updateBottomInset()
    }

    private func configureFocusedView() {
        focusedView.onLink = { [weak self] link in
            guard let self else { return }
            self.services.open(link: link, from: self)
        }
        focusedView.onMedia = { [weak self] owner, index in self?.openFocusedMedia(owner: owner, index: index) }
        focusedView.onQuote = { [weak self] in
            guard let self, let quoted = self.note.renote else { return }
            self.services.openNote(quoted, from: self)
        }
        focusedView.onReaction = { [weak self] key, frame in
            guard let self else { return }
            self.services.reactionTapped(key, on: self.note, origin: frame)
        }
        focusedView.onReact = { [weak self] frame in
            guard let self else { return }
            self.services.reactButtonTapped(self.note, from: self, origin: frame)
        }
        focusedView.onReply = { [weak self] in
            guard let self else { return }
            self.services.replyTapped(self.note, from: self)
        }
        focusedView.onRenote = { [weak self] in
            guard let self else { return }
            self.services.renoteTapped(self.note, from: self) { [weak self] renoted in
                self?.focusedView.playActionAnimation(renoted ? .renote : .undoRenote)
            }
        }
        focusedView.onBookmark = { [weak self] in
            guard let self else { return }
            self.services.bookmarkTapped(self.note) { [weak self] bookmarked in
                self?.focusedView.playActionAnimation(.bookmark(bookmarked))
            }
        }
        focusedView.onShare = { [weak self] in
            guard let self else { return }
            self.services.share(self.note, from: self)
        }
        focusedView.onUser = { [weak self] user in
            guard let self else { return }
            self.services.openUser(user, from: self)
        }
        focusedView.onFollow = { [weak self] in
            guard let self, let author = self.author else { return }
            self.services.followTapped(author, from: self)
        }
        focusedView.onResize = { [weak self] in self?.focusedContentDidChange() }
    }

    /// The follow button shows if the account does not follow the author (yet): once there,
    /// it stays, for following and taking it back.
    private func loadAuthor() {
        guard let client = services.client, !services.isAccount(note.user) else { return }
        let userID = note.user.id
        Task { [weak self] in
            guard let author = try? await client.user(id: userID), let self else { return }
            self.author = author
            let state = FollowState(author.relation)
            guard author.relation.isKnown, state != .following, state != .blocking else { return }
            self.focusedView.followState = state
        }
    }

    @objc private func relationDidChange(_ notification: Notification) {
        guard var author, notification.userInfo?["userID"] as? String == author.user.id,
              let relation = notification.userInfo?["relation"] as? UserDetailed.Relation
        else { return }
        author.relation = relation
        self.author = author
        if focusedView.followState != nil { focusedView.followState = FollowState(relation) }
    }

    private func setFocused(_ note: Note) {
        self.note = note
        focusedView.update(note)
        moreButton.menu = services.menu(for: note, from: self)
    }

    @objc private func didPostNote(_ notification: Notification) {
        guard let posted = notification.userInfo?["note"] as? Note,
              posted.replyId == note.id || posted.renoteId == note.id, let client = services.client
        else { return }
        let noteID = note.id
        Task { [weak self] in
            guard let self, let fresh = try? await client.note(noteID) else { return }
            self.setFocused(self.services.marked(fresh))
        }
        if posted.replyId == note.id && repliesReachedEnd {
            repliesReachedEnd = false
            loadMoreReplies()
        }
    }

    @objc private func didDeleteNote(_ notification: Notification) {
        guard let noteID = notification.userInfo?["noteID"] as? String else { return }
        if TimelineItem(note: note).isGone(afterDeleting: noteID) || ancestors.contains(where: { $0.id == noteID }) {
            guard let navigation = navigationController else { return }
            if navigation.topViewController === self {
                navigation.popViewController(animated: true)
            } else {
                navigation.viewControllers.removeAll { $0 === self }
            }
            return
        }
        let count = replies.count
        replies.removeAll { $0.isGone(afterDeleting: noteID) }
        if replies.count != count { relayout() }
    }

    @objc private func didHideUser(_ notification: Notification) {
        guard let userID = notification.userInfo?["userID"] as? String else { return }
        let count = replies.count
        replies.removeAll { reply in
            reply.note.map { $0.user.id == userID || $0.renote?.user.id == userID } ?? false
        }
        if replies.count != count { relayout() }
    }

    private func focusedContentDidChange() {
        guard isViewLoaded, collectionView.bounds.width > 0 else { return }
        let height = measureFocused()
        guard height != focusedHeight else { return }
        focusedHeight = height
        applyHeights()
    }

    private func measureFocused() -> CGFloat {
        focusedView.sizeThatFits(CGSize(width: collectionView.bounds.width, height: .greatestFiniteMagnitude)).height
    }

    private func openFocusedMedia(owner: MediaOwner, index: Int) {
        guard let files = (owner == .note ? note : note.renote)?.visualFiles, files.indices.contains(index) else { return }
        let source = MediaViewerSource(
            target: { [weak self] index in self?.focusedView.mediaTarget(owner: owner, index: index) },
            setHidden: { [weak self] index in self?.focusedView.setHiddenMedia(owner: owner, index: index) })
        MediaViewerController.present(files: files, startIndex: index, source: source,
                                      imagePipeline: services.imagePipeline, from: self)
    }

    private func load() {
        guard let client = services.client else {
            setFooter(.hidden)
            return
        }
        let noteID = note.id
        Task { [weak self] in
            guard let self, let fresh = try? await client.note(noteID) else { return }
            self.setFocused(self.services.marked(fresh))
        }
        services.bookmarks.refresh(noteID)
        if note.replyId != nil {
            Task { [weak self] in
                guard let chain = try? await client.conversation(of: noteID) else { return }
                self?.setAncestors(chain.reversed())
            }
        }
        loadMoreReplies()
    }

    private func setAncestors(_ notes: [Note]) {
        let marks = services.marks
        let sensitiveMedia = services.sensitiveMedia
        ancestors = notes.filter { sensitiveMedia.shows($0) }.map { TimelineItem(note: marks.apply(to: $0)) }
        relayout()
    }

    private func loadMoreReplies() {
        guard let client = services.client, !isLoadingReplies, !repliesReachedEnd else { return }
        isLoadingReplies = true
        setFooter(.loading)
        let noteID = note.id
        let cursor = repliesCursor
        let limit = Self.repliesPageSize
        Task { [weak self] in
            do {
                let page = try await client.replies(to: noteID, since: cursor, limit: limit)
                self?.appendReplies(page, isEnd: page.count < limit)
            } catch {
                self?.repliesFailed(error)
            }
        }
    }

    private func appendReplies(_ page: [Note], isEnd: Bool) {
        isLoadingReplies = false
        repliesReachedEnd = isEnd
        if let last = page.last { repliesCursor = last.id }
        let known = Set(replies.map(\.id))
        let marks = services.marks
        let sensitiveMedia = services.sensitiveMedia
        replies += page.filter { !known.contains($0.id) && sensitiveMedia.shows($0) }
            .map { TimelineItem(note: marks.apply(to: $0)) }
        setFooter(isEnd ? .hidden : .loading)
        relayout()
    }

    private func repliesFailed(_ error: any Error) {
        isLoadingReplies = false
        setFooter(.failed((error as? LocalizedError)?.errorDescription ?? "返信を読み込めませんでした"))
    }

    private func setFooter(_ state: TimelineFooterView.State) {
        footerState = state
        listLayout.footerHeight = state.height
        let footer = collectionView.visibleSupplementaryViews(ofKind: TimelineCollectionLayout.footerKind).first
        (footer as? TimelineFooterView)?.apply(state)
        updateBottomInset()
    }

    private func updateContextIfNeeded() {
        let width = view.bounds.width
        guard width > 0 else { return }
        let newContext = LayoutContext(width: width, safeAreaInsets: view.safeAreaInsets, traits: traitCollection,
                                       revealsSensitiveMedia: services.sensitiveMedia == .show)
        guard newContext != context else { return }
        context = newContext
        focusedHeight = measureFocused()
        applyHeights()
        relayout()
    }

    private func relayout() {
        guard let context else { return }
        layoutGeneration += 1
        let generation = layoutGeneration
        var ancestors = self.ancestors
        for index in ancestors.indices {
            ancestors[index].state.thread = index == 0 ? [.below] : [.above, .below]
        }
        let replies = self.replies
        let engine = services.engine
        let imagePipeline = services.imagePipeline
        let now = services.clock.now()
        Task.detached(priority: .userInitiated) {
            let items = ancestors + replies
            let emojis = engine.customEmojis(in: items)
            async let text: Void = imagePipeline.prepareSizes(of: emojis.text, timeout: .seconds(3))
            async let reactions: Void = imagePipeline.prepareSizes(of: emojis.reactions, timeout: .milliseconds(800))
            async let links: Void = engine.linkPreviews.prepare(engine.linkPreviewURLs(in: items), timeout: .seconds(2))
            _ = await (text, reactions, links)
            let layouts = engine.layouts(for: items, context: context, now: now)
            await self.show(ancestors: ancestors, replies: replies, layouts: layouts, generation: generation)
        }
    }

    private func show(ancestors: [TimelineItem], replies: [TimelineItem], layouts: [NoteLayout], generation: Int) {
        guard generation == layoutGeneration else { return }
        waiting = Shown(ancestors: ancestors, ancestorLayouts: Array(layouts.prefix(ancestors.count)),
                        replies: replies, replyLayouts: Array(layouts.suffix(replies.count)))
        showWaiting()
    }

    /// Shows what was laid out since the rows last changed, unless the list is held.
    private func showWaiting() {
        guard !listHold.isHeld else { return }
        if let waiting {
            self.waiting = nil
            shown = waiting
            focusedView.showsThreadLine = !waiting.ancestors.isEmpty
            needsHeights = true
        }
        if needsHeights { applyHeights() }
    }

    private var focusedRow: Int { shown.ancestors.count }

    /// Lays the rows out again (reloading them); while the list is held, once it ends.
    private func applyHeights() {
        needsHeights = true
        guard !listHold.isHeld else { return }
        needsHeights = false
        let previousTop = listLayout.offset(ofItem: listLayoutFocusedRow)
        let screenY = previousTop.map { $0 - collectionView.contentOffset.y }
        listLayout.setHeights(shown.ancestorLayouts.map(\.height) + [focusedHeight] + shown.replyLayouts.map(\.height))
        listLayoutFocusedRow = focusedRow
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
        updateBottomInset()
        guard let top = listLayout.offset(ofItem: focusedRow) else { return }
        if !didPlaceFocused {
            didPlaceFocused = shown.ancestors.count >= ancestors.count
            collectionView.contentOffset.y = top - collectionView.adjustedContentInset.top
        } else if let screenY {
            collectionView.contentOffset.y = top - screenY
        }
    }

    private var listLayoutFocusedRow = 0

    private func updateBottomInset() {
        guard let top = listLayout.offset(ofItem: focusedRow) else { return }
        let safe = view.safeAreaInsets
        let visible = collectionView.bounds.height - safe.top - safe.bottom
        let below = collectionView.collectionViewLayout.collectionViewContentSize.height - top
        let extra = max(0, visible - below)
        if collectionView.contentInset.bottom != extra {
            collectionView.contentInset.bottom = extra
        }
    }

    @objc private func noteDidChange(_ notification: Notification) {
        guard let change = notification.userInfo?["change"] as? any NoteChange else { return }
        if note.contains(noteID: change.noteID) {
            setFocused(note.applying(change))
        }
        var changed = false
        for index in ancestors.indices {
            guard let item = ancestors[index].applying(change) else { continue }
            ancestors[index] = item
            changed = true
        }
        for index in replies.indices {
            guard let item = replies[index].applying(change) else { continue }
            replies[index] = item
            changed = true
        }
        if changed { relayout() }
    }

    /// An emoji size or a link's preview that layouts went without is in.
    @objc private func layoutInputDidLoad() {
        let engine = services.engine
        if (shown.ancestorLayouts + shown.replyLayouts).contains(where: { !engine.isCurrent($0) }) {
            relayout()
        }
    }

    @objc private func rendererDidRedraw(_ notification: Notification) {
        guard let rendered = notification.userInfo?["note"] as? RenderedNote else { return }
        for case let cell as NoteCell in collectionView.visibleCells {
            cell.applyRendered(rendered)
        }
    }

    private func startClock() {
        clockTimer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = self.services.clock.now()
                for case let cell as NoteCell in self.collectionView.visibleCells {
                    cell.updateTimes(at: now)
                }
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private enum Row {
        case ancestor(Int)
        case focused
        case reply(Int)
    }

    private func row(at index: Int) -> Row {
        if index < shown.ancestors.count { return .ancestor(index) }
        if index == shown.ancestors.count { return .focused }
        return .reply(index - shown.ancestors.count - 1)
    }

    private func item(at index: Int) -> (TimelineItem, NoteLayout)? {
        switch row(at: index) {
        case .ancestor(let i): (shown.ancestors[i], shown.ancestorLayouts[i])
        case .reply(let i): (shown.replies[i], shown.replyLayouts[i])
        case .focused: nil
        }
    }
}

extension NoteDetailViewController: NoteListHost {
    func indexPath(forNote noteID: String) -> IndexPath? {
        if let index = shown.ancestors.firstIndex(where: { $0.id == noteID }) {
            return IndexPath(item: index, section: 0)
        }
        if let index = shown.replies.firstIndex(where: { $0.id == noteID }) {
            return IndexPath(item: shown.ancestors.count + 1 + index, section: 0)
        }
        return nil
    }

    func item(forNote noteID: String) -> TimelineItem? {
        (shown.ancestors + shown.replies).first { $0.id == noteID }
    }

    func updateState(ofNote noteID: String, _ update: (inout NoteDisplayState) -> Void) {
        if let index = ancestors.firstIndex(where: { $0.id == noteID }) {
            update(&ancestors[index].state)
        } else if let index = replies.firstIndex(where: { $0.id == noteID }) {
            update(&replies[index].state)
        } else {
            return
        }
        relayout()
    }
}

extension NoteDetailViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        shown.ancestors.count + 1 + shown.replies.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let (_, layout) = item(at: indexPath.item) else {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: FocusedNoteCell.reuseIdentifier,
                                                          for: indexPath) as! FocusedNoteCell
            cell.host(focusedView)
            return cell
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: NoteCell.reuseIdentifier,
                                                      for: indexPath) as! NoteCell
        let renderer = services.renderer
        let rendered = renderer.cached(layout)
        cell.apply(layout, rendered: rendered, imagePipeline: services.imagePipeline, now: services.clock.now())
        cell.accessibilityIdentifier = indexPath.item < shown.ancestors.count
            ? "noteDetail.ancestor.\(indexPath.item)" : "noteDetail.reply.\(indexPath.item - shown.ancestors.count - 1)"
        if cell.customActionsProvider == nil {
            cell.customActionsProvider = { [weak self] in self?.accessibilityActions(for: $0) ?? [] }
            cell.menuProvider = { [weak self] in self?.menuElements(for: $0) ?? [] }
        }
        if rendered == nil {
            renderer.render(layout) { [weak cell] rendered in cell?.applyRendered(rendered) }
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> UICollectionReusableView {
        let footer = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind, withReuseIdentifier: TimelineFooterView.reuseIdentifier, for: indexPath) as! TimelineFooterView
        footer.onRetry = { [weak self] in self?.loadMoreReplies() }
        footer.apply(footerState)
        return footer
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        item(at: indexPath.item) != nil
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let (item, _) = item(at: indexPath.item) else { return }
        let cell = collectionView.cellForItem(at: indexPath) as? NoteCell
        perform(cell?.tappedAction, on: item, cell: cell)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplaySupplementaryView view: UICollectionReusableView,
                        forElementKind elementKind: String, at indexPath: IndexPath) {
        (view as? TimelineFooterView)?.apply(footerState)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let bottom = scrollView.contentOffset.y + scrollView.bounds.height
        if bottom > scrollView.contentSize.height - scrollView.bounds.height, footerState == .loading {
            loadMoreReplies()
        }
    }
}

private final class FocusedNoteCell: UICollectionViewCell {
    static let reuseIdentifier = "FocusedNoteCell"
    private weak var hosted: UIView?

    func host(_ view: UIView) {
        if view.superview !== contentView {
            contentView.addSubview(view)
        }
        hosted = view
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let hosted, hosted.superview === contentView {
            hosted.frame = contentView.bounds
        }
    }
}
