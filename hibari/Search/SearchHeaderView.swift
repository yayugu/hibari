import UIKit

final class SearchHeaderView: UIView {
    enum Leading {
        case avatar
        case back
    }

    static let rowHeight = HeaderView.topRowHeight
    static let tabsHeight = HeaderView.tabsHeight

    let leadingButton: UIButton
    let field = SearchField()
    let cancelButton = UIButton(type: .system)
    let tabStrip: TabStripView?
    /// The status bar's height: the row sits below it (the background goes under it).
    var topInset: CGFloat = 0 {
        didSet { setNeedsLayout() }
    }

    private let leading: Leading
    private let avatar = AvatarView()
    private let hairline = UIView()
    private(set) var isEditing = false

    private static let avatarSize: CGFloat = 32
    private static let fieldHeight: CGFloat = 38

    /// `tabs`: titles of the tabs under the field (none for the tab's root).
    init(leading: Leading, tabs: [String] = [], tabIdentifierPrefix: String = "search.tab") {
        self.leading = leading
        tabStrip = tabs.isEmpty ? nil : TabStripView(titles: tabs, identifierPrefix: tabIdentifierPrefix)
        switch leading {
        case .avatar:
            leadingButton = UIButton(type: .custom)
            avatar.isUserInteractionEnabled = false
            leadingButton.addSubview(avatar)
            leadingButton.accessibilityLabel = "メニュー"
            leadingButton.accessibilityHint = "アカウントのメニューを開きます"
            leadingButton.accessibilityIdentifier = "search.account"
        case .back:
            leadingButton = ChromeButton.back(identifier: "search.back")
        }
        super.init(frame: .zero)
        backgroundColor = .hibari(.background)
        addSubview(leadingButton)
        addSubview(field)

        cancelButton.setTitle("キャンセル", for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 16)
        cancelButton.tintColor = .hibari(.primaryText)
        cancelButton.alpha = 0
        cancelButton.accessibilityIdentifier = "search.cancel"
        addSubview(cancelButton)

        if let tabStrip { addSubview(tabStrip) }
        hairline.backgroundColor = .hibari(.separator)
        addSubview(hairline)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var height: CGFloat { topInset + Self.rowHeight + (tabStrip == nil ? 0 : Self.tabsHeight) }

    func setAvatar(_ url: String?) {
        avatar.setURL(url)
    }

    func setEditing(_ editing: Bool, animated: Bool) {
        guard editing != isEditing else { return }
        isEditing = editing
        let changes = {
            self.layoutRow()
            self.cancelButton.alpha = editing ? 1 : 0
        }
        if animated {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .curveEaseOut],
                           animations: changes)
        } else {
            changes()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutRow()
        let w = bounds.width
        tabStrip?.frame = CGRect(x: 0, y: topInset + Self.rowHeight, width: w, height: Self.tabsHeight)
        let scale = window?.screen.scale ?? traitCollection.displayScale
        hairline.frame = CGRect(x: 0, y: bounds.height - 1 / scale, width: w, height: 1 / scale)
    }

    private func layoutRow() {
        let w = bounds.width
        let row = CGRect(x: 0, y: topInset, width: w, height: Self.rowHeight)
        let insets = topBarInsets
        let fieldX: CGFloat
        switch leading {
        case .avatar:
            leadingButton.frame = CGRect(x: insets.left + 10, y: row.minY, width: 44, height: row.height)
            avatar.frame = CGRect(x: 6, y: (row.height - Self.avatarSize) / 2, width: Self.avatarSize,
                                  height: Self.avatarSize)
            avatar.layer.cornerRadius = Self.avatarSize / 2
            avatar.clipsToBounds = true
            fieldX = insets.left + 62
        case .back:
            leadingButton.frame = CGRect(x: insets.left + 6, y: row.minY, width: 44, height: row.height)
            fieldX = insets.left + 57
        }
        let trailingX = w - insets.right
        let cancelWidth = ceil(cancelButton.sizeThatFits(row.size).width)
        cancelButton.frame = CGRect(x: trailingX - 16 - cancelWidth + (isEditing ? 0 : cancelWidth + 16 + insets.right),
                                    y: row.minY, width: cancelWidth, height: row.height)
        let fieldMaxX = isEditing ? cancelButton.frame.minX - 12 : trailingX - 16
        field.frame = CGRect(x: fieldX, y: row.minY + (row.height - Self.fieldHeight) / 2,
                             width: max(0, fieldMaxX - fieldX), height: Self.fieldHeight)
    }
}

final class SearchField: UITextField {
    private let icon = UIImageView(image: UIImage(systemName: "magnifyingglass", withConfiguration:
        UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)))

    private static let iconCenterX: CGFloat = 20
    private static let textX: CGFloat = 38

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .hibari(.chipBackground)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        font = .systemFont(ofSize: 17)
        textColor = .hibari(.primaryText)
        tintColor = .hibari(.accent)
        attributedPlaceholder = NSAttributedString(string: "検索", attributes: [
            .foregroundColor: UIColor.hibari(.secondaryText),
        ])
        icon.tintColor = .hibari(.secondaryText)
        icon.contentMode = .center
        addSubview(icon)
        clearButtonMode = .whileEditing
        returnKeyType = .search
        enablesReturnKeyAutomatically = true
        autocapitalizationType = .none
        autocorrectionType = .no
        spellCheckingType = .no
        accessibilityIdentifier = "search.field"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = CGRect(x: Self.iconCenterX - 12, y: 0, width: 24, height: bounds.height)
    }

    private func textArea(_ bounds: CGRect) -> CGRect {
        let clear = clearButtonMode == .never || !isEditing ? 12 : clearButtonRect(forBounds: bounds).width + 8
        return CGRect(x: Self.textX, y: 0, width: max(0, bounds.width - Self.textX - clear), height: bounds.height)
    }

    override func textRect(forBounds bounds: CGRect) -> CGRect { textArea(bounds) }
    override func editingRect(forBounds bounds: CGRect) -> CGRect { textArea(bounds) }
    override func placeholderRect(forBounds bounds: CGRect) -> CGRect { textArea(bounds) }

    override func clearButtonRect(forBounds bounds: CGRect) -> CGRect {
        let rect = super.clearButtonRect(forBounds: bounds)
        return rect.offsetBy(dx: -4, dy: 0)
    }
}
