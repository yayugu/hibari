import UIKit

final class RootViewController: UIViewController {
    enum Tab: Int {
        case home = 0
        case search = 1
        case notifications = 2
        case profile = 3
    }

    /// Where the tabs are: the bar along the bottom (iPhone), or the side rail at the
    /// window's left or right edge. `inBarColumn`: in the column the system keeps for its
    /// bars at the side (iPhone Duo), which also has the back button.
    private enum Chrome: Equatable {
        case bottomBar
        case rail(UIRectEdge, inBarColumn: Bool)

        var hasBackButtonInRail: Bool {
            if case .rail(_, inBarColumn: true) = self { true } else { false }
        }
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
    /// Home (or the side rail's avatar) was long-pressed: the account list.
    var onShowAccounts: (() -> Void)? {
        didSet {
            bottomBar.onLongPressHome = onShowAccounts
            rail.onShowAccounts = onShowAccounts
        }
    }
    /// Tapped "ログアウト" in the settings.
    var onSignOut: (() -> Void)?
    /// The server rejected the account's token.
    var onAuthenticationFailure: (() -> Void)? {
        didSet {
            home.onAuthenticationFailure = onAuthenticationFailure
            notifications?.onAuthenticationFailure = onAuthenticationFailure
            services.onAuthenticationFailure = onAuthenticationFailure
        }
    }

    private let unread: UnreadNotifications?
    private let homeStack: ScreenStackController
    private var searchStack: ScreenStackController?
    private var search: SearchViewController?
    private var notificationsStack: ScreenStackController?
    private var notifications: TimelinePagerViewController?
    private var profileStack: ScreenStackController?
    private var profile: ProfileViewController?
    private(set) var selectedTab = Tab.home
    private let bottomBar = BottomBarView()
    private let rail = NavigationRailView()
    private var chrome = Chrome.bottomBar
    /// Under the status bar beside the side rail: it goes over both, so it reads against
    /// the background (as on X for iPad) rather than what the screen shows there.
    private let statusBarBackdrop = UIView()
    /// Where toasts go: the tabs' content, above the tab bar or beside the side rail.
    private let toastArea = UIView()
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

    private var stacks: [ScreenStackController] {
        [homeStack, searchStack, notificationsStack, profileStack].compactMap { $0 }
    }

    private var selectedStack: ScreenStackController {
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

    override var childForStatusBarStyle: UIViewController? {
        chrome == .bottomBar ? selectedStack.topViewController : nil
    }

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
        statusBarBackdrop.backgroundColor = .hibari(.background)
        statusBarBackdrop.isUserInteractionEnabled = false
        statusBarBackdrop.isHidden = true
        view.addSubview(statusBarBackdrop)
        view.addSubview(bottomBar)
        rail.isHidden = true
        view.addSubview(rail)
        toastArea.isHidden = true
        view.addSubview(toastArea)
        Toast.area = toastArea

        bottomBar.onSelect = { [weak self] index in
            guard let tab = Tab(rawValue: index) else { return }
            self?.tabTapped(tab)
        }
        rail.onSelect = { [weak self] tab in self?.tabTapped(tab) }
        rail.onShowBookmarks = { [weak self] in self?.showBookmarks() }
        rail.onShowSettings = { [weak self] in self?.showSettings() }
        rail.onBack = { [weak self] in self?.selectedStack.popViewController(animated: true) }
        rail.composeButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.services.compose(from: self)
        }, for: .touchUpInside)
        rail.setAccount(session.account)
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

    private func install(_ stack: ScreenStackController) {
        stack.onScreensChange = { [weak self, weak stack] in
            guard let self, stack === self.selectedStack else { return }
            self.updateRailBack()
        }
        stack.traitOverrides.hasBackButtonInRail = chrome.hasBackButtonInRail
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
        let chrome = preferredChrome()
        if chrome != self.chrome { apply(chrome) }

        var content = bounds
        let bottomInset: CGFloat
        switch chrome {
        case .bottomBar:
            bottomInset = BottomBarView.barHeight
            bottomBar.transform = .identity
            bottomBar.frame = CGRect(x: 0, y: bounds.height - safe.bottom - BottomBarView.barHeight,
                                     width: bounds.width, height: BottomBarView.barHeight + safe.bottom)
        case .rail(let edge, let inBarColumn):
            // In the system's column where it has one (iPhone Duo: the status bar's, which
            // is the safe area's inset there), and the content beside it.
            bottomInset = 0
            let width = max(NavigationRailView.minimumWidth, edge == .left ? safe.left : safe.right)
            (rail.frame, content) = bounds.divided(atDistance: width, from: edge == .left ? .minXEdge : .maxXEdge)
            rail.edge = edge
            rail.isInBarColumn = inBarColumn
        }
        statusBarBackdrop.frame = CGRect(x: content.minX, y: 0, width: content.width, height: safe.top)
        for stack in stacks {
            stack.view.frame = content
            stack.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        }
        var contentSafe = safe
        contentSafe.bottom += bottomInset
        if case .rail(let edge, _) = chrome {
            if edge == .left { contentSafe.left = 0 } else { contentSafe.right = 0 }
        }
        toastArea.frame = content.inset(by: contentSafe)
        hud?.frame = CGRect(x: content.maxX - 180 - 8, y: safe.top + 4, width: 180, height: 64)
        applyBottomBar(selectedBarsProgress)
    }

    /// The tabs along the bottom, or at a side of the window: where the system puts its
    /// bars in a column (iPhone Duo; on the hardware's side, beside the camera), or where
    /// the window is wide (iPad, iPhone Duo open in portrait), on the leading side like X.
    private func preferredChrome() -> Chrome {
        let traits = traitCollection
        let leading: UIRectEdge = traits.layoutDirection == .rightToLeft ? .right : .left
        let trailing: UIRectEdge = leading == .left ? .right : .left
        if #available(iOS 27.1, *) {
            switch traits.verticalBarEdge {
            case .leading: return .rail(leading, inBarColumn: true)
            case .trailing: return .rail(trailing, inBarColumn: true)
            default: break
            }
        }
        return traits.horizontalSizeClass == .regular ? .rail(leading, inBarColumn: false) : .bottomBar
    }

    private func apply(_ chrome: Chrome) {
        self.chrome = chrome
        let usesRail = chrome != .bottomBar
        bottomBar.isHidden = usesRail
        rail.isHidden = !usesRail
        statusBarBackdrop.isHidden = !usesRail
        home.setUsesRail(usesRail)
        search?.setUsesRail(usesRail)
        notifications?.setUsesRail(usesRail)
        for stack in stacks {
            stack.traitOverrides.hasBackButtonInRail = chrome.hasBackButtonInRail
        }
        updateRailBack()
        setNeedsStatusBarAppearanceUpdate()
        // The rail has what the drawer had.
        if usesRail { (parent as? SideDrawerController)?.close(animated: false) }
    }

    /// The rail's back button, for the shown tab's screens (iPhone Duo).
    private func updateRailBack() {
        rail.setShowsBack(chrome.hasBackButtonInRail && selectedStack.viewControllers.count > 1)
    }

    private func barsDidChange(_ progress: CGFloat, in tab: Tab) {
        guard tab == selectedTab else { return }
        applyBottomBar(progress)
    }

    private func applyBottomBar(_ progress: CGFloat) {
        guard chrome == .bottomBar else { return }
        bottomBar.transform = CGAffineTransform(translationX: 0, y: bottomBar.bounds.height * progress)
        bottomBar.alpha = 1 - progress * 0.6
    }

    private func tabTapped(_ tab: Tab) {
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
        rail.select(tab)
        homeStack.view.isHidden = tab != .home
        searchStack?.view.isHidden = tab != .search
        notificationsStack?.view.isHidden = tab != .notifications
        profileStack?.view.isHidden = tab != .profile
        setNeedsStatusBarAppearanceUpdate()
        applyBottomBar(selectedBarsProgress)
        updateRailBack()
        updateBadges()
    }

    private func makeSearch() {
        let search = SearchViewController(services: services)
        search.onAccountButton = onOpenDrawer
        search.setUsesRail(chrome != .bottomBar)
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
        pager.setUsesRail(chrome != .bottomBar)
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
        } else {
            selectedPager?.refreshOrScrollToTop()
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
        let notificationsBadge: TabBadge.Value? = count > 0 ? .count(count) : nil
        let homeBadge: TabBadge.Value? = unread.othersHaveUnread ? .dot : nil
        bottomBar.setBadge(notificationsBadge, at: Tab.notifications.rawValue)
        bottomBar.setBadge(homeBadge, at: Tab.home.rawValue)
        rail.setBadge(notificationsBadge, on: .notifications)
        rail.setBadge(homeBadge, on: .home)
    }

    func update(_ account: Account) {
        if account.id == session.account.id { rail.setAccount(account) }
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
        let settings = SettingsViewController(account: session.account) { [weak self] in self?.onSignOut?() }
        stack.pushViewController(settings, animated: false)
    }
}

extension RootViewController: SideDrawerContent {
    /// From the tab's first timeline only, like X: elsewhere a rightward swipe pages the
    /// timelines or goes back.
    var allowsOpeningSideDrawer: Bool {
        let stack = selectedStack
        return onOpenDrawer != nil && chrome == .bottomBar && stack.viewControllers.count == 1 && stack.transitionCoordinator == nil
            && presentedViewController == nil && selectedPager?.isAtFirstTimeline ?? true
    }

    func sideDrawerDidMove(_ progress: CGFloat) {
        drawerProgress = progress
        home.setDrawerProgress(progress)
        search?.setDrawerProgress(progress)
        notifications?.setDrawerProgress(progress)
    }
}
