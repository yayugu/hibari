import UIKit

final class AccountSwitcherViewController: UIViewController {
    var onSelect: ((Account) -> Void)?
    var onAdd: (() -> Void)?
    var onSignOut: ((Account) -> Void)?

    private let accounts: AccountStore
    private let unread: UnreadNotifications?
    private var rows: [Account] = []
    private var selectedID: String?
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let titleLabel = UILabel()
    private let editButton = UIButton(type: .system)
    private let feedback = UISelectionFeedbackGenerator()

    private static let headerHeight: CGFloat = 56
    private static let rowHeight: CGFloat = 64
    private static let addRowHeight: CGFloat = 52

    init(accounts: AccountStore = .shared, unread: UnreadNotifications? = nil) {
        self.accounts = accounts
        self.unread = unread
        rows = accounts.accounts
        selectedID = accounts.current?.id
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.custom(identifier: .init("accounts")) { [weak self] context in
                min(context.maximumDetentValue, self?.contentHeight ?? 300)
            }]
            sheet.prefersGrabberVisible = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var contentHeight: CGFloat {
        Self.headerHeight + CGFloat(rows.count) * Self.rowHeight + Self.addRowHeight + 8
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .hibari(.background)
        view.accessibilityIdentifier = "accountSwitcher"

        titleLabel.text = "アカウント"
        titleLabel.font = .systemFont(ofSize: 17, weight: .bold)
        titleLabel.textColor = .hibari(.primaryText)
        titleLabel.textAlignment = .center
        titleLabel.accessibilityTraits = .header
        view.addSubview(titleLabel)

        editButton.tintColor = .hibari(.primaryText)
        editButton.titleLabel?.font = .systemFont(ofSize: 17)
        editButton.accessibilityIdentifier = "accountSwitcher.edit"
        editButton.addAction(UIAction { [weak self] _ in self?.toggleEditing() }, for: .touchUpInside)
        view.addSubview(editButton)

        tableView.backgroundColor = .hibari(.background)
        tableView.separatorStyle = .none
        tableView.alwaysBounceVertical = false
        tableView.allowsSelectionDuringEditing = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(AccountCell.self, forCellReuseIdentifier: AccountCell.reuseIdentifier)
        tableView.register(AddAccountCell.self, forCellReuseIdentifier: AddAccountCell.reuseIdentifier)
        view.addSubview(tableView)

        NotificationCenter.default.addObserver(self, selector: #selector(accountsDidChange),
                                               name: AccountStore.didChange, object: accounts)
        if let unread {
            NotificationCenter.default.addObserver(self, selector: #selector(unreadDidChange),
                                                   name: UnreadNotifications.didChange, object: unread)
        }
        tableView.reloadData()
        updateEditButton()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        titleLabel.frame = CGRect(x: 80, y: 8, width: bounds.width - 160, height: Self.headerHeight - 8)
        let editWidth = editButton.sizeThatFits(CGSize(width: 120, height: 44)).width
        editButton.frame = CGRect(x: 16, y: 8 + (Self.headerHeight - 8 - 44) / 2, width: editWidth, height: 44)
        tableView.frame = CGRect(x: 0, y: Self.headerHeight, width: bounds.width, height: bounds.height - Self.headerHeight)
    }

    @objc private func accountsDidChange() {
        let old = rows.map(\.id)
        rows = accounts.accounts
        selectedID = accounts.current?.id
        let new = Set(rows.map(\.id))
        let removed = old.indices.filter { !new.contains(old[$0]) }
        if !removed.isEmpty, old.filter(new.contains) == rows.map(\.id) {
            tableView.deleteRows(at: removed.map { IndexPath(row: $0, section: 0) }, with: .fade)
            for case let cell as AccountCell in tableView.visibleCells {
                guard let row = tableView.indexPath(for: cell)?.row, rows.indices.contains(row) else { continue }
                cell.setChecked(rows[row].id == selectedID, animated: true)
            }
        } else {
            tableView.reloadData()
        }
        if rows.isEmpty, tableView.isEditing { toggleEditing() }
        sheetPresentationController?.animateChanges {
            sheetPresentationController?.invalidateDetents()
        }
    }

    @objc private func unreadDidChange() {
        for case let cell as AccountCell in tableView.visibleCells {
            guard let row = tableView.indexPath(for: cell)?.row, rows.indices.contains(row) else { continue }
            cell.setUnread(showsUnread(rows[row]))
        }
    }

    private func showsUnread(_ account: Account) -> Bool {
        account.id != accounts.current?.id && unread?.hasUnread(account) == true
    }

    private func toggleEditing() {
        tableView.setEditing(!tableView.isEditing, animated: true)
        updateEditButton()
    }

    private func updateEditButton() {
        editButton.setTitle(tableView.isEditing ? "完了" : "編集", for: .normal)
        editButton.titleLabel?.font = .systemFont(ofSize: 17, weight: tableView.isEditing ? .semibold : .regular)
        view.setNeedsLayout()
    }

    private func select(_ account: Account) {
        guard account.id != selectedID else {
            dismiss(animated: true)
            return
        }
        feedback.selectionChanged()
        let previous = rows.firstIndex { $0.id == selectedID }
        selectedID = account.id
        let changed = ([previous, rows.firstIndex { $0.id == account.id }].compactMap { $0 })
        for row in changed {
            (tableView.cellForRow(at: IndexPath(row: row, section: 0)) as? AccountCell)?
                .setChecked(rows[row].id == selectedID, animated: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.onSelect?(account)
        }
    }
}

extension AccountSwitcherViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? rows.count : 1
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        indexPath.section == 0 ? Self.rowHeight : Self.addRowHeight
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard indexPath.section == 0 else {
            return tableView.dequeueReusableCell(withIdentifier: AddAccountCell.reuseIdentifier, for: indexPath)
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: AccountCell.reuseIdentifier, for: indexPath) as! AccountCell
        let account = rows[indexPath.row]
        cell.configure(account, checked: account.id == selectedID, unread: showsUnread(account))
        cell.accessibilityIdentifier = "accountSwitcher.\(account.acct)"
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            select(rows[indexPath.row])
        } else {
            onAdd?()
        }
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        indexPath.section == 0
    }

    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        indexPath.section == 0 ? .delete : .none
    }

    /// Also behind 編集's red minus. No full swipe: signing back in takes a trip to the server.
    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 0 else { return nil }
        let account = rows[indexPath.row]
        let signOut = UIContextualAction(style: .destructive, title: "ログアウト") { [weak self] _, _, done in
            self?.onSignOut?(account)
            done(true)
        }
        let configuration = UISwipeActionsConfiguration(actions: [signOut])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
}

private final class AccountCell: UITableViewCell {
    static let reuseIdentifier = "account"

    private let avatar = AvatarView()
    private let dot = UnreadDot()
    private let nameLabel = AccountNameLabel()
    private let acctLabel = UILabel()
    private let check = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
    private var accountLabel = ""

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .hibari(.background)
        let selected = UIView()
        selected.backgroundColor = .hibari(.chipBackground)
        selectedBackgroundView = selected
        contentView.addSubview(avatar)
        contentView.addSubview(dot)
        contentView.addSubview(nameLabel)
        acctLabel.font = .systemFont(ofSize: 15)
        acctLabel.textColor = .hibari(.secondaryText)
        acctLabel.lineBreakMode = .byTruncatingMiddle
        contentView.addSubview(acctLabel)
        check.tintColor = .hibari(.accent)
        check.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        contentView.addSubview(check)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ account: Account, checked: Bool, unread: Bool) {
        avatar.setURL(account.avatarUrl)
        nameLabel.configure(account, font: .systemFont(ofSize: 17, weight: .bold))
        acctLabel.text = account.acct
        accountLabel = "\(account.displayName)、\(account.acct)"
        setChecked(checked, animated: false)
        setUnread(unread)
    }

    func setUnread(_ unread: Bool) {
        dot.isHidden = !unread
        accessibilityLabel = unread ? "\(accountLabel)、未読の通知あり" : accountLabel
    }

    func setChecked(_ checked: Bool, animated: Bool) {
        accessibilityTraits = checked ? [.button, .selected] : .button
        guard animated else {
            check.alpha = checked ? 1 : 0
            check.transform = .identity
            return
        }
        if checked { check.transform = CGAffineTransform(scaleX: 0.5, y: 0.5) }
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0) {
            self.check.alpha = checked ? 1 : 0
            self.check.transform = .identity
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        let avatarSize: CGFloat = 40
        avatar.frame = CGRect(x: 12, y: (bounds.height - avatarSize) / 2, width: avatarSize, height: avatarSize)
        dot.place(atTopRightOf: avatar.frame)
        let checkSize = check.intrinsicContentSize
        check.frame = CGRect(x: bounds.width - 16 - checkSize.width, y: (bounds.height - checkSize.height) / 2,
                             width: checkSize.width, height: checkSize.height)
        let textX = avatar.frame.maxX + 12
        let textWidth = max(0, check.frame.minX - 12 - textX)
        nameLabel.frame = CGRect(x: textX, y: bounds.height / 2 - 21, width: textWidth, height: 22)
        acctLabel.frame = CGRect(x: textX, y: bounds.height / 2 + 1, width: textWidth, height: 20)
    }
}

private final class AddAccountCell: UITableViewCell {
    static let reuseIdentifier = "add"

    private let label = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .hibari(.background)
        let selected = UIView()
        selected.backgroundColor = .hibari(.chipBackground)
        selectedBackgroundView = selected
        label.text = "アカウントを追加"
        label.font = .systemFont(ofSize: 17)
        label.textColor = .hibari(.accent)
        contentView.addSubview(label)
        accessibilityIdentifier = "accountSwitcher.add"
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = contentView.bounds.inset(by: UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12))
    }
}
