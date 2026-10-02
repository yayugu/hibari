import UIKit

final class BookmarksViewController: UIViewController {
    enum Page: Int, CaseIterable {
        case bookmarks
        case likes

        var title: String {
            switch self {
            case .bookmarks: "ブックマーク"
            case .likes: "いいね"
            }
        }

        var icon: String {
            switch self {
            case .bookmarks: "Bookmark"
            case .likes: "Heart"
            }
        }

        var timelineID: String {
            switch self {
            case .bookmarks: "bookmarks"
            case .likes: "likes"
            }
        }

        var emptyMessage: String {
            switch self {
            case .bookmarks: "ブックマークしたノートはまだありません"
            case .likes: "いいねしたノートはまだありません"
            }
        }
    }

    let services: NoteServices

    private let tabStrip = IconTabStripView(tabs: Page.allCases.map {
        IconTabStripView.Tab(title: $0.title, icon: UIImage(named: $0.icon)?.withRenderingMode(.alwaysTemplate))
    }, identifierPrefix: "bookmarks.tab")
    private lazy var header = NavigationHeaderView(title: "ブックマーク", identifier: "bookmarks", tabs: tabStrip)
    private let statusBarBackdrop = UIView()
    private let pager = BackSwipePager()
    private var timelines: [TimelineViewController] = []
    private let bars = BarsVisibilityController()
    private let pageFeedback = UISelectionFeedbackGenerator()

    private(set) var currentPage = Page.bookmarks
    private var pagesBehind: Set<Page> = []

    init(services: NoteServices) {
        self.services = services
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var currentTimeline: TimelineViewController? {
        timelines.indices.contains(currentPage.rawValue) ? timelines[currentPage.rawValue] : nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .hibari(.background)
        view.accessibilityIdentifier = "bookmarks"

        pager.isPagingEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.scrollsToTop = false
        pager.contentInsetAdjustmentBehavior = .never
        pager.delegate = self
        view.addSubview(pager)

        if let client = services.client {
            for page in Page.allCases {
                let source: any TimelineSource = switch page {
                case .bookmarks: BookmarkedNotesSource(client: client)
                case .likes: ReactedNotesSource(client: client, userID: services.account.userID)
                }
                let timeline = TimelineViewController(timelineID: page.timelineID, source: source, services: services)
                timeline.emptyMessage = page.emptyMessage
                timeline.waitsForActivation = true
                timeline.scrollObserver = self
                timeline.onAuthenticationFailure = { [weak self] in self?.services.onAuthenticationFailure?() }
                addChild(timeline)
                pager.addSubview(timeline.view)
                timeline.didMove(toParent: self)
                timelines.append(timeline)
            }
        }
        currentTimeline?.activate()
        updateScrollsToTop()

        statusBarBackdrop.backgroundColor = .hibari(.background)
        view.addSubview(header)
        view.addSubview(statusBarBackdrop)
        tabStrip.onSelect = { [weak self] index in
            guard let page = Page(rawValue: index) else { return }
            self?.select(page, animated: true)
        }
        bars.onChange = { [weak self] progress in self?.applyBars(progress) }
        NotificationCenter.default.addObserver(self, selector: #selector(bookmarkDidChange(_:)),
                                               name: BookmarkController.didChange, object: services.bookmarks)
        NotificationCenter.default.addObserver(self, selector: #selector(reactionDidChange(_:)),
                                               name: ReactionController.didChange, object: services.reactions)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        catchUpCurrentPage()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let safe = view.safeAreaInsets

        pager.frame = bounds
        pager.contentSize = CGSize(width: bounds.width * CGFloat(timelines.count), height: bounds.height)
        for (index, timeline) in timelines.enumerated() {
            timeline.view.frame = CGRect(x: bounds.width * CGFloat(index), y: 0, width: bounds.width, height: bounds.height)
            timeline.contentInsets = UIEdgeInsets(top: safe.top + header.height, left: 0,
                                                  bottom: safe.bottom, right: 0)
        }
        if !pager.isDragging && !pager.isDecelerating {
            pager.contentOffset.x = bounds.width * CGFloat(currentPage.rawValue)
        }

        statusBarBackdrop.frame = CGRect(x: 0, y: 0, width: bounds.width, height: safe.top)
        header.transform = .identity
        header.frame = CGRect(x: 0, y: safe.top, width: bounds.width, height: header.height)
        bars.distance = NavigationHeaderView.rowHeight
        applyBars(bars.progress)
    }

    private func applyBars(_ progress: CGFloat) {
        header.transform = CGAffineTransform(translationX: 0, y: -NavigationHeaderView.rowHeight * progress)
        header.rowView.alpha = 1 - progress
    }

    func select(_ page: Page, animated: Bool) {
        guard timelines.indices.contains(page.rawValue) else { return }
        timelines[page.rawValue].activate()
        if page == currentPage, animated {
            scrollToTop()
            return
        }
        pager.setContentOffset(CGPoint(x: pager.bounds.width * CGFloat(page.rawValue), y: 0), animated: animated)
        if !animated { pageDidSettle() }
    }

    func scrollToTop() {
        currentTimeline?.scrollToTop(animated: true)
        bars.show(animated: true)
    }

    private func pageDidSettle() {
        let index = Int((pager.contentOffset.x / max(1, pager.bounds.width)).rounded())
        guard let page = Page(rawValue: index), page != currentPage, timelines.indices.contains(index) else { return }
        timelines[index].activate()
        currentPage = page
        updateScrollsToTop()
        if let scrollView = currentTimeline?.collectionView {
            bars.reset(for: scrollView)
        }
        bars.show(animated: true)
        catchUpCurrentPage()
    }

    private func updateScrollsToTop() {
        for (index, timeline) in timelines.enumerated() {
            timeline.collectionView.scrollsToTop = index == currentPage.rawValue
        }
    }

    @objc private func bookmarkDidChange(_ notification: Notification) {
        guard let change = notification.userInfo?["change"] as? BookmarkChange else { return }
        membershipDidChange(on: .bookmarks, noteID: change.noteID, isIncluded: change.isBookmarked)
    }

    @objc private func reactionDidChange(_ notification: Notification) {
        guard let change = notification.userInfo?["change"] as? ReactionChange else { return }
        membershipDidChange(on: .likes, noteID: change.noteID, isIncluded: change.myReaction != nil)
    }

    private func membershipDidChange(on page: Page, noteID: String, isIncluded: Bool) {
        guard timelines.indices.contains(page.rawValue) else { return }
        let timeline = timelines[page.rawValue]
        if !isIncluded {
            timeline.remove(noteID: noteID)
            return
        }
        guard !timeline.contains(noteID: noteID) else { return }
        pagesBehind.insert(page)
        catchUpCurrentPage()
    }

    private func catchUpCurrentPage() {
        guard pagesBehind.contains(currentPage), navigationController?.topViewController === self,
              let timeline = currentTimeline
        else { return }
        pagesBehind.remove(currentPage)
        timeline.refresh()
    }
}

extension BookmarksViewController: BackSwipeGating {
    var allowsContentBackSwipe: Bool { pager.isAtFirstPage }
}

extension BookmarksViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === pager else { return }
        let progress = pager.contentOffset.x / max(1, pager.bounds.width)
        if pager.isTracking || pager.isDecelerating {
            for index in [Int(progress.rounded(.down)), Int(progress.rounded(.up))] where timelines.indices.contains(index) {
                timelines[index].activate()
            }
        }
        let previous = tabStrip.selectedIndex
        tabStrip.setProgress(progress)
        if tabStrip.selectedIndex != previous && pager.isTracking {
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

extension BookmarksViewController: TimelineScrollObserver {
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
