import UIKit

/// A user's followers and the users they follow, a page each.
final class FollowListViewController: UIViewController {
    let services: NoteServices
    private let user: User

    private let tabStrip = IconTabStripView(tabs: FollowList.allCases.map {
        IconTabStripView.Tab(title: $0.title, icon: UIImage(named: $0.icon)?.withRenderingMode(.alwaysTemplate))
    }, identifierPrefix: "follows.tab", showsTitles: true)
    private lazy var header = NavigationHeaderView(title: user.displayName, identifier: "follows", tabs: tabStrip,
                                                   tabsHeight: 39, separatesTabs: true)
    private let pager = BackSwipePager()
    private var lists: [UserListViewController?] = Array(repeating: nil, count: FollowList.allCases.count)
    private let pageFeedback = UISelectionFeedbackGenerator()
    private var emojiReloadPending = false

    private(set) var currentList: FollowList

    init(user: User, list: FollowList, services: NoteServices) {
        self.user = user
        self.services = services
        currentList = list
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .hibari(.background)
        view.accessibilityIdentifier = "follows"

        pager.isPagingEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.scrollsToTop = false
        pager.contentInsetAdjustmentBehavior = .never
        pager.delegate = self
        view.addSubview(pager)
        header.install(in: self)
        tabStrip.contentBottomInset = 6
        tabStrip.setProgress(CGFloat(currentList.rawValue))
        tabStrip.onSelect = { [weak self] index in
            guard let list = FollowList(rawValue: index) else { return }
            self?.select(list, animated: true)
        }
        configureTitle()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.configureTitle() }
        ensureList(currentList)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let safe = view.safeAreaInsets
        pager.frame = CGRect(x: 0, y: safe.top, width: bounds.width, height: max(0, bounds.height - safe.top))
        pager.contentSize = CGSize(width: bounds.width * CGFloat(lists.count), height: pager.bounds.height)
        if !pager.isDragging && !pager.isDecelerating {
            pager.contentOffset.x = bounds.width * CGFloat(currentList.rawValue)
        }
        for (index, list) in lists.enumerated() {
            guard let list else { continue }
            list.view.frame = CGRect(x: bounds.width * CGFloat(index), y: 0, width: bounds.width,
                                     height: pager.bounds.height)
            list.contentInsets = UIEdgeInsets(top: 0, left: 0, bottom: safe.bottom, right: 0)
        }
    }

    private func configureTitle() {
        let palette = Palette.palette(for: ThemeStyle(traitCollection.userInterfaceStyle))
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        let text = UIKitRichText(resolver: services.engine.emojiResolver, imagePipeline: services.imagePipeline,
                                 palette: palette, scale: scale, linkURL: { _ in nil })
        let title = text.build(user.displayName, emojis: .name(of: user), font: Typography.system(17, bold: true),
                               color: .primaryText, simple: true)
        header.setTitle(title.text)
        guard !title.missingEmojis.isEmpty, !emojiReloadPending else { return }
        emojiReloadPending = true
        let group = DispatchGroup()
        for request in title.missingEmojis {
            group.enter()
            services.imagePipeline.load(request) { _ in group.leave() }
        }
        group.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.emojiReloadPending = false
                if title.missingEmojis.contains(where: { self.services.imagePipeline.cachedImage(for: $0) != nil }) {
                    self.configureTitle()
                }
            }
        }
    }

    private func ensureList(_ list: FollowList) {
        guard lists[list.rawValue] == nil, let client = services.client else { return }
        let controller = UserListViewController(
            source: FollowListSource(client: client, userID: user.id, list: list), services: services)
        controller.showsRelations = true
        controller.emptyMessage = switch list {
        case .followers: "フォロワーはまだいません"
        case .following: "まだ誰もフォローしていません"
        }
        addChild(controller)
        pager.addSubview(controller.view)
        controller.didMove(toParent: self)
        lists[list.rawValue] = controller
        updateScrollsToTop()
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    func select(_ list: FollowList, animated: Bool) {
        if list == currentList, animated {
            scrollToTop()
            return
        }
        ensureList(list)
        pager.setContentOffset(CGPoint(x: pager.bounds.width * CGFloat(list.rawValue), y: 0), animated: animated)
        if !animated { pageDidSettle() }
    }

    func scrollToTop() {
        lists[currentList.rawValue]?.scrollToTop(animated: true)
    }

    private func pageDidSettle() {
        let index = Int((pager.contentOffset.x / max(1, pager.bounds.width)).rounded())
        guard let list = FollowList(rawValue: index), list != currentList else { return }
        currentList = list
        updateScrollsToTop()
    }

    private func updateScrollsToTop() {
        for (index, list) in lists.enumerated() {
            list?.scrollView.scrollsToTop = index == currentList.rawValue
        }
    }
}

extension FollowList {
    /// The tab's icon (an asset).
    var icon: String {
        switch self {
        case .followers: "Followers"
        case .following: "Following"
        }
    }
}

extension FollowListViewController: BackSwipeGating {
    var allowsContentBackSwipe: Bool { pager.isAtFirstPage }
}

extension FollowListViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === pager, pager.bounds.width > 0 else { return }
        let progress = pager.contentOffset.x / pager.bounds.width
        if pager.isTracking || pager.isDecelerating {
            for index in [Int(progress.rounded(.down)), Int(progress.rounded(.up))] {
                if let list = FollowList(rawValue: index) { ensureList(list) }
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
