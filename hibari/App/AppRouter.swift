import UIKit

@MainActor
final class AppRouter {
    private let window: UIWindow
    private let accounts: AccountStore
    private let resources: ServerResourceCache
    private let unread: UnreadNotifications
    private var container: SideDrawerController?
    private weak var root: RootViewController?
    private weak var signIn: SignInViewController?
    private var loadedResources: (server: URL, resources: ServerResources)?
    private var openCount = 0
    private var verifyingTokens: Set<String> = []

    init(window: UIWindow, accounts: AccountStore = .shared, resources: ServerResourceCache = .shared) {
        self.window = window
        self.accounts = accounts
        self.resources = resources
        unread = UnreadNotifications(accounts: accounts)
    }

    func start() {
        #if PERF
        if let fixtures = FixtureStore.shared {
            show(RootViewController(session: .fixtures(fixtures)), animated: false)
        } else {
            show(MissingFixturesViewController(), animated: false)
        }
        #else
        if AppSettings.signsOutOnLaunch {
            accounts.signOutAll()
            PendingMiAuthStore().session = nil
            AppSettings.hasAcceptedTerms = false
        }
        if AppSettings.usesTestAccounts, let mode = AppSettings.mockAccounts,
           let serverURL = ServerAddress.url(from: AppSettings.signInServer) {
            setupMockAccounts(mode, server: serverURL)
        }
        if let account = accounts.current, let token = accounts.token(for: account) {
            open(account, token: token, animated: false)
            if PendingMiAuthStore().session != nil {
                DispatchQueue.main.async { self.showAddAccount() }
            }
        } else {
            showSignIn(animated: false)
        }
        #endif
    }

    func handle(_ url: URL) {
        guard MiAuth.session(fromCallback: url) != nil else { return }
        signIn?.handleCallback(url)
    }

    func didBecomeActive() {
        signIn?.appDidBecomeActive()
        #if !PERF
        unread.start()
        #endif
    }

    func willResignActive() {
        unread.stop()
    }

    private func showSignIn(message: String? = nil, animated: Bool = true) {
        container = nil
        loadedResources = nil
        openCount += 1
        let controller = SignInViewController(message: message)
        signIn = controller
        controller.onSignIn = { [weak self] account, token in
            guard let self else { return }
            try self.accounts.signIn(account, token: token)
            self.open(account, token: token, animated: true)
        }
        show(controller, animated: animated)
    }

    private func open(_ account: Account, token: String, animated: Bool, completion: (() -> Void)? = nil) {
        openCount += 1
        let count = openCount
        let server = account.server
        if let loaded = loadedResources, loaded.server == server {
            showTimelines(account, token: token, resources: loaded.resources, animated: animated)
            completion?()
            return
        }
        let connecting = ConnectingViewController(account: account)
        connecting.onSignOut = { [weak self] in self?.signOut(account) }
        connecting.onRetry = { [weak self] in self?.open(account, token: token, animated: false) }
        if container == nil {
            installContainer(content: connecting, animated: animated)
        }
        let cache = resources
        Task {
            if let saved = await Task.detached(operation: { cache.load(for: server) }).value {
                guard count == openCount else { return }
                showTimelines(account, token: token, resources: saved, animated: true)
                completion?()
                refreshResources(of: server)
                return
            }
            guard count == openCount else { return }
            container?.setContent(connecting, animated: true)
            completion?()
            do {
                let fetched = try await Task.detached(operation: { try await cache.refresh(for: server) }).value
                guard count == openCount else { return }
                showTimelines(account, token: token, resources: fetched, animated: true)
            } catch {
                guard count == openCount else { return }
                connecting.showError(error)
            }
        }
    }

    private func refreshResources(of server: URL) {
        let cache = resources
        Task {
            guard let fresh = try? await Task.detached(operation: { try await cache.refresh(for: server) }).value,
                  loadedResources?.server == server
            else { return }
            loadedResources = (server, fresh)
        }
    }

    private func installContainer(content: UIViewController, animated: Bool) {
        let drawer = DrawerViewController(accounts: accounts, unread: unread)
        drawer.onSelect = { [weak self] account in self?.switchAccount(to: account) }
        drawer.onShowAccounts = { [weak self] in self?.showAccountSwitcher() }
        drawer.onShowProfile = { [weak self] in
            self?.root?.showAccountProfile()
            self?.container?.close(animated: true)
        }
        drawer.onShowBookmarks = { [weak self] in
            self?.root?.showBookmarks()
            self?.container?.close(animated: true)
        }
        drawer.onShowSettings = { [weak self] in
            self?.root?.showSettings()
            self?.container?.close(animated: true)
        }
        let container = SideDrawerController(content: content, drawer: drawer)
        self.container = container
        show(container, animated: animated)
    }

    private func showTimelines(_ account: Account, token: String, resources: ServerResources, animated: Bool) {
        var account = accounts.accounts.first { $0.id == account.id } ?? account
        account.resolveNameEmojis(resources.emojiResolver())
        accounts.update(account)
        loadedResources = (account.server, resources)

        let accountID = account.id
        let session = TimelineSession.live(account: account, token: token, resources: resources) {
            [weak unread] in
            Task { @MainActor in unread?.didRead(accountID) }
        }
        if let previous = self.root, accounts.accounts.contains(where: { $0.id == previous.session.account.id }) {
            previous.saveTimelines()
        }
        let root = RootViewController(session: session, unread: unread)
        root.onAuthenticationFailure = { [weak self] in self?.authenticationFailed(account) }
        root.onOpenDrawer = { [weak self] in self?.container?.open(animated: true, byUser: true) }
        root.onShowAccounts = { [weak self] in self?.showAccountSwitcher() }
        self.root = root
        if let container {
            container.setContent(root, animated: animated)
        } else {
            installContainer(content: root, animated: animated)
        }
        refreshProfile(account, token: token, resources: resources)
    }

    private func refreshProfile(_ account: Account, token: String, resources: ServerResources) {
        Task {
            do {
                let me = try await MisskeyClient(server: account.server, token: token).request("i", as: MeDetailed.self)
                guard var updated = accounts.accounts.first(where: { $0.id == account.id }) else { return }
                updated.update(with: me)
                updated.resolveNameEmojis(resources.emojiResolver())
                accounts.update(updated)
                if root?.session.account.id == account.id {
                    root?.update(updated)
                }
            } catch let error as MisskeyAPIError where error.isAuthenticationFailure {
                sessionExpired(account, token: token)
            } catch {
            }
        }
    }

    private func switchAccount(to account: Account) {
        guard account.id != accounts.current?.id, let token = accounts.token(for: account) else {
            container?.close(animated: true)
            return
        }
        accounts.select(account)
        let chosenAt = ContinuousClock.now
        open(account, token: token, animated: true) { [weak self] in
            Task {
                try? await Task.sleep(until: chosenAt + .milliseconds(250))
                self?.container?.close(animated: true)
            }
        }
    }

    private func showAccountSwitcher() {
        guard let container, container.presentedViewController == nil else { return }
        let list = AccountSwitcherViewController(accounts: accounts, unread: unread)
        list.onSelect = { [weak self, weak list] account in
            list?.dismiss(animated: true)
            self?.switchAccount(to: account)
        }
        list.onAdd = { [weak self, weak list] in
            list?.dismiss(animated: true) { self?.showAddAccount() }
        }
        list.onSignOut = { [weak self] account in self?.signOut(account) }
        container.present(list, animated: true)
    }

    private func showAddAccount() {
        guard let container, container.presentedViewController == nil else { return }
        let controller = SignInViewController(onClose: { [weak container] in
            container?.dismiss(animated: true)
        })
        signIn = controller
        controller.onSignIn = { [weak self, weak controller] account, token in
            guard let self else { return }
            try self.accounts.signIn(account, token: token)
            controller?.dismiss(animated: true)
            self.open(account, token: token, animated: true) { [weak self] in
                self?.container?.close(animated: false)
            }
        }
        controller.isModalInPresentation = true
        container.present(controller, animated: true)
    }

    private func signOut(_ account: Account) {
        let wasCurrent = accounts.current?.id == account.id
        accounts.signOut(account)
        guard let next = accounts.current, let token = accounts.token(for: next) else {
            dismissSheet { self.showSignIn() }
            return
        }
        if wasCurrent {
            open(next, token: token, animated: true)
        }
    }

    private func authenticationFailed(_ account: Account) {
        guard let token = accounts.token(for: account), verifyingTokens.insert(account.id).inserted else { return }
        Task {
            let refused = await MisskeyClient(server: account.server, token: token).refusesToken()
            verifyingTokens.remove(account.id)
            if refused { sessionExpired(account, token: token) }
        }
    }

    private func sessionExpired(_ account: Account, token: String) {
        guard accounts.token(for: account) == token else { return }
        let wasCurrent = accounts.current?.id == account.id
        accounts.signOut(account)
        let message = "ログインの有効期限が切れました。もう一度ログインしてください"
        guard let next = accounts.current, let nextToken = accounts.token(for: next) else {
            dismissSheet { self.showSignIn(message: message) }
            return
        }
        guard wasCurrent else { return }
        Toast.show("\(account.acct) の\(message)", in: window, important: true)
        guard let presented = container?.presentedViewController, presented !== signIn else {
            open(next, token: nextToken, animated: true)
            return
        }
        presented.dismiss(animated: true) { self.open(next, token: nextToken, animated: true) }
    }

    private func dismissSheet(then completion: @escaping () -> Void) {
        guard let presented = container?.presentedViewController else {
            completion()
            return
        }
        presented.dismiss(animated: true, completion: completion)
    }

    private func show(_ controller: UIViewController, animated: Bool) {
        guard animated, window.rootViewController != nil else {
            window.rootViewController = controller
            return
        }
        UIView.transition(with: window, duration: 0.3, options: [.transitionCrossDissolve, .allowAnimatedContent]) {
            UIView.performWithoutAnimation {
                self.window.rootViewController = controller
            }
        }
    }

    private func setupMockAccounts(_ mode: String, server: URL) {
        accounts.signOutAll()
        let mainMe = MeDetailed(
            id: "mockuser",
            username: "hibari_mock",
            name: "Hibari テスト",
            avatarUrl: "\(server.absoluteString)/files/avatar.png",
            policies: .init(ltlAvailable: true, gtlAvailable: true),
            followingCount: 6,
            followersCount: 128
        )
        let main = Account(server: server, me: mainMe)
        try? accounts.signIn(main, token: "mock-0-uitest")

        if mode == "both" {
            let subMe = MeDetailed(
                id: "mocksub",
                username: "hibari_sub",
                name: "サブ :blobcat:",
                avatarUrl: "\(server.absoluteString)/files/sub_avatar.png",
                policies: .init(ltlAvailable: true, gtlAvailable: true),
                followingCount: 2,
                followersCount: 3
            )
            let sub = Account(server: server, me: subMe)
            try? accounts.signIn(sub, token: "mock-0-sub.uitest")
            accounts.select(main)
        }
    }
}
