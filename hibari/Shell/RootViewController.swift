import UIKit

final class RootViewController: UIViewController {
    enum Tab: Int {
        case home = 0
        case search = 1
        case notifications = 2
        case profile = 3
    }

    let session: TimelineSession
    let services: NoteServices
    let home: TimelinePagerViewController
    /// The header's avatar was tapped: open the side drawer. Setting it also lets a
    /// rightward swipe on the first timeline open it (`allowsOpeningSideDrawer`).
    var onOpenDrawer: (() -> Void)? {
        didSet {
            home.onAccountButton = onOpenDrawer
            search?.onAccountButton = onOpenDrawer
            notifications?.onAccountButton = onOpenDrawer
        }
    }
    /// Home was long-pressed: the account list.
    var onShowAccounts: (() -> Void)? {
        didSet { bottomBar.onLongPressHome = onShowAccounts }
    }
    /// The server rejected the account's token.
    var onAuthenticationFailure: (() -> Void)? {
        didSet {
            home.onAuthenticationFailure = onAuthenticationFailure
            notifications?.onAuthenticationFailure = onAuthenticationFailure
            services.onAuthenticationFailure = onAuthenticationFailure
        }
    }

    private let unread: UnreadNotifications?
    private let homeStack: UINavigationController
    private var searchStack: UINavigationController?
    private var search: SearchViewController?
    private var notificationsStack: UINavigationController?
    private var notifications: TimelinePagerViewController?
    private var profileStack: UINavigationController?
    private var profile: ProfileViewController?
    private(set) var selectedTab = Tab.home
    private let bottomBar = BottomBarView()
    private var drawerProgress: CGFloat = 0
    private var hud: PerfHUD?
    #if PERF
    private var benchmark: Benchmark?
    #endif

    /// `unread`: the badges' counts (nil for the fixtures of perf builds).
    init(session: TimelineSession, unread: UnreadNotifications? = nil) {
        self.session = session
        self.unread = unread
        services = NoteServices(session: session)
        home = TimelinePagerViewController(session: session, services: services, pages: session.timelines,
                                           showsPostedNotes: true, savesTimelines: true)
        homeStack = ScreenStackController(rootViewController: home)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var selectedStack: UINavigationController {
        switch selectedTab {
        case .search: searchStack ?? homeStack
        case .notifications: notificationsStack ?? homeStack
        case .profile: profileStack ?? homeStack
        case .home: homeStack
        }
    }

    private var selectedPager: TimelinePagerViewController? {
        switch selectedTab {
        case .search, .profile: nil
        case .notifications: notifications ?? home
        case .home: home
        }
    }

    private var selectedBarsProgress: CGFloat { selectedPager?.barsProgress ?? 0 }

    override var childForStatusBarStyle: UIViewController? { selectedStack.topViewController }

    var timelines: [TimelineViewController] { home.timelines }
    var currentTimeline: TimelineViewController? { home.currentTimeline }

    func select(_ index: Int, animated: Bool) {
        home.select(index, animated: animated)
    }

    func saveTimelines() {
        home.saveTimelines()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .hibari(.background)

        install(homeStack)
        view.addSubview(bottomBar)

        bottomBar.onSelect = { [weak self] index in self?.tabTapped(index) }
        home.onBarsChange = { [weak self] progress in self?.barsDidChange(progress, in: .home) }
        services.bookmarks.loadRecent()
        if let unread {
            NotificationCenter.default.addObserver(self, selector: #selector(unreadDidChange),
                                                   name: UnreadNotifications.didChange, object: unread)
        }
        updateBadges()

        #if PERF
        let showsHUD = AppSettings.showsPerfHUD || AppSettings.benchmarkMode != nil
        if let mode = AppSettings.benchmarkMode {
            benchmark = Benchmark(mode: mode, root: self)
        }
        #else
        let showsHUD = AppSettings.showsPerfHUD
        #endif
        if showsHUD {
            let hud = PerfHUD()
            view.addSubview(hud)
            hud.start()
            self.hud = hud
        }
    }

    private func install(_ stack: UINavigationController) {
        addChild(stack)
        view.insertSubview(stack.view, at: 0)
        stack.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if PERF
        benchmark?.startIfNeeded()
        #endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let safe = view.safeAreaInsets
        for stack in [homeStack, searchStack, notificationsStack, profileStack].compactMap({ $0 }) {
            stack.view.frame = bounds
            stack.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: BottomBarView.barHeight, right: 0)
        }
        bottomBar.transform = .identity
        bottomBar.frame = CGRect(x: 0, y: bounds.height - safe.bottom - BottomBarView.barHeight,
                                 width: bounds.width, height: BottomBarView.barHeight + safe.bottom)
        hud?.frame = CGRect(x: bounds.width - 180 - 8, y: safe.top + 4, width: 180, height: 64)
        applyBottomBar(selectedBarsProgress)
    }

    private func barsDidChange(_ progress: CGFloat, in tab: Tab) {
        guard tab == selectedTab else { return }
        applyBottomBar(progress)
    }

    private func applyBottomBar(_ progress: CGFloat) {
        bottomBar.transform = CGAffineTransform(translationX: 0, y: bottomBar.bounds.height * progress)
        bottomBar.alpha = 1 - progress * 0.6
    }

    private func tabTapped(_ index: Int) {
        guard let tab = Tab(rawValue: index) else { return }
        if tab == selectedTab {
            reselect()
        } else {
            show(tab)
        }
    }

    /// Shows the tab's stack (as it was left). The notifications are loaded the first
    /// time; after that, showing them again fetches what came meanwhile.
    func show(_ tab: Tab) {
        guard tab != selectedTab else { return }
        if tab == .search, searchStack == nil {
            guard services.client != nil else {
                services.notAvailableYet("検索")
                return
            }
            makeSearch()
        } else if tab == .notifications, notificationsStack == nil {
            guard !session.notificationTimelines.isEmpty else {
                services.notAvailableYet("通知")
                return
            }
            makeNotifications()
        } else if tab == .notifications {
            refreshNotifications()
        } else if tab == .profile, profileStack == nil {
            guard services.client != nil else {
                services.notAvailableYet("プロフィール")
                return
            }
            makeProfile()
        }
        selectedTab = tab
        bottomBar.select(tab.rawValue)
        homeStack.view.isHidden = tab != .home
        searchStack?.view.isHidden = tab != .search
        notificationsStack?.view.isHidden = tab != .notifications
        profileStack?.view.isHidden = tab != .profile
        setNeedsStatusBarAppearanceUpdate()
        applyBottomBar(selectedBarsProgress)
        updateBadges()
    }

    private func makeSearch() {
        let search = SearchViewController(services: services)
        search.onAccountButton = onOpenDrawer
        search.loadViewIfNeeded()
        search.setDrawerProgress(drawerProgress)
        let stack = ScreenStackController(rootViewController: search)
        self.search = search
        searchStack = stack
        install(stack)
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    private func makeNotifications() {
        let pager = TimelinePagerViewController(session: session, services: services,
                                                pages: session.notificationTimelines, title: "通知")
        pager.onAccountButton = onOpenDrawer
        pager.onAuthenticationFailure = onAuthenticationFailure
        pager.onBarsChange = { [weak self] progress in self?.barsDidChange(progress, in: .notifications) }
        pager.setDrawerProgress(drawerProgress)
        let stack = ScreenStackController(rootViewController: pager)
        notifications = pager
        notificationsStack = stack
        install(stack)
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    /// The account, as a user.
    private var accountUser: User {
        let account = session.account
        return User(id: account.userID, name: account.name, username: account.username, host: nil,
                    avatarUrl: account.avatarUrl)
    }

    private func makeProfile() {
        let profile = ProfileViewController(subject: .user(accountUser), services: services)
        let stack = ScreenStackController(rootViewController: profile)
        self.profile = profile
        profileStack = stack
        install(stack)
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    private func refreshNotifications() {
        guard let list = notifications?.timelines.first, list.isLoaded, list.isAtTop else { return }
        list.refresh()
    }

    private func reselect() {
        let stack = selectedStack
        if stack.viewControllers.count > 1 {
            stack.popToRootViewController(animated: true)
        } else if selectedTab == .search {
            search?.focusSearchField()
        } else if selectedTab == .profile {
            profile?.scrollToTop()
        } else if selectedTab == .home {
            home.refreshOrScrollToTop()
        } else {
            selectedPager?.scrollToTop()
            if selectedTab == .notifications { refreshNotifications() }
        }
    }

    @objc private func unreadDidChange() {
        updateBadges()
        if selectedTab == .notifications, unread?.hasUnread(session.account) == true {
            refreshNotifications()
        }
    }

    private func updateBadges() {
        guard let unread else { return }
        let count = selectedTab == .notifications ? 0 : unread.count(for: session.account)
        bottomBar.setBadge(count > 0 ? .count(count) : nil, at: Tab.notifications.rawValue)
        bottomBar.setBadge(unread.othersHaveUnread ? .dot : nil, at: Tab.home.rawValue)
    }

    func update(_ account: Account) {
        home.update(account)
        search?.update(account)
        notifications?.update(account)
    }

    /// The profile tab, back at its root (the side drawer closes over it).
    func showAccountProfile() {
        show(.profile)
        guard selectedTab == .profile else { return }
        profileStack?.popToRootViewController(animated: false)
    }

    /// The account's bookmarks (and the notes it reacted to), on top of the tab's root
    /// (without the push animation, like the profile).
    func showBookmarks() {
        let stack = selectedStack
        stack.popToRootViewController(animated: false)
        stack.pushViewController(BookmarksViewController(services: services), animated: false)
    }

    /// The account's followers or followees, on top of the tab's root (without the push
    /// animation, like the profile).
    func showFollows(_ list: FollowList) {
        let stack = selectedStack
        stack.popToRootViewController(animated: false)
        services.openFollows(of: accountUser, list: list, from: stack.topViewController ?? stack, animated: false)
    }

    /// The settings, on top of the tab's root (without the push animation, like the
    /// profile).
    func showSettings() {
        let stack = selectedStack
        stack.popToRootViewController(animated: false)
        stack.pushViewController(SettingsViewController(account: session.account), animated: false)
    }
}

extension RootViewController: SideDrawerContent {
    /// From the tab's first timeline only, like X: elsewhere a rightward swipe pages the
    /// timelines or goes back.
    var allowsOpeningSideDrawer: Bool {
        let stack = selectedStack
        return onOpenDrawer != nil && stack.viewControllers.count == 1 && stack.transitionCoordinator == nil
            && presentedViewController == nil && selectedPager?.isAtFirstTimeline ?? true
    }

    func sideDrawerDidMove(_ progress: CGFloat) {
        drawerProgress = progress
        home.setDrawerProgress(progress)
        search?.setDrawerProgress(progress)
        notifications?.setDrawerProgress(progress)
    }
}
