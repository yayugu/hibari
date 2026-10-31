import UIKit

final class TimelinePagerViewController: UIViewController {
    let session: TimelineSession
    let services: NoteServices
    private var pages: [TimelineSession.Timeline]
    private let showsPostedNotes: Bool
    private let savesTimelines: Bool
    private(set) var timelines: [TimelineViewController] = []
    /// The header's avatar was tapped (opens the side drawer).
    var onAccountButton: (() -> Void)?
    /// The server rejected the account's token.
    var onAuthenticationFailure: (() -> Void)?
    /// How far the bars are hidden (0 = shown, 1 = hidden), for the bottom bar the shell owns.
    var onBarsChange: ((CGFloat) -> Void)?
    /// The shown page changed.
    var onPageChange: (() -> Void)?

    private let pager = UIScrollView()
    private let header: HeaderView
    private let statusBarBackdrop = UIView()
    private let bars = BarsVisibilityController()
    private let pageFeedback = UISelectionFeedbackGenerator()

    private(set) var currentIndex = 0 {
        didSet { onPageChange?() }
    }

    /// `title`: in the header, instead of the app's mark.
    init(session: TimelineSession, services: NoteServices, pages: [TimelineSession.Timeline], title: String? = nil,
         showsPostedNotes: Bool = false, savesTimelines: Bool = false) {
        self.session = session
        self.services = services
        self.pages = pages
        self.showsPostedNotes = showsPostedNotes
        self.savesTimelines = savesTimelines
        header = HeaderView(tabs: pages.map(\.tab), title: title)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var currentTimeline: TimelineViewController? {
        timelines.indices.contains(currentIndex) ? timelines[currentIndex] : nil
    }

    /// The shown tab's channel: composing on it posts in it.
    var composeChannel: Channel? {
        pages.indices.contains(currentIndex) ? pages[currentIndex].channel : nil
    }

    var barsProgress: CGFloat { bars.progress }

    /// The first timeline is shown and settled.
    var isAtFirstTimeline: Bool {
        pager.contentOffset.x <= 0.5 && !pager.isDragging && !pager.isDecelerating
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .hibari(.background)

        pager.isPagingEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.scrollsToTop = false
        pager.contentInsetAdjustmentBehavior = .never
        pager.delegate = self
        view.addSubview(pager)

        timelines = pages.map(makeTimeline)
        currentTimeline?.activate()

        statusBarBackdrop.backgroundColor = .hibari(.background)
        view.addSubview(header)
        view.addSubview(statusBarBackdrop)

        if showsPostedNotes {
            NotificationCenter.default.addObserver(self, selector: #selector(didPostNote(_:)),
                                                   name: NoteServices.didPostNote, object: services)
        }
        header.tabStrip.onSelect = { [weak self] index in self?.select(index, animated: true) }
        header.accountButton.addAction(UIAction { [weak self] _ in self?.onAccountButton?() }, for: .touchUpInside)
        configureAccountButton(session.account)
        bars.onChange = { [weak self] progress in self?.applyBars(progress) }
        updateScrollsToTop()
    }

    private func makeTimeline(_ timeline: TimelineSession.Timeline) -> TimelineViewController {
        let controller = TimelineViewController(timelineID: timeline.id, source: timeline.source, services: services)
        controller.emptyMessage = timeline.emptyMessage
        controller.waitsForActivation = true
        if savesTimelines, timeline.source.refreshPolicy == .preserveHistory {
            controller.snapshotStore = TimelineSnapshotStore(accountID: session.account.id, timelineID: timeline.id)
        }
        controller.scrollObserver = self
        controller.onAuthenticationFailure = { [weak self] in self?.onAuthenticationFailure?() }
        addChild(controller)
        pager.addSubview(controller.view)
        controller.didMove(toParent: self)
        return controller
    }

    /// The settings changed the tabs. The timelines that stay keep what they have, and the
    /// one shown stays shown (or the one now in its place).
    func setPages(_ pages: [TimelineSession.Timeline]) {
        guard pages.map(\.id) != self.pages.map(\.id) || pages.map(\.tab) != self.pages.map(\.tab) else { return }
        self.pages = pages
        header.tabStrip.setTabs(pages.map(\.tab))
        guard isViewLoaded else { return }
        let shownID = currentTimeline?.timelineID
        var removed = Dictionary(uniqueKeysWithValues: timelines.map { ($0.timelineID, $0) })
        timelines = pages.map { removed.removeValue(forKey: $0.id) ?? makeTimeline($0) }
        for timeline in removed.values {
            timeline.saveSnapshot()
            timeline.willMove(toParent: nil)
            timeline.view.removeFromSuperview()
            timeline.removeFromParent()
        }
        currentIndex = timelines.firstIndex { $0.timelineID == shownID } ?? max(0, min(currentIndex, timelines.count - 1))
        currentTimeline?.activate()
        updateScrollsToTop()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        header.tabStrip.setProgress(CGFloat(currentIndex))
        if let scrollView = currentTimeline?.collectionView {
            bars.reset(for: scrollView)
        }
        bars.show(animated: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if navigationController?.topViewController !== self {
            bars.show(animated: animated)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let safe = view.safeAreaInsets

        pager.frame = bounds
        pager.contentSize = CGSize(width: bounds.width * CGFloat(timelines.count), height: bounds.height)
        for (index, timeline) in timelines.enumerated() {
            timeline.view.frame = CGRect(x: bounds.width * CGFloat(index), y: 0, width: bounds.width, height: bounds.height)
            timeline.contentInsets = UIEdgeInsets(top: safe.top + header.height, left: 0, bottom: safe.bottom, right: 0)
        }
        if !pager.isDragging && !pager.isDecelerating {
            pager.contentOffset.x = bounds.width * CGFloat(currentIndex)
        }

        statusBarBackdrop.frame = CGRect(x: 0, y: 0, width: bounds.width, height: safe.top)
        header.transform = .identity
        header.frame = CGRect(x: 0, y: safe.top, width: bounds.width, height: header.height)
        bars.distance = header.height
        applyBars(bars.progress)
    }

    private func applyBars(_ progress: CGFloat) {
        let headerOffset = -header.height * progress
        header.transform = CGAffineTransform(translationX: 0, y: headerOffset)
        header.contentView.alpha = 1 - progress
        for timeline in timelines {
            timeline.barsOffset = -headerOffset
        }
        onBarsChange?(progress)
    }

    func select(_ index: Int, animated: Bool) {
        guard timelines.indices.contains(index) else { return }
        timelines[index].activate()
        if index == currentIndex, animated {
            scrollToTop()
            return
        }
        pager.setContentOffset(CGPoint(x: pager.bounds.width * CGFloat(index), y: 0), animated: animated)
        if !animated { pageDidSettle() }
    }

    private func pageDidSettle() {
        let width = max(1, pager.bounds.width)
        let index = Int((pager.contentOffset.x / width).rounded())
        guard index != currentIndex, timelines.indices.contains(index) else { return }
        timelines[index].activate()
        currentIndex = index
        updateScrollsToTop()
        if let scrollView = currentTimeline?.collectionView {
            bars.reset(for: scrollView)
        }
        bars.show(animated: true)
    }

    private func updateScrollsToTop() {
        for (index, timeline) in timelines.enumerated() {
            timeline.collectionView.scrollsToTop = index == currentIndex
        }
    }

    func scrollToTop() {
        currentTimeline?.scrollToTop(animated: true)
        bars.show(animated: true)
    }

    /// At the top, refreshes the current timeline with the spinner showing; otherwise scrolls to the top.
    func refreshOrScrollToTop() {
        guard let timeline = currentTimeline, timeline.isLoaded, timeline.isAtTop else { return scrollToTop() }
        timeline.refreshShowingSpinner()
        bars.show(animated: true)
    }

    func saveTimelines() {
        timelines.forEach { $0.saveSnapshot() }
    }

    /// A renote goes in above the screen: the list stays put under the note just renoted
    /// (which plays its animation there).
    @objc private func didPostNote(_ notification: Notification) {
        guard let note = notification.userInfo?["note"] as? Note, let timeline = currentTimeline else { return }
        timeline.refresh(until: note.id, keepingPosition: note.isPureRenote)
    }

    func update(_ account: Account) {
        guard session.account.id == account.id else { return }
        configureAccountButton(account)
    }

    func setDrawerProgress(_ progress: CGFloat) {
        header.accountButton.alpha = 1 - progress
    }

    /// Beside the side rail, which has the account.
    func setUsesRail(_ usesRail: Bool) {
        guard usesRail != header.usesRail else { return }
        header.usesRail = usesRail
        viewIfLoaded?.setNeedsLayout()
    }

    private func configureAccountButton(_ account: Account) {
        header.accountButton.accessibilityValue = account.acct
        header.setAvatar(account.avatarUrl)
    }
}

private extension TimelineSession.Timeline {
    var tab: TabStripView.Tab {
        TabStripView.Tab(title: title, mark: mediaOnly ? .media : nil,
                         accessibilityLabel: mediaOnly ? TimelineTab.mediaTitle(title) : nil)
    }
}

extension TimelinePagerViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === pager else { return }
        let progress = pager.contentOffset.x / max(1, pager.bounds.width)
        if pager.isTracking || pager.isDecelerating {
            for index in [Int(progress.rounded(.down)), Int(progress.rounded(.up))] where timelines.indices.contains(index) {
                timelines[index].activate()
            }
        }
        let previous = header.tabStrip.selectedIndex
        header.tabStrip.setProgress(progress)
        if header.tabStrip.selectedIndex != previous && pager.isTracking {
            pageFeedback.selectionChanged()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if scrollView === pager { pageDidSettle() }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if scrollView === pager { pageDidSettle() }
    }
}

extension TimelinePagerViewController: TimelineScrollObserver {
    func timelineDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === currentTimeline?.collectionView else { return }
        bars.scrollViewDidScroll(scrollView)
    }

    func timelineDidEndScrolling(_ scrollView: UIScrollView) {
        guard scrollView === currentTimeline?.collectionView else { return }
        bars.scrollViewDidEndScrolling(scrollView)
    }

    func timelineDidMoveContent(_ scrollView: UIScrollView) {
        guard scrollView === currentTimeline?.collectionView else { return }
        bars.reset(for: scrollView)
    }
}
