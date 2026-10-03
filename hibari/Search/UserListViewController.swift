import UIKit

final class UserListViewController: UIViewController {
    let services: NoteServices
    private let source: any UserListSource
    var emptyMessage = "ユーザーが見つかりませんでした"
    /// Each user's follow button, and whether they follow the account.
    var showsRelations = false
    var contentInsets: UIEdgeInsets = .zero {
        didSet { applyInsets() }
    }

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let footer = TimelineFooterView()
    private var users: [UserDetailed] = []
    private var ids: Set<String> = []
    private var cursor: String?
    private var reachedEnd = false
    private var isLoading = false
    private var failed = false

    private static let pageSize = 30
    private static let loadMoreThreshold = 5

    init(source: any UserListSource, services: NoteServices) {
        self.source = source
        self.services = services
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .hibari(.background)
        tableView.backgroundColor = .hibari(.background)
        tableView.separatorStyle = .none
        tableView.register(UserRowCell.self, forCellReuseIdentifier: UserRowCell.reuseIdentifier)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.automaticallyAdjustsScrollIndicatorInsets = false
        tableView.keyboardDismissMode = .onDrag
        tableView.accessibilityIdentifier = "userList"
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(tableView)
        footer.emptyMessage = emptyMessage
        footer.onRetry = { [weak self] in self?.loadNextPage() }
        NotificationCenter.default.addObserver(self, selector: #selector(relationDidChange(_:)),
                                               name: NoteServices.didChangeRelation, object: services)
        applyInsets()
        setFooter(.loading)
        loadNextPage()
    }

    private func applyInsets() {
        guard isViewLoaded else { return }
        tableView.contentInset = contentInsets
        tableView.verticalScrollIndicatorInsets = contentInsets
    }

    func scrollToTop(animated: Bool) {
        tableView.setContentOffset(CGPoint(x: 0, y: -tableView.adjustedContentInset.top), animated: animated)
    }

    var scrollView: UIScrollView { tableView }

    private func loadNextPage() {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        failed = false
        setFooter(.loading)
        let source = self.source
        let cursor = self.cursor
        Task { [weak self] in
            do {
                let page = try await source.users(from: cursor, limit: Self.pageSize)
                self?.append(page)
            } catch {
                self?.pageFailed(error)
            }
        }
    }

    private func append(_ page: UserListPage) {
        isLoading = false
        let fresh = page.users.filter { ids.insert($0.user.id).inserted }
        cursor = page.next
        if page.next == nil { reachedEnd = true }
        let range = users.count..<(users.count + fresh.count)
        users += fresh
        if range.lowerBound == 0 {
            tableView.reloadData()
        } else if !range.isEmpty {
            UIView.performWithoutAnimation {
                tableView.insertRows(at: range.map { IndexPath(row: $0, section: 0) }, with: .none)
            }
        }
        setFooter(reachedEnd ? (users.isEmpty ? .empty : .hidden) : .loading)
        if !reachedEnd, fresh.isEmpty { loadNextPage() }
    }

    private func pageFailed(_ error: any Error) {
        isLoading = false
        failed = true
        if (error as? MisskeyAPIError)?.isAuthenticationFailure == true {
            services.onAuthenticationFailure?()
        }
        setFooter(.failed((error as? LocalizedError)?.errorDescription ?? "読み込めませんでした"))
    }

    @objc private func relationDidChange(_ notification: Notification) {
        guard let userID = notification.userInfo?["userID"] as? String,
              let relation = notification.userInfo?["relation"] as? UserDetailed.Relation,
              let row = users.firstIndex(where: { $0.user.id == userID }), users[row].relation != relation
        else { return }
        users[row].relation = relation
        tableView.reconfigureRows(at: [IndexPath(row: row, section: 0)])
    }

    private func followTapped(_ userID: String) {
        guard let profile = users.first(where: { $0.user.id == userID }) else { return }
        services.followTapped(profile, from: self)
    }

    private func setFooter(_ state: TimelineFooterView.State) {
        footer.frame.size = CGSize(width: tableView.bounds.width, height: state.height)
        footer.apply(state)
        tableView.tableFooterView = footer
    }
}

extension UserListViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        users.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: UserRowCell.reuseIdentifier, for: indexPath) as! UserRowCell
        cell.configure(users[indexPath.row], services: services, showsRelation: showsRelations)
        cell.onFollow = { [weak self] userID in self?.followTapped(userID) }
        cell.onResize = { [weak self] in
            UIView.performWithoutAnimation { self?.tableView.performBatchUpdates(nil) }
        }
        return cell
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if !failed, indexPath.row + Self.loadMoreThreshold >= users.count { loadNextPage() }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        services.openUser(users[indexPath.row].user, from: self)
    }
}

/// A user, as X lists them: the avatar, the name, the username, whether they follow the
/// account, and the whole bio below, with the follow button at the top right.
final class UserRowCell: UITableViewCell {
    static let reuseIdentifier = "UserRow"

    private let avatar = AvatarView()
    private let nameLabel = UILabel()
    private let acctLabel = UILabel()
    private let followsYouLabel = BadgeLabel()
    private let bioLabel = UILabel()
    private let followButton = FollowButton(height: 32, fontSize: 13)
    private var profile: UserDetailed?
    private var showsRelation = false
    private weak var services: NoteServices?
    /// The follow button tapped, with the user's id.
    var onFollow: ((String) -> Void)?
    /// The row changed height (emojis came in).
    var onResize: (() -> Void)?

    private enum Metrics {
        static let top: CGFloat = 14
        static let bottom: CGFloat = 16
        static let leading: CGFloat = 12
        static let trailing: CGFloat = 12
        static let buttonTrailing: CGFloat = 9
        static let avatarSize: CGFloat = 42
        static let avatarSpacing: CGFloat = 11
        static let buttonSpacing: CGFloat = 12
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .hibari(.background)
        let selection = UIView()
        selection.backgroundColor = .hibari(.chipBackground)
        selectedBackgroundView = selection

        avatar.clipsToBounds = true
        avatar.layer.cornerRadius = Metrics.avatarSize / 2
        nameLabel.lineBreakMode = .byTruncatingTail
        acctLabel.textColor = .hibari(.secondaryText)
        acctLabel.lineBreakMode = .byTruncatingTail
        followsYouLabel.text = "フォローされています"
        bioLabel.numberOfLines = 0
        followButton.titles = [.followBack: "フォローバックする"]
        followButton.widthStates = [.follow, .followBack, .following, .requested]
        followButton.titlePadding = 18
        followButton.accessibilityIdentifier = "userList.follow"
        followButton.addAction(UIAction { [weak self] _ in
            guard let self, let profile = self.profile else { return }
            self.onFollow?(profile.user.id)
        }, for: .touchUpInside)
        for view in [avatar, nameLabel, acctLabel, followsYouLabel, bioLabel, followButton] as [UIView] {
            contentView.addSubview(view)
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self]) {
            (self: Self, _) in self.reload()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ profile: UserDetailed, services: NoteServices, showsRelation: Bool) {
        self.profile = profile
        self.services = services
        self.showsRelation = showsRelation
        avatar.setURL(profile.user.avatarUrl)
        reload()
    }

    private func size(_ base: CGFloat) -> CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(for: base, compatibleWith: traitCollection).rounded()
    }

    private func reload() {
        guard let profile, let services else { return }
        let user = profile.user
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        let palette = Palette.palette(for: ThemeStyle(traitCollection.userInterfaceStyle))
        let rich = UIKitRichText(resolver: services.engine.emojiResolver, imagePipeline: services.imagePipeline,
                                 palette: palette, scale: scale, linkURL: { _ in nil })
        let emojis = EmojiContext.name(of: user)
        let name = rich.build(user.displayName, emojis: emojis, font: Typography.system(size(15), bold: true),
                              color: .primaryText, simple: true)
        let nameText = NSMutableAttributedString(attributedString: name.text)
        nameText.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: nameText.length))
        nameLabel.attributedText = nameText
        acctLabel.font = .systemFont(ofSize: size(15))
        acctLabel.text = user.acct
        let relation = profile.relation
        followsYouLabel.font = .systemFont(ofSize: size(14))
        followsYouLabel.isHidden = !showsRelation || !relation.isFollowed
        followButton.isHidden = !showsRelation || !relation.isKnown || services.isAccount(user)
        followButton.apply(FollowState(relation))
        var missing = name.missingEmojis
        if let description = profile.description {
            let bio = rich.build(description, emojis: emojis, font: Typography.system(size(15)), color: .primaryText,
                                 lineHeight: (size(15) * 1.4).rounded())
            // Links are plain text here, and lines break at any character, like X's lists.
            let bioText = NSMutableAttributedString(attributedString: bio.text)
            let whole = NSRange(location: 0, length: bioText.length)
            let primary = UIColor(cgColor: palette[.primaryText])
            bioText.enumerateAttribute(TextAttribute.link, in: whole) { value, range, _ in
                if value != nil { bioText.addAttribute(.foregroundColor, value: primary, range: range) }
            }
            bioText.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
                guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
                style.lineBreakStrategy = []
                bioText.addAttribute(.paragraphStyle, value: style, range: range)
            }
            bioLabel.attributedText = bioText
            bioLabel.isHidden = false
            missing += bio.missingEmojis
        } else {
            bioLabel.attributedText = nil
            bioLabel.isHidden = true
        }
        accessibilityLabel = [user.displayName, user.acct, followsYouLabel.isHidden ? nil : "フォローされています",
                              profile.description].compactMap { $0 }.joined(separator: "、")
        accessibilityCustomActions = followButton.isHidden ? nil : [
            UIAccessibilityCustomAction(name: FollowState(relation).title) { [weak self] _ in
                self?.onFollow?(user.id)
                return true
            },
        ]
        setNeedsLayout()
        loadMissing(missing, for: user.id, imagePipeline: services.imagePipeline)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layout(width: contentView.bounds.width, apply: true)
    }

    override func systemLayoutSizeFitting(_ targetSize: CGSize, withHorizontalFittingPriority horizontal: UILayoutPriority,
                                          verticalFittingPriority vertical: UILayoutPriority) -> CGSize {
        CGSize(width: targetSize.width, height: layout(width: targetSize.width, apply: false))
    }

    /// Places the views at `width`; returns the row's height.
    @discardableResult
    private func layout(width: CGFloat, apply: Bool) -> CGFloat {
        let m = Metrics.self
        let textX = m.leading + m.avatarSize + m.avatarSpacing
        var headerMaxX = width - m.trailing
        var buttonBottom: CGFloat = 0
        if !followButton.isHidden {
            let size = followButton.intrinsicContentSize
            let frame = CGRect(x: width - m.buttonTrailing - size.width, y: m.top, width: size.width,
                               height: size.height)
            if apply { followButton.frame = frame }
            headerMaxX = frame.minX - m.buttonSpacing
            buttonBottom = frame.maxY
        }
        let headerWidth = max(0, headerMaxX - textX)
        func line(_ label: UILabel, y: CGFloat, width: CGFloat) -> CGRect {
            let size = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            let frame = CGRect(x: textX, y: y, width: min(width, ceil(size.width)), height: ceil(size.height))
            if apply { label.frame = frame }
            return frame
        }
        if apply { avatar.frame = CGRect(x: m.leading, y: m.top, width: m.avatarSize, height: m.avatarSize) }
        var y = m.top - 2
        y = line(nameLabel, y: y, width: headerWidth).maxY + 2
        y = line(acctLabel, y: y, width: headerWidth).maxY
        if !followsYouLabel.isHidden {
            y = line(followsYouLabel, y: y + 3.5, width: headerWidth).maxY
        }
        if !bioLabel.isHidden {
            y = max(y, buttonBottom)
            y = line(bioLabel, y: y + 2, width: width - m.trailing - textX).maxY
        }
        return ceil(max(y, m.top + m.avatarSize, buttonBottom) + m.bottom)
    }

    private func loadMissing(_ requests: [ImageRequest], for userID: String, imagePipeline: ImagePipeline) {
        guard !requests.isEmpty else { return }
        let group = DispatchGroup()
        for request in requests {
            group.enter()
            imagePipeline.load(request) { _ in group.leave() }
        }
        group.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.profile?.user.id == userID,
                      requests.contains(where: { imagePipeline.cachedImage(for: $0) != nil })
                else { return }
                self.reload()
                self.onResize?()
            }
        }
    }
}
