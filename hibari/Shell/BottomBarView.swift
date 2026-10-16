import UIKit

final class BottomBarView: UIView {
    static let barHeight: CGFloat = 49

    /// A tab was tapped (also the one shown).
    var onSelect: ((Int) -> Void)?
    var onLongPressHome: (() -> Void)? {
        didSet { homeLongPress.isEnabled = onLongPressHome != nil }
    }

    private let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private let tint = UIView()
    private let hairline = UIView()
    private var buttons: [UIButton] = []
    private var badges: [TabBadge] = []
    private var selectedIndex = 0
    private let feedback = UIImpactFeedbackGenerator(style: .light)
    private let longPressFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let homeLongPress = UILongPressGestureRecognizer()

    private let items: [(icon: String, selectedIcon: String, label: String)] = [
        ("TabHome", "TabHomeSelected", "ホーム"),
        ("TabSearch", "TabSearchSelected", "検索"),
        ("TabBell", "TabBellSelected", "通知"),
        ("TabProfile", "TabProfileSelected", "プロフィール"),
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        tint.backgroundColor = UIColor.hibari(.background).withAlphaComponent(0.72)
        background.contentView.addSubview(tint)
        addSubview(background)
        hairline.backgroundColor = .hibari(.separator)
        addSubview(hairline)
        for (index, item) in items.enumerated() {
            let button = UIButton(type: .system)
            button.tintColor = .hibari(.primaryText)
            button.accessibilityLabel = item.label
            button.accessibilityIdentifier = "bottomBar.\(index)"
            button.addAction(UIAction { [weak self] _ in self?.tapped(index) }, for: .touchUpInside)
            addSubview(button)
            buttons.append(button)

            let badge = TabBadge()
            button.addSubview(badge)
            badges.append(badge)
        }
        homeLongPress.minimumPressDuration = 0.4
        homeLongPress.isEnabled = false
        homeLongPress.addTarget(self, action: #selector(homeLongPressed(_:)))
        buttons[0].addGestureRecognizer(homeLongPress)
        updateButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setBadge(_ value: TabBadge.Value?, at index: Int) {
        guard badges.indices.contains(index) else { return }
        buttons[index].accessibilityValue = badges[index].show(value)
        setNeedsLayout()
    }

    @objc private func homeLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        longPressFeedback.impactOccurred()
        onLongPressHome?()
    }

    private func tapped(_ index: Int) {
        feedback.impactOccurred()
        onSelect?(index)
    }

    func select(_ index: Int) {
        guard index != selectedIndex else { return }
        selectedIndex = index
        updateButtons()
    }

    private func updateButtons() {
        for (index, button) in buttons.enumerated() {
            let item = items[index]
            let name = index == selectedIndex ? item.selectedIcon : item.icon
            button.setImage(UIImage(named: name)?.withRenderingMode(.alwaysTemplate), for: .normal)
            button.accessibilityTraits = index == selectedIndex ? [.button, .selected] : .button
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        background.frame = bounds
        tint.frame = background.bounds
        let scale = window?.screen.scale ?? traitCollection.displayScale
        hairline.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1 / scale)
        let width = bounds.width / CGFloat(buttons.count)
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: CGFloat(index) * width, y: 0, width: width, height: Self.barHeight)
            badges[index].place(atTopRightOfIconAt: CGPoint(x: width / 2, y: Self.barHeight / 2))
        }
    }
}

/// The count or the dot on a tab's icon.
final class TabBadge: UILabel {
    enum Value {
        case dot
        case count(Int)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        isUserInteractionEnabled = false
        textAlignment = .center
        font = .systemFont(ofSize: 10, weight: .bold)
        textColor = .white
        backgroundColor = .hibari(.accent)
        layer.borderWidth = 2
        layer.masksToBounds = true
        layer.borderColor = UIColor.hibari(.background).cgColor
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.layer.borderColor = UIColor.hibari(.background).resolvedColor(with: self.traitCollection).cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows `value` (nothing for nil or a count of 0). Returns what VoiceOver says of the tab.
    func show(_ value: Value?) -> String? {
        switch value {
        case .none:
            isHidden = true
            return nil
        case .dot:
            text = nil
            isHidden = false
            return "未読あり"
        case .count(let count):
            guard count > 0 else {
                isHidden = true
                return nil
            }
            let displayedCount = count > 99 ? "99+" : String(count)
            text = displayedCount
            isHidden = false
            return "未読 \(displayedCount) 件"
        }
    }

    /// Over the top right corner of the 24pt icon centered at `center`.
    func place(atTopRightOfIconAt center: CGPoint) {
        let isCount = text != nil
        let width: CGFloat = isCount ? max(20, (intrinsicContentSize.width + 10).rounded(.up)) : 10
        let height: CGFloat = isCount ? 20 : 10
        frame = CGRect(x: center.x + 7, y: center.y - (isCount ? 19.5 : 16.5), width: width, height: height)
        layer.cornerRadius = height / 2
    }
}

final class ComposeButton: UIControl {
    static let size: CGFloat = 56

    private let face = UIView()
    private let icon = UIImageView()
    private let feedback = UIImpactFeedbackGenerator(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        face.isUserInteractionEnabled = false
        face.backgroundColor = .hibari(.accent)
        face.layer.cornerRadius = Self.size / 2
        face.layer.shadowColor = UIColor.black.cgColor
        face.layer.shadowOpacity = 0.25
        face.layer.shadowRadius = 8
        face.layer.shadowOffset = CGSize(width: 0, height: 3)
        addSubview(face)
        icon.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold))
        icon.tintColor = .white
        icon.contentMode = .center
        face.addSubview(icon)
        accessibilityLabel = "ノートを書く"
        accessibilityTraits = .button
        isAccessibilityElement = true
        addAction(UIAction { [weak self] _ in self?.feedback.impactOccurred() }, for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // bounds + center rather than frame: `face` may be scaled.
        face.bounds = bounds
        face.center = CGPoint(x: bounds.midX, y: bounds.midY)
        icon.frame = face.bounds
        // An explicit path keeps the shadow from forcing an offscreen pass.
        face.layer.shadowPath = UIBezierPath(ovalIn: face.bounds).cgPath
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.icon.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.86, y: 0.86) : .identity
                self.face.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.92, y: 0.92) : .identity
            }
        }
    }
}
