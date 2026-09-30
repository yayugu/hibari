import Foundation

@MainActor
final class AccountStore {
    static let shared = AccountStore(
        defaults: .standard,
        tokens: KeychainTokenStore(service: KeychainTokenStore.defaultService + (AppSettings.usesTestAccounts ? ".uitest" : "")),
        keyPrefix: AppSettings.usesTestAccounts ? "HibariUITest" : "Hibari")

    /// Posted (by the store) when accounts are added, removed, switched or updated.
    static let didChange = Notification.Name("HibariAccountsDidChange")

    private let defaults: UserDefaults
    private let tokens: any TokenStore
    private let accountsKey: String
    private let currentKey: String

    private(set) var accounts: [Account]

    init(defaults: UserDefaults, tokens: any TokenStore, keyPrefix: String = "Hibari") {
        self.defaults = defaults
        self.tokens = tokens
        accountsKey = "\(keyPrefix)Accounts"
        currentKey = "\(keyPrefix)CurrentAccount"
        accounts = defaults.data(forKey: accountsKey)
            .flatMap { try? JSONDecoder().decode([Account].self, from: $0) } ?? []
        // A Keychain item can outlive a reinstall while UserDefaults does not (and the
        // reverse after a restore to another device): keep only accounts with a token.
        accounts.removeAll { tokens.token(for: $0.id) == nil }
    }

    var current: Account? {
        let id = defaults.string(forKey: currentKey)
        return accounts.first { $0.id == id } ?? accounts.first
    }

    var others: [Account] {
        let current = current?.id
        return accounts.filter { $0.id != current }
    }

    func token(for account: Account) -> String? {
        tokens.token(for: account.id)
    }

    func signIn(_ account: Account, token: String) throws {
        try tokens.setToken(token, for: account.id)
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        defaults.set(account.id, forKey: currentKey)
        save()
    }

    func select(_ account: Account) {
        guard accounts.contains(where: { $0.id == account.id }), current?.id != account.id else { return }
        defaults.set(account.id, forKey: currentKey)
        notify()
    }

    func update(_ account: Account) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }), accounts[index] != account else { return }
        accounts[index] = account
        save()
    }

    /// Removes the account, its token and its saved timelines. When it was the current
    /// one, the next account (or the previous, for the last) becomes current.
    func signOut(_ account: Account) {
        TimelineSnapshotStore.removeAll(accountID: account.id)
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else {
            tokens.removeToken(for: account.id)
            return
        }
        let wasCurrent = current?.id == account.id
        tokens.removeToken(for: account.id)
        accounts.remove(at: index)
        if wasCurrent {
            let next = accounts.indices.contains(index) ? accounts[index] : accounts.last
            defaults.set(next?.id, forKey: currentKey)
        }
        save()
    }

    func signOutAll() {
        for account in accounts { signOut(account) }
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(accounts), forKey: accountsKey)
        notify()
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
