import UIKit

final class DrawerViewController: UIViewController {
    /// Tapped the avatar of another account.
    var onSelect: ((Account) -> Void)?
    /// Tapped "⋯".
    var onShowAccounts: (() -> Void)?
    /// Tapped the current account (its avatar or name), or "プロフィール": its profile.
    var onShowProfile: (() -> Void)?
    /// Tapped the following or followers count of the current account.
    var onShowFollows: ((FollowList) -> Void)?
    /// Tapped "ブックマーク".
    var onShowBookmarks: (() -> Void)?
    /// Tapped "設定".
    var onShowSettings: (() -> Void)?

    private let accounts: AccountStore
    private let unread: UnreadNotifications?
    private let header = UIView()
    private let avatar = AvatarView()
    private let nameLabel = AccountNameLabel()
    private let acctLabel = UILabel()
    private let counts = FollowCountsView()
    private var otherButtons: [AccountAvatarButton] = []
    private let moreButton = UIButton(type: .system)
    private let moreDot = UnreadDot()
    private let profileButton = ProfileAreaButton()
    private var menuButtons: [UIButton] = []
    private let settingsButton = UIButton(type: .system)
    private var shown: [Account] = []
    private let feedback = UISelectionFeedbackGenerator()

    private static let inset: CGFloat = 32
    private static let avatarSize: CGFloat = 40
    private static let otherAvatarSize: CGFloat = 26
    private static let slotWidth: CGFloat = 44
    private static let maxOthers = 2
    private static let menuRowHeight: CGFloat = 54

    init(accounts: AccountStore = .shared, unread: UnreadNotifications? = nil) {
        self.accounts = accounts
        self.unread = unread
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .hibari(.background)
        view.accessibilityIdentifier = "drawer"
        view.addSubview(header)

        avatar.isAccessibilityElement = false
        header.addSubview(avatar)
        nameLabel.accessibilityIdentifier = "drawer.name"
        header.addSubview(nameLabel)
        acctLabel.font = .systemFont(ofSize: 15)
        acctLabel.textColor = .hibari(.secondaryText)
        acctLabel.lineBreakMode = .byTruncatingMiddle
        acctLabel.accessibilityIdentifier = "drawer.acct"
        header.addSubview(acctLabel)
        counts.onSelect = { [weak self] list in self?.onShowFollows?(list) }
        header.addSubview(counts)
        profileButton.dimmed = [avatar, nameLabel, acctLabel]
        profileButton.isAccessibilityElement = true
        profileButton.accessibilityTraits = .button
        profileButton.accessibilityLabel = "プロフィール"
        profileButton.accessibilityIdentifier = "drawer.profile"
        profileButton.addAction(UIAction { [weak self] _ in self?.onShowProfile?() }, for: .touchUpInside)
        header.insertSubview(profileButton, at: 0)

        moreButton.setImage(UIImage(systemName: "ellipsis.circle",
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)),
                            for: .normal)
        moreButton.tintColor = .hibari(.primaryText)
        moreButton.accessibilityLabel = "アカウント"
        moreButton.accessibilityHint = "アカウントを切り替え、追加します"
        moreButton.accessibilityIdentifier = "drawer.accounts"
        moreButton.addAction(UIAction { [weak self] _ in self?.onShowAccounts?() }, for: .touchUpInside)
        header.addSubview(moreButton)
        moreButton.addSubview(moreDot)

        let menu: [(title: String, icon: String, identifier: String, action: () -> Void)] = [
            ("プロフィール", "Profile", "drawer.menu.profile", { [weak self] in self?.onShowProfile?() }),
            ("ブックマーク", "Bookmark", "drawer.menu.bookmarks", { [weak self] in self?.onShowBookmarks?() }),
        ]
        for item in menu {
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(named: item.icon)?.withRenderingMode(.alwaysTemplate)
            configuration.imagePadding = 26
            var title = AttributedString(item.title)
            title.font = .systemFont(ofSize: 20, weight: .bold)
            configuration.attributedTitle = title
            configuration.baseForegroundColor = .hibari(.primaryText)
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Self.inset, bottom: 0,
                                                                  trailing: Self.inset)
            let button = UIButton(configuration: configuration)
            button.contentHorizontalAlignment = .leading
            button.accessibilityIdentifier = item.identifier
            button.addAction(UIAction { _ in item.action() }, for: .touchUpInside)
            view.addSubview(button)
            menuButtons.append(button)
        }

        var settings = UIButton.Configuration.plain()
        settings.image = UIImage(systemName: "gearshape", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16))
        settings.imagePadding = 22
        var title = AttributedString("設定")
        title.font = .systemFont(ofSize: 17)
        settings.attributedTitle = title
        settings.baseForegroundColor = .hibari(.primaryText)
        settings.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Self.inset, bottom: 0, trailing: Self.inset)
        settingsButton.configuration = settings
        settingsButton.contentHorizontalAlignment = .leading
        settingsButton.accessibilityIdentifier = "drawer.settings"
        settingsButton.addAction(UIAction { [weak self] _ in self?.onShowSettings?() }, for: .touchUpInside)
        view.addSubview(settingsButton)

        NotificationCenter.default.addObserver(self, selector: #selector(accountsDidChange),
                                               name: AccountStore.didChange, object: accounts)
        if let unread {
            NotificationCenter.default.addObserver(self, selector: #selector(updateDots),
                                                   name: UnreadNotifications.didChange, object: unread)
        }
        reload(animated: false)
    }

    @objc private func updateDots() {
        for button in otherButtons {
            button.hasUnread = button.account.map { unread?.hasUnread($0) ?? false } ?? false
        }
        let listed = Set(shown.map(\.id))
        moreDot.isHidden = !accounts.others.contains { !listed.contains($0.id) && unread?.hasUnread($0) == true }
        moreButton.accessibilityValue = moreDot.isHidden ? nil : "未読あり"
    }

    @objc private func accountsDidChange() {
        reload(animated: true)
    }

    private func reload(animated: Bool) {
        guard let current = accounts.current else { return }
        let others = Array(accounts.others.prefix(Self.maxOthers))
        let switched = shown.first?.id != current.id
        shown = [current] + others
        let update = { [self] in
            avatar.setURL(current.avatarUrl)
            nameLabel.configure(current, font: .systemFont(ofSize: 18, weight: .bold))
            acctLabel.text = current.acct
            counts.configure(following: current.followingCount, followers: current.followersCount, size: 15,
                             identifier: "drawer.counts")
            counts.isHidden = counts.isEmpty
            while otherButtons.count < others.count {
                let button = AccountAvatarButton(size: Self.otherAvatarSize)
                button.addAction(UIAction { [weak self, weak button] _ in
                    guard let self, let account = button?.account else { return }
                    self.feedback.selectionChanged()
                    self.onSelect?(account)
                }, for: .touchUpInside)
                header.addSubview(button)
                otherButtons.append(button)
            }
            for (index, button) in otherButtons.enumerated() {
                button.isHidden = index >= others.count
                if index < others.count { button.account = others[index] }
            }
            updateDots()
            view.setNeedsLayout()
            view.layoutIfNeeded()
        }
        if animated && switched && view.window != nil {
            UIView.transition(with: header, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction],
                              animations: update)
        } else {
            update()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width
        let top = view.safeAreaInsets.top + 12
        let inset = Self.inset
        let contentWidth = width - inset * 2

        avatar.frame = CGRect(x: inset, y: top, width: Self.avatarSize, height: Self.avatarSize)
        var slotMaxX = width - inset + (Self.slotWidth - 24) / 2
        let slotY = avatar.frame.midY - Self.slotWidth / 2
        moreButton.frame = CGRect(x: slotMaxX - Self.slotWidth, y: slotY, width: Self.slotWidth, height: Self.slotWidth)
        moreDot.place(atTopRightOf: CGRect(x: (Self.slotWidth - 24) / 2, y: (Self.slotWidth - 24) / 2,
                                           width: 24, height: 24))
        for button in otherButtons.reversed() where !button.isHidden {
            slotMaxX -= Self.slotWidth
            button.frame = CGRect(x: slotMaxX - Self.slotWidth, y: slotY, width: Self.slotWidth, height: Self.slotWidth)
        }

        let nameHeight = ceil(nameLabel.sizeThatFits(CGSize(width: contentWidth, height: 100)).height)
        nameLabel.frame = CGRect(x: inset, y: avatar.frame.maxY + 10, width: contentWidth, height: nameHeight)
        acctLabel.frame = CGRect(x: inset, y: nameLabel.frame.maxY + 2, width: contentWidth, height: 20)
        counts.frame = CGRect(x: inset, y: acctLabel.frame.maxY + 12, width: contentWidth, height: 20)
        counts.frame.size.width = counts.sizeThatFits(CGSize(width: contentWidth, height: 20)).width
        let bottom = counts.isHidden ? acctLabel.frame.maxY : counts.frame.maxY
        header.frame = CGRect(x: 0, y: 0, width: width, height: bottom + 16)
        profileButton.frame = CGRect(x: 0, y: top - 8, width: width, height: acctLabel.frame.maxY + 16 - top)
        for (index, button) in menuButtons.enumerated() {
            button.frame = CGRect(x: 0, y: header.frame.maxY + 4 + Self.menuRowHeight * CGFloat(index), width: width,
                                  height: Self.menuRowHeight)
        }
        settingsButton.frame = CGRect(x: 0, y: view.bounds.height - view.safeAreaInsets.bottom - 56, width: width, height: 48)
    }
}

private final class ProfileAreaButton: UIControl {
    var dimmed: [UIView] = []

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            for view in dimmed { view.alpha = isHighlighted ? 0.5 : 1 }
        }
    }
}

final class AccountAvatarButton: UIControl {
    var account: Account? {
        didSet {
            avatar.setURL(account?.avatarUrl)
            accessibilityLabel = account.map { "\($0.acct) に切り替え" }
            accessibilityIdentifier = account.map { "drawer.\($0.acct)" }
        }
    }

    var hasUnread = false {
        didSet {
            dot.isHidden = !hasUnread
            accessibilityValue = hasUnread ? "未読あり" : nil
        }
    }

    private let avatar = AvatarView()
    private let dot = UnreadDot()
    private let size: CGFloat

    init(size: CGFloat) {
        self.size = size
        super.init(frame: .zero)
        avatar.isUserInteractionEnabled = false
        addSubview(avatar)
        addSubview(dot)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { avatar.alpha = isHighlighted ? 0.5 : 1 }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        avatar.frame = CGRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
        dot.place(atTopRightOf: avatar.frame)
    }
}
