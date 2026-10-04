import Foundation

/// The accounts' unread notification counts, as badges show them. Follows approved
/// automatically are left out: Misskey notifies `followRequestAccepted` for every follow
/// the account makes, even of users who are not locked, and counts it unread.
@MainActor
final class UnreadNotifications {
    /// Posted (by the store) when a count changes.
    static let didChange = Notification.Name("UnreadNotifications.didChange")

    private let accounts: AccountStore
    private let urlSession: URLSession
    private let interval: Duration
    private var counts: [String: Int] = [:]
    private var readAt: [String: ContinuousClock.Instant] = [:]
    private var seen: [String: Seen] = [:]
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
        var count = unread.count
        // Without the count Misskey does not say which ones are unread.
        if let exact = unread.unreadNotificationsCount {
            count -= await automaticApprovals(amongNewest: exact, of: account.id, client: client)
        }
        update(count, for: account.id, askedAt: askedAt)
    }

    /// What the last check made of an account's unread notifications (the newest `count`).
    private struct Seen {
        let count: Int
        let newestID: String?
        /// The `followRequestAccepted` among them by id: whether the user is not locked.
        let approvals: [String: Bool]

        var automatic: Int { approvals.values.count(where: \.self) }
    }

    /// How many of the newest `count` notifications are follows approved automatically
    /// (by a user whose account is not locked). Looked at again only when the count
    /// changes, or, if some were, when a newer notification came in its place.
    private func automaticApprovals(amongNewest count: Int, of accountID: String, client: MisskeyClient) async -> Int {
        guard count > 0 else {
            seen[accountID] = nil
            return 0
        }
        let last = seen[accountID]
        if let last, last.count == count {
            if last.automatic == 0 { return 0 }
            if let newest = try? await client.latestNotifications(limit: 1), newest.first?.id == last.newestID {
                return last.automatic
            }
        }
        guard let notifications = try? await client.latestNotifications(limit: count) else { return 0 }
        let accepted = notifications.filter { $0.type == "followRequestAccepted" }
        var approvals = (last?.approvals ?? [:]).filter { id, _ in accepted.contains { $0.id == id } }
        let unknown = accepted.filter { approvals[$0.id] == nil }
        if !unknown.isEmpty {
            // Unknown users and failures count as approved by hand; asked again next time.
            guard let unlocked = try? await client.unlockedUsers(among: Array(Set(unknown.compactMap(\.userId))))
            else {
                seen[accountID] = nil
                return approvals.values.count(where: \.self)
            }
            for notification in unknown {
                approvals[notification.id] = notification.userId.map(unlocked.contains) ?? false
            }
        }
        let checked = Seen(count: count, newestID: notifications.first?.id, approvals: approvals)
        seen[accountID] = checked
        return checked.automatic
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
        seen = seen.filter { signedIn.contains($0.key) }
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
