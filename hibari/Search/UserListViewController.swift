import UIKit

final class UserListViewController: UIViewController {
    let services: NoteServices
    private let source: any UserListSource
    var emptyMessage = "ユーザーが見つかりませんでした"
    var contentInsets: UIEdgeInsets = .zero {
        didSet { applyInsets() }
    }

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let footer = TimelineFooterView()
    private var users: [UserDetailed] = []
    private var ids: Set<String> = []
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
        tableView.separatorColor = .hibari(.separator)
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
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
        let offset = users.count
        Task { [weak self] in
            do {
                let page = try await source.users(offset: offset, limit: Self.pageSize)
                self?.append(page)
            } catch {
                self?.pageFailed(error)
            }
        }
    }

    private func append(_ page: [UserDetailed]) {
        isLoading = false
        let fresh = page.filter { ids.insert($0.user.id).inserted }
        if page.isEmpty { reachedEnd = true }
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
        cell.configure(users[indexPath.row], services: services)
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

final class UserRowCell: UITableViewCell {
    static let reuseIdentifier = "UserRow"

    private let avatar = AvatarView()
    private let nameLabel = UILabel()
    private let acctLabel = UILabel()
    private let bioLabel = UILabel()
    private var profile: UserDetailed?
    private weak var services: NoteServices?

    private static let avatarSize: CGFloat = 44

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .hibari(.background)
        let selection = UIView()
        selection.backgroundColor = .hibari(.chipBackground)
        selectedBackgroundView = selection

        avatar.clipsToBounds = true
        avatar.layer.cornerRadius = Self.avatarSize / 2
        nameLabel.lineBreakMode = .byTruncatingTail
        acctLabel.textColor = .hibari(.secondaryText)
        acctLabel.lineBreakMode = .byTruncatingTail
        bioLabel.numberOfLines = 3
        bioLabel.lineBreakMode = .byTruncatingTail

        let text = UIStackView(arrangedSubviews: [nameLabel, acctLabel, bioLabel])
        text.axis = .vertical
        text.spacing = 2
        text.setCustomSpacing(6, after: acctLabel)
        for view in [avatar, text] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            avatar.widthAnchor.constraint(equalToConstant: Self.avatarSize),
            avatar.heightAnchor.constraint(equalToConstant: Self.avatarSize),
            avatar.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -12),
            text.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 12),
            text.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            text.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            text.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -12),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self]) {
            (self: Self, _) in self.reload()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ profile: UserDetailed, services: NoteServices) {
        self.profile = profile
        self.services = services
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
        let rich = UIKitRichText(resolver: services.engine.emojiResolver, imagePipeline: services.imagePipeline,
                                 palette: .palette(for: ThemeStyle(traitCollection.userInterfaceStyle)),
                                 scale: scale, linkURL: { _ in nil })
        let emojis = EmojiContext.name(of: user)
        let name = rich.build(user.displayName, emojis: emojis, font: Typography.system(size(15), bold: true),
                              color: .primaryText, simple: true)
        let nameText = NSMutableAttributedString(attributedString: name.text)
        nameText.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: nameText.length))
        nameLabel.attributedText = nameText
        acctLabel.font = .systemFont(ofSize: size(14))
        acctLabel.text = user.acct
        var missing = name.missingEmojis
        if let description = profile.description {
            let bio = rich.build(description, emojis: emojis, font: Typography.system(size(14)), color: .primaryText)
            let bioText = NSMutableAttributedString(attributedString: bio.text)
            bioText.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: bioText.length))
            bioLabel.attributedText = bioText
            bioLabel.isHidden = false
            missing += bio.missingEmojis
        } else {
            bioLabel.attributedText = nil
            bioLabel.isHidden = true
        }
        accessibilityLabel = [user.displayName, user.acct, profile.description].compactMap { $0 }.joined(separator: "、")
        loadMissing(missing, for: user.id, imagePipeline: services.imagePipeline)
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
            }
        }
    }
}
