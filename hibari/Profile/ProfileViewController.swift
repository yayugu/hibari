import UIKit

enum ProfileSubject {
    /// A user at hand (from a note): shown at once, then filled in by `users/show`.
    case user(User)
    /// A mention: looked up by name first. `host` nil is a user of the account's server.
    case name(username: String, host: String?)
}

final class ProfileViewController: UIViewController {
    let services: NoteServices
    private let subject: ProfileSubject
    private var user: User?
    private var profile: UserDetailed?
    private var loadError: String?
    private var isLoadingProfile = false

    private let pager = BackSwipePager()
    private var timelines: [TimelineViewController?] = Array(repeating: nil, count: ProfileTab.allCases.count)
    private let header: ProfileHeaderView
    private let avatar: ProfileAvatarView
    private let banner = ProfileBannerView()
    private let topBar = ProfileTopBar()
    private let tabs = UIView()
    private let tabStrip = TabStripView(titles: ProfileTab.allCases.map(\.title), identifierPrefix: "profile.tab")
    private let tabsHairline = UIView()
    private let pageFeedback = UISelectionFeedbackGenerator()
    private let refreshFeedback = UIImpactFeedbackGenerator(style: .medium)

    private(set) var currentIndex = 0
    private var geometry = Geometry()
    private var isRefreshing = false
    /// This drag can still start a refresh, as in `PullToRefresh`.
    private var refreshArmed = false

    private static let refreshDistance = PullToRefresh.triggerDistance

    private struct Geometry {
        var width: CGFloat = 0
        var collapsedHeight: CGFloat = 0
        var bannerHeight: CGFloat = 0
        var contentHeight: CGFloat = 0

        var headerHeight: CGFloat { contentHeight + ProfileMetrics.tabsHeight }
        var collapseDistance: CGFloat { bannerHeight - collapsedHeight }
        var stickDistance: CGFloat { contentHeight - collapsedHeight }
    }

    init(subject: ProfileSubject, services: NoteServices) {
        self.subject = subject
        self.services = services
        header = ProfileHeaderView(services: services)
        avatar = ProfileAvatarView(imagePipeline: services.imagePipeline)
        if case .user(let user) = subject { self.user = user }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var isAccount: Bool { user.map(services.isAccount) ?? false }

    var currentTimeline: TimelineViewController? {
        timelines.indices.contains(currentIndex) ? timelines[currentIndex] : nil
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    func shows(_ subject: ProfileSubject) -> Bool {
        let known = profile?.user ?? user
        switch subject {
        case .user(let other):
            return known?.id == other.id
        case .name(let username, let host):
            if let known {
                return known.username.lowercased() == username.lowercased() && known.host == host
            }
            if case .name(let ownName, let ownHost) = self.subject {
                return ownName.lowercased() == username.lowercased() && ownHost == host
            }
            return false
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .hibari(.background)
        view.accessibilityIdentifier = "profile"

        pager.isPagingEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.scrollsToTop = false
        pager.contentInsetAdjustmentBehavior = .never
        pager.delegate = self
        view.addSubview(pager)

        view.addSubview(header)
        tabs.backgroundColor = .hibari(.background)
        tabs.addSubview(tabStrip)
        tabsHairline.backgroundColor = .hibari(.separator)
        tabs.addSubview(tabsHairline)
        view.addSubview(tabs)
        banner.isUserInteractionEnabled = false
        view.addSubview(banner)
        avatar.isUserInteractionEnabled = false
        view.addSubview(avatar)
        view.addSubview(topBar)

        header.onContentChange = { [weak self] in self?.relayoutHeader() }
        header.followButton.addAction(UIAction { [weak self] _ in self?.followTapped() }, for: .touchUpInside)
        header.counts.onSelect = { [weak self] list in self?.openFollows(list) }
        topBar.searchButton.addAction(UIAction { [weak self] _ in self?.searchNotes() }, for: .touchUpInside)
        topBar.moreButton.showsMenuAsPrimaryAction = true
        topBar.moreButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.menuElements() ?? [])
        }])
        topBar.followButton.addAction(UIAction { [weak self] _ in self?.followTapped() }, for: .touchUpInside)
        topBar.onLayoutChange = { [weak self] in self?.layoutTitle() }
        tabStrip.onSelect = { [weak self] index in self?.select(index, animated: true) }

        let headerTap = UITapGestureRecognizer(target: self, action: #selector(headerTapped(_:)))
        headerTap.cancelsTouchesInView = false
        headerTap.delegate = self
        view.addGestureRecognizer(headerTap)

        NotificationCenter.default.addObserver(self, selector: #selector(relationDidChange(_:)),
                                               name: NoteServices.didChangeRelation, object: services)
        configureContent()
        loadProfile()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsStatusBarAppearanceUpdate()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let shell = navigationController?.parent
        if let coordinator = transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { _ in shell?.setNeedsStatusBarAppearanceUpdate() }
        } else {
            shell?.setNeedsStatusBarAppearanceUpdate()
        }
    }

    private var statusBarHeight: CGFloat { view.safeAreaInsets.top }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        topBar.showsBackButton = navigationController?.viewControllers.first !== self
        let bounds = view.bounds
        let top = statusBarHeight
        geometry.width = bounds.width
        geometry.collapsedHeight = top + ProfileMetrics.barRowHeight
        geometry.bannerHeight = ProfileMetrics.bannerHeight(width: bounds.width,
                                                            collapsedHeight: geometry.collapsedHeight)

        pager.frame = bounds
        pager.contentSize = CGSize(width: bounds.width * CGFloat(timelines.count), height: bounds.height)
        if !pager.isDragging && !pager.isDecelerating {
            pager.contentOffset.x = bounds.width * CGFloat(currentIndex)
        }
        topBar.topInset = top
        topBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: geometry.collapsedHeight)
        tabs.bounds.size = CGSize(width: bounds.width, height: ProfileMetrics.tabsHeight)
        tabStrip.frame = tabs.bounds
        let scale = view.window?.screen.scale ?? traitCollection.displayScale
        tabsHairline.frame = CGRect(x: 0, y: ProfileMetrics.tabsHeight - 1 / scale, width: bounds.width, height: 1 / scale)
        avatar.bounds.size = CGSize(width: ProfileMetrics.avatarSize, height: ProfileMetrics.avatarSize)
        avatar.layer.anchorPoint = CGPoint(x: 0.5, y: 1)

        relayoutHeader()
        for (index, timeline) in timelines.enumerated() {
            guard let timeline else { continue }
            timeline.view.frame = CGRect(x: bounds.width * CGFloat(index), y: 0, width: bounds.width, height: bounds.height)
        }
        ensureTimeline(at: currentIndex)
        configureBanner()
        applyScroll()
    }

    private func relayoutHeader() {
        guard geometry.width > 0 else { return }
        let height = header.layout(width: geometry.width, bannerHeight: geometry.bannerHeight)
        header.bounds.size = CGSize(width: geometry.width, height: height)
        geometry.contentHeight = height
        for timeline in timelines.compactMap({ $0 }) {
            applyInsets(to: timeline)
        }
        layoutTitle()
        applyScroll()
    }

    private func applyInsets(to timeline: TimelineViewController) {
        let safe = view.safeAreaInsets
        let collectionView = timeline.collectionView
        let oldTop = collectionView.contentInset.top
        let scrolled = collectionView.contentOffset.y + oldTop
        let top = geometry.headerHeight
        let pinned = geometry.collapsedHeight + ProfileMetrics.tabsHeight
        timeline.contentInsets = UIEdgeInsets(top: top, left: 0, bottom: safe.bottom, right: 0)
        timeline.indicatorInsets = UIEdgeInsets(top: pinned, left: 0, bottom: safe.bottom, right: 0)
        timeline.minimumContentHeight = max(0, view.bounds.height - safe.bottom - pinned)
        guard top != oldTop else { return }
        if scrolled <= 0 || oldTop == 0 {
            collectionView.contentOffset.y = min(0, scrolled) - top
        }
    }

    private var scrolled: CGFloat {
        guard let collectionView = currentTimeline?.collectionView else { return 0 }
        return collectionView.contentOffset.y + collectionView.contentInset.top
    }

    private func applyScroll() {
        guard geometry.width > 0 else { return }
        let s = scrolled
        let g = geometry
        let width = g.width

        let bannerHeight = max(g.collapsedHeight, g.bannerHeight - s)
        banner.frame = CGRect(x: 0, y: 0, width: width, height: bannerHeight)
        let imageFrame = s >= 0
            ? CGRect(x: 0, y: -min(s, g.collapseDistance), width: width, height: g.bannerHeight)
            : CGRect(x: 0, y: 0, width: width, height: g.bannerHeight - s)
        banner.layout(imageFrame: imageFrame, scrimHeight: statusBarHeight, barHeight: g.collapsedHeight)

        header.frame.origin = CGPoint(x: 0, y: -s)
        tabs.frame.origin = CGPoint(x: 0, y: max(g.contentHeight - s, g.collapsedHeight))

        let progress = min(1, max(0, s / max(1, g.collapseDistance)))
        let avatarScale = 1 - (1 - ProfileMetrics.avatarMinScale) * progress
        avatar.transform = CGAffineTransform(scaleX: avatarScale, y: avatarScale)
        avatar.center = CGPoint(x: ProfileMetrics.padding + ProfileMetrics.avatarSize / 2,
                                y: g.bannerHeight - ProfileMetrics.avatarOverlap + ProfileMetrics.avatarSize - s)
        let inFront = s < g.collapseDistance
        if inFront != isAvatarInFront {
            if inFront {
                view.insertSubview(avatar, aboveSubview: banner)
            } else {
                view.insertSubview(avatar, belowSubview: banner)
            }
        }

        let nameBottom = header.nameFrame.maxY - s
        let travel = g.collapsedHeight - topBar.rowMidY + banner.titleView.bounds.height / 2
        let under = g.collapsedHeight - nameBottom
        banner.titleView.transform = CGAffineTransform(translationX: 0, y: travel - min(max(under, 0), travel))

        let blurEnd = header.nameFrame.maxY - g.collapsedHeight
        let blur = s < 0
            ? min(1, -s / Self.refreshDistance)
            : min(1, max(0, (s - g.collapseDistance) / max(1, blurEnd - g.collapseDistance)))
        banner.setBlur(blur)

        if refreshArmed {
            banner.spinner.alpha = s < 0 ? min(1, -s / Self.refreshDistance) : 0
        }
        banner.spinner.center = CGPoint(x: width / 2, y: topBar.rowMidY)

        let followBottom = header.followButton.isHidden ? CGFloat.infinity : header.followButton.frame.maxY - s
        topBar.setShowsFollow(followBottom <= g.collapsedHeight, animated: view.window != nil)
    }

    private func layoutTitle() {
        let height = banner.titleView.fittingHeight
        let x = topBar.showsBackButton ? topBar.backButton.frame.maxX + 16 : ProfileMetrics.padding
        let transform = banner.titleView.transform
        banner.titleView.transform = .identity
        banner.titleView.frame = CGRect(x: x, y: (topBar.rowMidY - height / 2).rounded(),
                                        width: max(0, topBar.trailingButtonsMinX - 12 - x), height: height)
        banner.titleView.transform = transform
        banner.titleView.layoutIfNeeded()
    }

    private func alignOtherTimelines() {
        let s = max(0, scrolled)
        let stick = geometry.stickDistance
        for (index, timeline) in timelines.enumerated() where index != currentIndex {
            guard let collectionView = timeline?.collectionView else { continue }
            let own = collectionView.contentOffset.y + collectionView.contentInset.top
            let target = s < stick ? s : max(own, stick)
            if abs(target - own) > 0.5 {
                collectionView.setContentOffset(CGPoint(x: 0, y: target - collectionView.contentInset.top), animated: false)
            }
        }
    }

    func scrollToTop() {
        currentTimeline?.scrollToTop(animated: true)
    }

    private func pullDidChange(_ scrollView: UIScrollView) {
        guard refreshArmed, scrollView.isDragging, scrolled <= -Self.refreshDistance else { return }
        refresh()
    }

    private func refresh() {
        isRefreshing = true
        refreshArmed = false
        refreshFeedback.impactOccurred()
        banner.spinner.alpha = 1
        banner.spinner.startAnimating()
        var pending = 2
        let done = { [weak self] in
            pending -= 1
            guard pending == 0, let self else { return }
            self.isRefreshing = false
            UIView.animate(withDuration: 0.25) {
                self.banner.spinner.alpha = 0
            } completion: { _ in
                if !self.isRefreshing { self.banner.spinner.stopAnimating() }
                self.applyScroll()
            }
        }
        loadProfile(completion: done)
        if let timeline = currentTimeline {
            timeline.refresh(completion: done)
        } else {
            done()
        }
    }

    private func ensureTimeline(at index: Int) {
        guard timelines.indices.contains(index), timelines[index] == nil, geometry.width > 0,
              let client = services.client, let userID = user?.id
        else { return }
        let tab = ProfileTab.allCases[index]
        let timeline = TimelineViewController(timelineID: "profile.\(tab.id)",
                                              source: UserNotesSource(client: client, userID: userID, tab: tab),
                                              services: services)
        timeline.allowsPullToRefresh = false
        timeline.profileUserID = userID
        timeline.scrollObserver = self
        timeline.onAuthenticationFailure = services.onAuthenticationFailure
        addChild(timeline)
        pager.addSubview(timeline.view)
        timeline.didMove(toParent: self)
        timelines[index] = timeline
        let bounds = view.bounds
        timeline.view.frame = CGRect(x: bounds.width * CGFloat(index), y: 0, width: bounds.width, height: bounds.height)
        timeline.view.layoutIfNeeded()
        applyInsets(to: timeline)
        timeline.collectionView.scrollsToTop = index == currentIndex
        if index != currentIndex {
            let target = min(max(0, scrolled), geometry.stickDistance)
            timeline.collectionView.contentOffset.y = target - geometry.headerHeight
        }
    }

    func select(_ index: Int, animated: Bool) {
        guard timelines.indices.contains(index) else { return }
        if index == currentIndex {
            if animated { scrollToTop() }
            return
        }
        alignOtherTimelines()
        ensureTimeline(at: index)
        pager.setContentOffset(CGPoint(x: pager.bounds.width * CGFloat(index), y: 0), animated: animated)
        if !animated { pageDidSettle() }
    }

    private func pageDidSettle() {
        let width = max(1, pager.bounds.width)
        let index = Int((pager.contentOffset.x / width).rounded())
        guard index != currentIndex, timelines.indices.contains(index) else { return }
        currentIndex = index
        for (index, timeline) in timelines.enumerated() {
            timeline?.collectionView.scrollsToTop = index == currentIndex
        }
        applyScroll()
    }

    private func loadProfile(completion: (() -> Void)? = nil) {
        guard let client = services.client else {
            completion?()
            return
        }
        isLoadingProfile = true
        let subject = self.subject
        let userID = user?.id
        Task { [weak self] in
            defer { completion?() }
            do {
                let profile = switch subject {
                case .user(let user):
                    try await client.user(id: user.id)
                case .name(let username, let host):
                    if let userID {
                        try await client.user(id: userID)
                    } else {
                        try await client.user(username: username, host: host)
                    }
                }
                self?.show(profile)
            } catch {
                self?.profileFailed(error)
            }
        }
    }

    private func show(_ profile: UserDetailed) {
        isLoadingProfile = false
        loadError = nil
        self.profile = profile
        user = profile.user
        configureContent()
        ensureTimeline(at: currentIndex)
    }

    private func profileFailed(_ error: any Error) {
        isLoadingProfile = false
        let apiError = error as? MisskeyAPIError
        if apiError?.isAuthenticationFailure == true {
            services.onAuthenticationFailure?()
        }
        guard profile == nil else {
            Toast.show(Self.message(for: error), in: view.window)
            return
        }
        loadError = apiError?.code == "NO_SUCH_USER" ? "ユーザーが見つかりませんでした" : Self.message(for: error)
        configureContent()
    }

    private static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "読み込めませんでした"
    }

    private func configureContent() {
        let user = self.user ?? {
            if case .name(let username, let host) = subject {
                return User(id: "", name: nil, username: username, host: host, avatarUrl: nil)
            }
            return nil
        }()
        guard let user else { return }
        let relation = profile?.relation
        let canFollow = !isAccount && relation?.isKnown == true
        let state = relation.map(FollowState.init) ?? .follow
        header.followButton.isHidden = !canFollow
        header.followButton.apply(state)
        topBar.hasFollowButton = canFollow
        topBar.followButton.apply(state)
        header.configure(ProfileHeaderView.Content(user: user, profile: profile,
                                                  isLoading: isLoadingProfile || (profile == nil && loadError == nil),
                                                  error: loadError))
        avatar.imageView.setURL(user.avatarUrl)
        avatar.accessibilityLabel = "\(user.displayName)のアイコン"
        configureTitle(user)
        configureBanner()
        topBar.setNeedsLayout()
        topBar.layoutIfNeeded()
        relayoutHeader()
    }

    private func configureTitle(_ user: User) {
        let palette = Palette.palette(for: ThemeStyle(traitCollection.userInterfaceStyle))
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        let text = UIKitRichText(resolver: services.engine.emojiResolver, imagePipeline: services.imagePipeline,
                                 palette: palette, scale: scale, linkURL: { _ in nil })
        let name = NSMutableAttributedString(attributedString: text.build(
            user.displayName, emojis: .name(of: user), font: Typography.system(17, bold: true), color: .overlayText,
            simple: true).text)
        name.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: name.length))
        let subtitle = profile?.notesCount.map { "\($0.formatted())件のノート" }
        banner.titleView.configure(name: name, subtitle: subtitle)
        layoutTitle()
    }

    private func configureBanner() {
        guard geometry.width > 0 else { return }
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        banner.setImage(url: profile?.bannerUrl, blurhash: profile?.bannerBlurhash,
                        size: CGSize(width: geometry.width, height: geometry.bannerHeight), scale: scale,
                        imagePipeline: services.imagePipeline)
    }

    @objc private func headerTapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: view)
        if avatarContains(point) {
            openAvatar()
        } else if point.y < banner.frame.maxY {
            bannerTapped()
        } else if let link = header.link(at: gesture.location(in: header)) {
            services.open(link: link, from: self)
        }
    }

    private var isAvatarInFront: Bool {
        (view.subviews.firstIndex(of: avatar) ?? 0) > (view.subviews.firstIndex(of: banner) ?? 0)
    }

    private func avatarContains(_ point: CGPoint) -> Bool {
        let frame = avatar.frame
        guard hypot(point.x - frame.midX, point.y - frame.midY) <= frame.width / 2 else { return false }
        return isAvatarInFront || point.y > banner.frame.maxY
    }

    private func bannerTapped() {
        guard scrolled < geometry.collapseDistance, let url = profile?.bannerUrl else { return }
        let frame = view.convert(banner.frame, to: nil)
        present(DriveFile(imageURL: url, blurhash: profile?.bannerBlurhash),
                target: MediaTransitionTarget(frame: frame, cornerRadius: 0, corners: [], image: banner.image),
                hide: { _ in })
    }

    private func openAvatar() {
        guard let url = (profile?.user ?? user)?.avatarUrl else { return }
        let target = { [weak self] () -> MediaTransitionTarget? in
            guard let self, let window = self.view.window else { return nil }
            let image = self.avatar.imageView
            return MediaTransitionTarget(frame: image.convert(image.bounds, to: window), cornerRadius: image.bounds.width / 2,
                                         corners: [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner,
                                                   .layerMaxXMaxYCorner],
                                         image: image.image?.cgImage)
        }
        present(DriveFile(imageURL: Self.originalImageURL(url), blurhash: (profile?.user ?? user)?.avatarBlurhash),
                target: target(), hide: { [weak self] hidden in self?.avatar.imageView.alpha = hidden ? 0 : 1 })
    }

    private func present(_ file: DriveFile, target: MediaTransitionTarget?, hide: @escaping @MainActor (Bool) -> Void) {
        let source = MediaViewerSource(target: { _ in target }, setHidden: { hide($0 != nil) })
        MediaViewerController.present(files: [file], startIndex: 0, source: source,
                                      imagePipeline: services.imagePipeline, from: self)
    }

    /// Avatars come through the media proxy, shrunk; the viewer shows the original.
    nonisolated static func originalImageURL(_ url: String) -> String {
        guard let components = URLComponents(string: url), components.path.hasPrefix("/proxy/"),
              let original = components.queryItems?.first(where: { $0.name == "url" })?.value,
              original.hasPrefix("http")
        else { return url }
        return original
    }

    private func followTapped() {
        guard let profile else { return }
        services.followTapped(profile, from: self) { [weak self] in self?.loadProfile() }
    }

    private func openFollows(_ list: FollowList) {
        guard let user = profile?.user ?? user else { return }
        services.openFollows(of: user, list: list, from: self)
    }

    private func searchNotes() {
        guard let user = profile?.user ?? user else { return }
        services.openSearchField("from:\(user.acct) ", from: self)
    }

    private func menuElements() -> [UIMenuElement] {
        guard let user = profile?.user ?? user else { return [] }
        var general: [UIMenuElement] = [
            UIAction(title: "ユーザー名をコピー", image: UIImage(systemName: "at")) { [weak self] _ in
                UIPasteboard.general.string = self?.fullAcct(of: user) ?? user.acct
                Toast.show("コピーしました")
            },
        ]
        if let url = services.webURL(of: user) {
            general.append(UIAction(title: "プロフィールのURLをコピー", image: UIImage(systemName: "link")) { _ in
                UIPasteboard.general.url = url
                Toast.show("リンクをコピーしました")
            })
        }
        if let url = profile?.url ?? services.webURL(of: user) {
            general.append(UIAction(title: "ブラウザで開く", image: UIImage(systemName: "safari")) { _ in
                UIApplication.shared.open(url)
            })
        }
        general.append(UIAction(title: "ノートを検索", image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
            self?.searchNotes()
        })
        var elements: [UIMenuElement] = [UIMenu(options: .displayInline, children: general)]
        if !isAccount, services.client != nil {
            let direct = UIAction(title: "ダイレクトで送る", image: UIImage(systemName: "envelope")) { [weak self] _ in
                guard let self else { return }
                self.services.compose(to: self.profile?.user ?? user, from: self)
            }
            elements.insert(UIMenu(options: .displayInline, children: [direct]), at: 0)
        }

        guard let relation = profile?.relation, relation.isKnown, !isAccount else { return elements }
        var actions: [UIMenuElement] = []
        if relation.isFollowing {
            actions.append(UIAction(title: "他の人への返信をTLに含める", image: UIImage(systemName: "arrowshape.turn.up.left"),
                                    state: relation.withReplies ? .on : .off) { [weak self] _ in
                let shows = !relation.withReplies
                self?.change({ $0.withReplies = shows }) { try await $0.setShowsReplies(shows, of: $1) }
            })
        }
        actions.append(UIAction(title: relation.isMuted ? "ミュートを解除" : "ミュート",
                                image: UIImage(systemName: relation.isMuted ? "speaker.wave.2" : "speaker.slash")) {
            [weak self] _ in
            let mutes = !relation.isMuted
            self?.change({ $0.isMuted = mutes }, done: mutes ? "ミュートしました" : "ミュートを解除しました", hides: mutes) {
                mutes ? try await $0.mute($1) : try await $0.unmute($1)
            }
        })
        actions.append(UIAction(title: relation.isRenoteMuted ? "リノートのミュートを解除" : "リノートをミュート",
                                image: UIImage(systemName: "arrow.2.squarepath")) { [weak self] _ in
            let mutes = !relation.isRenoteMuted
            self?.change({ $0.isRenoteMuted = mutes },
                         done: mutes ? "リノートをミュートしました" : "リノートのミュートを解除しました") {
                mutes ? try await $0.muteRenotes(of: $1) : try await $0.unmuteRenotes(of: $1)
            }
        })
        if relation.isBlocking {
            actions.append(UIAction(title: "ブロックを解除", image: UIImage(systemName: "nosign")) { [weak self] _ in
                self?.confirmUnblock()
            })
        } else {
            actions.append(UIAction(title: "ブロック", image: UIImage(systemName: "nosign"), attributes: .destructive) {
                [weak self] _ in self?.confirmBlock()
            })
        }
        actions.append(UIAction(title: "通報", image: UIImage(systemName: "flag")) { [weak self] _ in
            guard let self else { return }
            self.services.report(self.profile?.user ?? user, from: self)
        })
        elements.append(UIMenu(options: .displayInline, children: actions))
        return elements
    }

    private func confirmBlock() {
        guard let profile else { return }
        services.confirmBlock(profile.user, from: self) { [weak self] in
            self?.change({ relation in
                relation.isBlocking = true
                relation.isFollowing = false
                relation.isFollowed = false
                relation.hasPendingFollowRequestFromYou = false
            }, done: "ブロックしました", hides: true) { try await $0.block($1) }
        }
    }

    private func confirmUnblock() {
        guard let profile else { return }
        services.confirmUnblock(profile.user, relation: profile.relation, from: self) { [weak self] in
            self?.loadProfile()
        }
    }

    private func change(_ update: (inout UserDetailed.Relation) -> Void, done: String? = nil, hides: Bool = false,
                        request: @escaping @Sendable (MisskeyClient, String) async throws -> Void) {
        guard let profile else { return }
        services.changeRelation(of: profile.user.id, from: profile.relation, update: update, message: done, hides: hides,
                                done: { [weak self] in self?.loadProfile() }, request: request)
    }

    @objc private func relationDidChange(_ notification: Notification) {
        guard var profile, notification.userInfo?["userID"] as? String == profile.user.id,
              let relation = notification.userInfo?["relation"] as? UserDetailed.Relation, relation != profile.relation
        else { return }
        profile.relation = relation
        self.profile = profile
        configureContent()
    }

    private func fullAcct(of user: User) -> String {
        if user.host != nil { return user.acct }
        return "@\(user.username)@\(services.account.host)"
    }
}

extension ProfileViewController: TimelineScrollObserver {
    func timelineWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === currentTimeline?.collectionView else { return }
        refreshArmed = !isRefreshing
    }

    func timelineDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === currentTimeline?.collectionView else { return }
        applyScroll()
        pullDidChange(scrollView)
    }

    func timelineDidEndScrolling(_ scrollView: UIScrollView) {}
}

extension ProfileViewController: UIScrollViewDelegate {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === pager else { return }
        alignOtherTimelines()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === pager else { return }
        let progress = pager.contentOffset.x / max(1, pager.bounds.width)
        let previous = tabStrip.selectedIndex
        tabStrip.setProgress(progress)
        if tabStrip.selectedIndex != previous && pager.isTracking {
            pageFeedback.selectionChanged()
        }
        ensureTimeline(at: Int(progress.rounded(.down)))
        ensureTimeline(at: Int(progress.rounded(.up)))
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if scrollView === pager { pageDidSettle() }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if scrollView === pager { pageDidSettle() }
    }
}

extension ProfileViewController: BackSwipeGating {
    var allowsContentBackSwipe: Bool { pager.isAtFirstPage }
}

extension ProfileViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        let point = gesture.location(in: view)
        guard topBar.hitTest(view.convert(point, to: topBar), with: nil) == nil else { return false }
        if avatarContains(point) || point.y < banner.frame.maxY { return true }
        guard header.hitTest(view.convert(point, to: header), with: nil) == nil else { return false }
        return header.frame.contains(point) && point.y < tabs.frame.minY
    }
}