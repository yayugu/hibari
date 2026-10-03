import UIKit

extension NoteServices {
    /// The account's relation to a user changed (shown at once, before the server answers,
    /// and back again if it refuses). `userInfo["userID"]` is their id, `userInfo["relation"]`
    /// the `UserDetailed.Relation`.
    static let didChangeRelation = Notification.Name("NoteServices.didChangeRelation")

    /// A follow button tapped: follows at once (a locked account gets a request); asks
    /// before unfollowing, taking a request back or unblocking. `done`: once the server
    /// has made the change.
    func followTapped(_ profile: UserDetailed, from controller: UIViewController, done: (() -> Void)? = nil) {
        let relation = profile.relation
        guard relation.isKnown else { return }
        let user = profile.user
        switch FollowState(relation) {
        case .follow, .followBack:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            let locked = profile.isLocked
            changeRelation(of: user.id, from: relation, update: {
                $0.isFollowing = !locked
                $0.hasPendingFollowRequestFromYou = locked
            }, message: locked ? "フォローリクエストを送りました" : nil, done: done) { try await $0.follow($1) }
        case .following:
            confirm("\(user.acct) のフォローを解除しますか？", action: "フォロー解除", from: controller) { [weak self] in
                self?.changeRelation(of: user.id, from: relation, update: { $0.isFollowing = false }, done: done) {
                    try await $0.unfollow($1)
                }
            }
        case .requested:
            confirm("フォローリクエストを取り消しますか？", action: "取り消す", from: controller) { [weak self] in
                self?.changeRelation(of: user.id, from: relation, update: { $0.hasPendingFollowRequestFromYou = false },
                                     done: done) { try await $0.cancelFollowRequest(to: $1) }
            }
        case .blocking:
            confirmUnblock(user, relation: relation, from: controller, done: done)
        }
    }

    func confirmUnblock(_ user: User, relation: UserDetailed.Relation, from controller: UIViewController,
                        done: (() -> Void)? = nil) {
        confirm("\(user.acct) のブロックを解除しますか？", action: "ブロック解除", destructive: false, from: controller) {
            [weak self] in
            self?.changeRelation(of: user.id, from: relation, update: { $0.isBlocking = false },
                                 message: "ブロックを解除しました", done: done) { try await $0.unblock($1) }
        }
    }

    func confirm(_ title: String, action: String, destructive: Bool = true, from controller: UIViewController,
                 perform: @escaping () -> Void) {
        let sheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: action, style: destructive ? .destructive : .default) { _ in perform() })
        sheet.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        controller.present(sheet, animated: true)
    }

    /// Shows `relation` with `update` made to it on every screen, then asks the server;
    /// shows `relation` again if it refuses. `message`: a toast once it is done. `hides`: the
    /// user's notes go (muted or blocked).
    func changeRelation(of userID: String, from relation: UserDetailed.Relation,
                        update: (inout UserDetailed.Relation) -> Void, message: String? = nil, hides: Bool = false,
                        done: (() -> Void)? = nil,
                        request: @escaping @Sendable (MisskeyClient, String) async throws -> Void) {
        guard let client else { return }
        var changed = relation
        update(&changed)
        relationDidChange(changed, of: userID)
        Task { [weak self] in
            do {
                try await request(client, userID)
                if let message { Toast.show(message) }
                if hides { self?.didHide(userID) }
                done?()
            } catch {
                self?.failed(error, fallback: "変更できませんでした")
                self?.relationDidChange(relation, of: userID)
            }
        }
    }

    private func relationDidChange(_ relation: UserDetailed.Relation, of userID: String) {
        NotificationCenter.default.post(name: Self.didChangeRelation, object: self,
                                        userInfo: ["userID": userID, "relation": relation])
    }
}
