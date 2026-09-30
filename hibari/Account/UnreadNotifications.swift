import Foundation

@MainActor
final class UnreadNotifications {
    /// Posted (by the store) when a count changes.
    static let didChange = Notification.Name("UnreadNotifications.didChange")

    private let accounts: AccountStore
    private let urlSession: URLSession
    private let interval: Duration
    private var counts: [String: Int] = [:]
    private var readAt: [String: ContinuousClock.Instant] = [:]
    private var inFlight: Set<String> = []
    private var polling: Task<Void, Never>?

    init(accounts: AccountStore, urlSession: URLSession = .misskeyAPI, interval: Duration = .seconds(30)) {
        self.accounts = accounts
        self.urlSession = urlSession
        self.interval = interval
        NotificationCenter.default.addObserver(self, selector: #selector(accountsDidChange),
                                               name: AccountStore.didChange, object: accounts)
    }

    func count(for account: Account) -> Int {
        counts[account.id] ?? 0
    }

    func hasUnread(_ account: Account) -> Bool {
        count(for: account) > 0
    }

    var othersHaveUnread: Bool {
        accounts.others.contains(where: hasUnread)
    }

    /// Checks now, then every `interval` until `stop`.
    func start() {
        guard polling == nil else { return }
        let interval = interval
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkAll()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        polling?.cancel()
        polling = nil
    }

    func checkAll() async {
        await check(accounts.accounts)
    }

    private func check(_ accounts: [Account]) async {
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { await self.check(account) }
            }
        }
    }

    private func check(_ account: Account) async {
        guard let token = accounts.token(for: account), inFlight.insert(account.id).inserted else { return }
        defer { inFlight.remove(account.id) }
        let askedAt = ContinuousClock.now
        let client = MisskeyClient(server: account.server, token: token, session: urlSession)
        guard let unread = try? await client.request("i", as: UnreadNotificationCount.self) else { return }
        update(unread.count, for: account.id, askedAt: askedAt)
    }

    /// A count the server gave for a request made at `askedAt` (also `/api/i` responses
    /// from elsewhere).
    func update(_ count: Int, for accountID: String, askedAt: ContinuousClock.Instant) {
        guard accounts.accounts.contains(where: { $0.id == accountID }),
              readAt[accountID].map({ askedAt > $0 }) ?? true
        else { return }
        let old = counts.updateValue(count, forKey: accountID)
        if old ?? 0 != count { notify() }
    }

    func didRead(_ accountID: String) {
        readAt[accountID] = .now
        guard counts[accountID] ?? 0 != 0 else { return }
        counts[accountID] = 0
        notify()
    }

    @objc private func accountsDidChange() {
        let signedIn = Set(accounts.accounts.map(\.id))
        counts = counts.filter { signedIn.contains($0.key) }
        readAt = readAt.filter { signedIn.contains($0.key) }
        notify()
        let added = accounts.accounts.filter { counts[$0.id] == nil }
        if polling != nil, !added.isEmpty {
            Task { await check(added) }
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
