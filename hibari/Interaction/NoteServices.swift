import UIKit

@MainActor
final class NoteServices {
    let engine: NoteLayoutEngine
    let clock: TimelineClock
    /// nil for the fixtures of perf builds: nothing is fetched or sent.
    let client: MisskeyClient?
    let emojis: EmojiCatalog
    let reactions: ReactionController
    let recentReactions: RecentReactions
    let renotes: RenoteController
    let bookmarks: BookmarkController
    let polls: PollController
    let renderer: NoteRenderer
    let imagePipeline: ImagePipeline
    let account: Account
    let maxNoteTextLength: Int
    /// The server rejected the token (a screen besides the timelines found out).
    var onAuthenticationFailure: (() -> Void)?

    /// The account created a note (posted, replied, quoted or renoted). `userInfo["note"]`
    /// is the `Note`.
    static let didPostNote = Notification.Name("NoteServices.didPostNote")
    /// The account deleted one of its notes (or took a renote back). `userInfo["noteID"]`
    /// is its id.
    static let didDeleteNote = Notification.Name("NoteServices.didDeleteNote")
    /// The account muted or blocked a user: the screens take out what shows them (see
    /// `TimelineItem.involves(user:)`). `userInfo["userID"]` is their id.
    static let didHideUser = Notification.Name("NoteServices.didHideUser")

    init(session: TimelineSession, renderer: NoteRenderer = .shared, imagePipeline: ImagePipeline = .shared) {
        engine = session.engine
        clock = session.clock
        client = session.client
        account = session.account
        maxNoteTextLength = session.maxNoteTextLength
        emojis = session.emojis
        recentReactions = RecentReactions(account: session.account)
        reactions = ReactionController(client: session.client, emojis: session.emojis, recentReactions: recentReactions)
        renotes = RenoteController(accountUserID: session.account.userID)
        bookmarks = BookmarkController(client: session.client)
        polls = PollController(client: session.client)
        self.renderer = renderer
        self.imagePipeline = imagePipeline
    }

    var marks: NoteMarks {
        NoteMarks(renotes: renotes.marks, bookmarks: bookmarks.marks)
    }

    func marked(_ note: Note) -> Note {
        marks.apply(to: note)
    }

    func learn(from notes: [Note]) {
        renotes.learn(from: notes)
        bookmarks.learn(from: notes)
    }

    func webURL(of note: Note) -> URL? {
        client?.server.appending(path: "notes").appending(path: note.id)
    }

    var sensitiveMedia: SensitiveMediaDisplay { AppSettings.sensitiveMedia(for: account) }

    func webURL(of user: User) -> URL? {
        client?.server.appending(path: user.acct)
    }

    func isAccount(_ user: User) -> Bool {
        user.host == nil && user.id == account.userID
    }

    /// The user a mention (`@user` or `@user@host`) names. The host is nil for users of
    /// `server`, also when the mention spells it out.
    nonisolated static func mentionedUser(_ acct: String, server: URL?) -> (username: String, host: String?)? {
        let parts = acct.drop { $0 == "@" }.split(separator: "@", maxSplits: 1).map(String.init)
        guard let username = parts.first, !username.isEmpty else { return nil }
        var host = parts.count > 1 ? parts[1].lowercased() : nil
        if let server, let serverHost = server.host()?.lowercased(),
           host == serverHost || host == server.port.map({ "\(serverHost):\($0)" }) {
            host = nil
        }
        return (username, host)
    }

    /// Where a link in a note's text goes: URLs as they are, mentions and hashtags to their
    /// pages on the account's server (until the app has its own).
    func url(forLink link: String) -> URL? {
        if link.hasPrefix("mention:") {
            return client?.server.appending(path: String(link.dropFirst("mention:".count)))
        }
        if link.hasPrefix("hashtag:") {
            return client?.server.appending(path: "tags").appending(path: String(link.dropFirst("hashtag:".count)))
        }
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased() else { return nil }
        return scheme == "http" || scheme == "https" ? url : nil
    }
}

extension NoteServices {
    func openNote(_ note: Note, from controller: UIViewController) {
        let detail = NoteDetailViewController(note: note.displayedNote, services: self)
        controller.navigationController?.pushViewController(detail, animated: true)
    }

    /// Mentions open the profile screen, hashtags the search for them; everything else
    /// the browser (or the app the URL belongs to).
    func open(link: String, from controller: UIViewController) {
        if link.hasPrefix("mention:"), let client,
           let (username, host) = Self.mentionedUser(String(link.dropFirst("mention:".count)),
                                                     server: client.server) {
            open(profile: .name(username: username, host: host), from: controller)
            return
        }
        if link.hasPrefix("hashtag:"), client != nil {
            openSearch("#" + link.dropFirst("hashtag:".count), from: controller)
            return
        }
        guard let url = url(forLink: link) else { return }
        UIApplication.shared.open(url)
    }

    /// The account's achievements on its server's web client: the app shows only what a
    /// notification says.
    func openAchievements() {
        guard let url = client?.server.appending(path: "my/achievements") else { return }
        UIApplication.shared.open(url)
    }

    func openUser(_ user: User, from controller: UIViewController, animated: Bool = true) {
        guard client != nil else { return }
        open(profile: .user(user), from: controller, animated: animated)
    }

    private func open(profile subject: ProfileSubject, from controller: UIViewController, animated: Bool = true) {
        guard let navigation = controller.navigationController else { return }
        if let top = navigation.topViewController as? ProfileViewController, top.shows(subject) {
            top.scrollToTop()
            return
        }
        navigation.pushViewController(ProfileViewController(subject: subject, services: self), animated: animated)
    }

    /// The users who follow `user`, or whom they follow (with the other list a swipe away).
    func openFollows(of user: User, list: FollowList, from controller: UIViewController, animated: Bool = true) {
        guard client != nil else { return }
        controller.navigationController?.pushViewController(
            FollowListViewController(user: user, list: list, services: self), animated: animated)
    }

    /// The results of searching `text`, unless they are already on top.
    func openSearch(_ text: String, from controller: UIViewController) {
        let query = SearchQuery(text, server: client?.server)
        guard client != nil, !query.isEmpty, let navigation = controller.navigationController else { return }
        if let top = navigation.topViewController as? SearchResultsViewController, top.query == query {
            top.scrollToTop()
            return
        }
        navigation.pushViewController(SearchResultsViewController(query: query, services: self), animated: true)
    }

    func openSearchField(_ text: String, from controller: UIViewController) {
        guard client != nil else { return }
        controller.navigationController?.pushViewController(SearchViewController(services: self, initialText: text),
                                                            animated: true)
    }

    /// The reaction button: takes the user's reaction back, or picks one (likes at once a
    /// note that takes likes only). `origin` (window coordinates) is where the reaction
    /// pops up.
    func reactButtonTapped(_ note: Note, from controller: UIViewController, origin: CGRect?) {
        if reactions.state(of: note).myReaction != nil {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            reactions.unreact(note)
            return
        }
        if note.isLikeOnly {
            react(with: ReactionKey.like, to: note, origin: origin)
            return
        }
        let picker = EmojiPickerViewController(emojis: emojis, recent: recentReactions.all, imagePipeline: imagePipeline,
                                               hidesSensitive: note.rejectsSensitiveReactions) { [weak self] reaction in
            self?.react(with: reaction, to: note, origin: origin)
        }
        controller.present(picker, animated: true)
    }

    func reactionTapped(_ key: String, on note: Note, origin: CGRect?) {
        do throws(ReactionController.Refusal) {
            let added = try reactions.toggle(key, on: note)
            UIImpactFeedbackGenerator(style: added ? .medium : .light).impactOccurred()
            if added, let origin {
                ReactionBurst.show(key, emojis: emojis, imagePipeline: imagePipeline, from: origin)
            }
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            Toast.show(error.message)
        }
    }

    func react(with reaction: String, to note: Note, origin: CGRect?) {
        do throws(ReactionController.Refusal) {
            try reactions.react(with: reaction, to: note)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if let origin {
                ReactionBurst.show(ReactionKey.stored(reaction), emojis: emojis, imagePipeline: imagePipeline, from: origin)
            }
        } catch {
            Toast.show(error.message)
        }
    }

    func vote(for index: Int, in note: Note) {
        guard polls.vote(for: index, in: note) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func compose(reply: Note? = nil, quote: Note? = nil, to recipient: User? = nil, from controller: UIViewController) {
        guard let client else { return }
        controller.present(ComposeViewController(services: self, client: client, reply: reply, quote: quote,
                                                 recipient: recipient),
                           animated: true)
    }

    /// A reply to a direct note is direct too, for the same users.
    func replyTapped(_ note: Note, from controller: UIViewController) {
        compose(reply: note, from: controller)
    }

    func renoteMenu(for note: Note, from controller: UIViewController) -> UIMenu {
        let (title, actions) = renoteActions(for: note, from: controller)
        return UIMenu(title: title ?? "", children: actions.map { action in
            UIAction(title: action.title, image: UIImage(systemName: action.symbol),
                     attributes: action.isEnabled ? [] : .disabled) { _ in action.perform() }
        })
    }

    func renoteTapped(_ note: Note, from controller: UIViewController) {
        let (title, actions) = renoteActions(for: note, from: controller)
        showSheet(title: title, actions: actions, from: controller)
    }

    private func renoteActions(for note: Note, from controller: UIViewController) -> (String?, [MenuAction]) {
        let allowed = note.canBeRenoted(by: account)
        let renote = renotes.isRenoted(note)
            ? MenuAction(title: "リノートを取り消す", symbol: "arrow.uturn.backward",
                         isEnabled: !renotes.isBusy(note)) { [weak self] in self?.undoRenote(note) }
            : MenuAction(title: "リノート", symbol: "arrow.2.squarepath",
                         isEnabled: allowed && !renotes.isBusy(note)) { [weak self] in self?.renote(note) }
        let quote = MenuAction(title: "引用", symbol: "quote.opening", isEnabled: allowed) {
            [weak self, weak controller] in
            guard let controller else { return }
            self?.compose(quote: note, from: controller)
        }
        return (allowed ? nil : "この投稿はリノートできません", [renote, quote])
    }

    /// For the visibility picked last, narrowed to the note's (as Misskey would). The
    /// button shows it right away.
    func renote(_ note: Note) {
        guard let client, !renotes.isRenoted(note), !renotes.isBusy(note) else { return }
        let draft = NoteDraft(visibility: NoteVisibility.remembered(for: account).narrowed(to: NoteVisibility(of: note)),
                              renoteID: note.id)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        renotes.set(.sending, for: note.id, renoteCount: ServerCount.adding(note.renoteCount, 1))
        Task { [weak self] in
            do {
                let created = try await client.createNote(draft)
                self?.renotes.set(.renoted(created.id), for: note.id, renoteCount: nil)
                Toast.show("リノートしました")
                self?.didPost(created)
            } catch {
                self?.renotes.set(.notRenoted, for: note.id, renoteCount: note.renoteCount)
                self?.failed(error, fallback: "リノートできませんでした")
            }
        }
    }

    func undoRenote(_ note: Note) {
        guard let client, case .renoted(let renoteID) = renotes.state(of: note.id) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        renotes.set(.deleting(renoteID), for: note.id, renoteCount: max(0, max(0, note.renoteCount) - 1))
        Task { [weak self] in
            do {
                try await client.deleteNote(renoteID)
            } catch {
                if (error as? MisskeyAPIError)?.code != "NO_SUCH_NOTE" {
                    self?.renotes.set(.renoted(renoteID), for: note.id, renoteCount: note.renoteCount)
                    self?.failed(error, fallback: "リノートを取り消せませんでした")
                    return
                }
            }
            self?.renotes.set(.notRenoted, for: note.id, renoteCount: nil)
            Toast.show("リノートを取り消しました")
            NotificationCenter.default.post(name: Self.didDeleteNote, object: self, userInfo: ["noteID": renoteID])
        }
    }

    func failed(_ error: any Error, fallback: String) {
        if (error as? MisskeyAPIError)?.isAuthenticationFailure == true {
            onAuthenticationFailure?()
        }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        Toast.show((error as? LocalizedError)?.errorDescription ?? fallback)
    }

    func didPost(_ note: Note) {
        NotificationCenter.default.post(name: Self.didPostNote, object: self, userInfo: ["note": note])
    }

    func bookmarkTapped(_ note: Note) {
        guard client != nil else {
            notAvailableYet("ブックマーク")
            return
        }
        let bookmarked = bookmarks.toggle(note)
        UIImpactFeedbackGenerator(style: bookmarked ? .medium : .light).impactOccurred()
        Toast.show(bookmarked ? "ブックマークに追加しました" : "ブックマークから削除しました")
    }

    func share(_ note: Note, from controller: UIViewController) {
        guard let url = webURL(of: note) else { return }
        controller.present(UIActivityViewController(activityItems: [url], applicationActivities: nil), animated: true)
    }

    private func showSheet(title: String?, actions: [MenuAction], from controller: UIViewController) {
        let sheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for action in actions {
            let alertAction = UIAlertAction(title: action.title, style: action.isDestructive ? .destructive : .default) {
                _ in action.perform()
            }
            alertAction.isEnabled = action.isEnabled
            sheet.addAction(alertAction)
        }
        sheet.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        controller.present(sheet, animated: true)
    }

    func menu(for note: Note, from controller: UIViewController) -> UIMenu {
        UIMenu(children: menuSections(for: note, from: controller).map { section in
            UIMenu(options: .displayInline, children: section.map { action in
                UIAction(title: action.title, image: UIImage(systemName: action.symbol),
                         attributes: action.isDestructive ? .destructive : []) { _ in action.perform() }
            })
        })
    }

    private struct MenuAction {
        let title: String
        let symbol: String
        var isEnabled = true
        var isDestructive = false
        let perform: () -> Void
    }

    private func menuSections(for note: Note, from controller: UIViewController) -> [[MenuAction]] {
        var actions: [MenuAction] = []
        if let text = note.text, !text.isEmpty {
            actions.append(MenuAction(title: "テキストをコピー", symbol: "doc.on.doc") {
                UIPasteboard.general.string = text
                Toast.show("コピーしました")
            })
        }
        if let url = webURL(of: note) {
            actions.append(MenuAction(title: "リンクをコピー", symbol: "link") {
                UIPasteboard.general.url = url
                Toast.show("リンクをコピーしました")
            })
            actions.append(MenuAction(title: "共有", symbol: "square.and.arrow.up") { [weak self, weak controller] in
                guard let controller else { return }
                self?.share(note, from: controller)
            })
            actions.append(MenuAction(title: "ブラウザで開く", symbol: "safari") {
                UIApplication.shared.open(url)
            })
        }
        guard client != nil else { return [actions] }
        if isAccount(note.user) {
            let delete = MenuAction(title: "削除", symbol: "trash", isDestructive: true) {
                [weak self, weak controller] in
                guard let controller else { return }
                self?.confirmDelete(note, from: controller)
            }
            return [actions, [delete]]
        }
        let user = note.user
        let hide = [
            MenuAction(title: "\(user.acct) をミュート", symbol: "speaker.slash") { [weak self] in
                self?.mute(user)
            },
            MenuAction(title: "\(user.acct) をブロック", symbol: "nosign", isDestructive: true) {
                [weak self, weak controller] in
                guard let self, let controller else { return }
                self.confirmBlock(user, from: controller) { [weak self] in self?.block(user) }
            },
            MenuAction(title: "ノートを通報", symbol: "flag") { [weak self, weak controller] in
                guard let controller else { return }
                self?.report(user, note: note, from: controller)
            },
        ]
        return [actions, hide]
    }

    private func confirmDelete(_ note: Note, from controller: UIViewController) {
        let alert = UIAlertController(title: "ノートを削除しますか？",
                                      message: "リノート・引用・返信も一緒に削除されます。この操作は取り消せません。",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(UIAlertAction(title: "削除", style: .destructive) { [weak self] _ in self?.delete(note) })
        controller.present(alert, animated: true)
    }

    /// Deletes one of the account's notes; the screens take it out once the server has.
    func delete(_ note: Note) {
        guard let client, isAccount(note.user) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task { [weak self] in
            do {
                try await client.deleteNote(note.id)
            } catch {
                if (error as? MisskeyAPIError)?.code != "NO_SUCH_NOTE" {
                    self?.failed(error, fallback: "削除できませんでした")
                    return
                }
            }
            Toast.show("削除しました")
            NotificationCenter.default.post(name: Self.didDeleteNote, object: self, userInfo: ["noteID": note.id])
        }
    }

    /// Mutes the user (no expiry) and takes their notes out of the screens.
    func mute(_ user: User) {
        guard let client else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task { [weak self] in
            do {
                try await client.mute(user.id)
            } catch {
                if (error as? MisskeyAPIError)?.code != "ALREADY_MUTING" {
                    self?.failed(error, fallback: "ミュートできませんでした")
                    return
                }
            }
            Toast.show("ミュートしました")
            self?.didHide(user.id)
        }
    }

    /// Asks first, for blocking also ends the follows both ways; `block` does it.
    func confirmBlock(_ user: User, from controller: UIViewController, block: @escaping () -> Void) {
        let sheet = UIAlertController(title: "\(user.acct) をブロックしますか？",
                                      message: "ブロックすると、お互いのフォローは解除されます。", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "ブロック", style: .destructive) { _ in block() })
        sheet.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        controller.present(sheet, animated: true)
    }

    /// Blocks the user and takes their notes out of the screens.
    func block(_ user: User) {
        guard let client else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task { [weak self] in
            do {
                try await client.block(user.id)
            } catch {
                if (error as? MisskeyAPIError)?.code != "ALREADY_BLOCKING" {
                    self?.failed(error, fallback: "ブロックできませんでした")
                    return
                }
            }
            Toast.show("ブロックしました")
            self?.didHide(user.id)
        }
    }

    func didHide(_ userID: String) {
        NotificationCenter.default.post(name: Self.didHideUser, object: self, userInfo: ["userID": userID])
    }

    func report(_ user: User, note: Note? = nil, from controller: UIViewController) {
        guard let client else { return }
        controller.present(ReportViewController(user: user, note: note, noteURL: note.flatMap(webURL(of:)),
                                                client: client, server: account.host,
                                                onAuthenticationFailure: { [weak self] in
                                                    self?.onAuthenticationFailure?()
                                                }),
                           animated: true)
    }

    func notAvailableYet(_ feature: String) {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        Toast.show("\(feature)はまだ使えません")
    }
}

struct NoteMarks: Sendable {
    let renotes: RenoteMarks
    let bookmarks: BookmarkMarks

    func apply(to note: Note) -> Note {
        bookmarks.apply(to: renotes.apply(to: note))
    }
}
