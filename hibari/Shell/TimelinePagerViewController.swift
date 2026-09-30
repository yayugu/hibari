import UIKit

final class TimelinePagerViewController: UIViewController {
    let session: TimelineSession
    let services: NoteServices
    private let pages: [TimelineSession.Timeline]
    private let showsPostedNotes: Bool
    private let savesTimelines: Bool
    private(set) var timelines: [TimelineViewController] = []
    /// The header's avatar was tapped (opens the side drawer).
    var onAccountButton: (() -> Void)?
    /// The server rejected the account's token.
    var onAuthenticationFailure: (() -> Void)?
    /// How far the bars are hidden (0 = shown, 1 = hidden), for the bottom bar the shell owns.
    var onBarsChange: ((CGFloat) -> Void)?

    private let pager = UIScrollView()
    private let header: HeaderView
    private let statusBarBackdrop = UIView()
    private let composeButton = ComposeButton()
    private let bars = BarsVisibilityController()
    private let pageFeedback = UISelectionFeedbackGenerator()

    private(set) var currentIndex = 0

    /// `title`: in the header, instead of the app's mark.
    init(session: TimelineSession, services: NoteServices, pages: [TimelineSession.Timeline], title: String? = nil,
         showsPostedNotes: Bool = false, savesTimelines: Bool = false) {
        self.session = session
        self.services = services
        self.pages = pages
        self.showsPostedNotes = showsPostedNotes
        self.savesTimelines = savesTimelines
        header = HeaderView(titles: pages.map(\.title), title: title)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var currentTimeline: TimelineViewController? {
        timelines.indices.contains(currentIndex) ? timelines[currentIndex] : nil
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

        for timeline in pages {
            let controller = TimelineViewController(timelineID: timeline.id, source: timeline.source, services: services)
            controller.emptyMessage = timeline.emptyMessage
            controller.waitsForActivation = true
            if savesTimelines {
                controller.snapshotStore = TimelineSnapshotStore(accountID: session.account.id, timelineID: timeline.id)
            }
            controller.scrollObserver = self
            controller.onAuthenticationFailure = { [weak self] in self?.onAuthenticationFailure?() }
            addChild(controller)
            pager.addSubview(controller.view)
            controller.didMove(toParent: self)
            timelines.append(controller)
        }
        currentTimeline?.activate()

        statusBarBackdrop.backgroundColor = .hibari(.background)
        view.addSubview(header)
        view.addSubview(statusBarBackdrop)
        view.addSubview(composeButton)

        composeButton.accessibilityIdentifier = "home.compose"
        composeButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.services.compose(from: self)
        }, for: .touchUpInside)
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
            timeline.contentInsets = UIEdgeInsets(top: safe.top + HeaderView.height, left: 0, bottom: safe.bottom, right: 0)
        }
        if !pager.isDragging && !pager.isDecelerating {
            pager.contentOffset.x = bounds.width * CGFloat(currentIndex)
        }

        statusBarBackdrop.frame = CGRect(x: 0, y: 0, width: bounds.width, height: safe.top)
        header.transform = .identity
        header.frame = CGRect(x: 0, y: safe.top, width: bounds.width, height: HeaderView.height)
        composeButton.transform = .identity
        composeButton.frame = CGRect(x: bounds.width - 16 - ComposeButton.size,
                                     y: bounds.height - safe.bottom - 16 - ComposeButton.size,
                                     width: ComposeButton.size, height: ComposeButton.size)
        bars.distance = HeaderView.height
        applyBars(bars.progress)
    }

    private func applyBars(_ progress: CGFloat) {
        let headerOffset = -HeaderView.height * progress
        header.transform = CGAffineTransform(translationX: 0, y: headerOffset)
        header.contentView.alpha = 1 - progress
        composeButton.transform = CGAffineTransform(translationX: 0, y: BottomBarView.barHeight * progress)
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

    func saveTimelines() {
        timelines.forEach { $0.saveSnapshot() }
    }

    @objc private func didPostNote(_ notification: Notification) {
        guard let note = notification.userInfo?["note"] as? Note, let timeline = currentTimeline else { return }
        refresh(timeline, until: note.id, attempts: 3)
    }

    private func refresh(_ timeline: TimelineViewController, until noteID: String, attempts: Int) {
        timeline.refresh { [weak self, weak timeline] in
            guard let self, let timeline, attempts > 1, !timeline.contains(noteID: noteID) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.refresh(timeline, until: noteID, attempts: attempts - 1)
            }
        }
    }

    func update(_ account: Account) {
        guard session.account.id == account.id else { return }
        configureAccountButton(account)
    }

    func setDrawerProgress(_ progress: CGFloat) {
        header.accountButton.alpha = 1 - progress
    }

    private func configureAccountButton(_ account: Account) {
        header.accountButton.accessibilityValue = account.acct
        header.setAvatar(account.avatarUrl)
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
