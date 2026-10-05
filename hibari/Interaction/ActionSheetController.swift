import UIKit

/// A few actions on a card that rises from the bottom of the screen. Tapping outside it or
/// swiping it down closes it.
final class ActionSheetController: UIViewController {
    struct Action {
        let title: String
        let image: UIImage?
        var isEnabled = true
        let perform: () -> Void
    }

    static let iconSize: CGFloat = 22
    private static let inset: CGFloat = 8
    private static let rowHeight: CGFloat = 56

    private let message: String?
    private let actions: [Action]
    private let dimming = UIView()
    private let card = UIView()
    private var rows: [ActionSheetRow] = []
    private let messageLabel = UILabel()
    private var isClosing = false

    init(message: String? = nil, actions: [Action]) {
        self.message = message
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Opens over the top of `controller`'s stack (it animates itself).
    func show(from controller: UIViewController) {
        var top = controller
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        top.present(self, animated: false)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        dimming.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        dimming.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dimmingTapped)))
        view.addSubview(dimming)

        card.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.09, alpha: 1) : .white }
        card.cornerConfiguration = .uniformCorners(radius: .containerConcentric(minimum: 28))
        card.clipsToBounds = true
        card.accessibilityViewIsModal = true
        card.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(cardPanned(_:))))
        view.addSubview(card)

        if let message {
            messageLabel.text = message
            messageLabel.font = .preferredFont(forTextStyle: .footnote)
            messageLabel.textColor = .hibari(.secondaryText)
            messageLabel.numberOfLines = 0
            card.addSubview(messageLabel)
        }
        for (index, action) in actions.enumerated() {
            let row = ActionSheetRow(action: action)
            row.accessibilityIdentifier = "actionSheet.\(index)"
            row.addAction(UIAction { [weak self] _ in self?.close(then: action.perform) }, for: .touchUpInside)
            rows.append(row)
            card.addSubview(row)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        dimming.frame = view.bounds
        let width = view.bounds.width - Self.inset * 2
        let padding: CGFloat = 23
        var y: CGFloat = 19
        if message != nil {
            let height = ceil(messageLabel.sizeThatFits(CGSize(width: width - padding * 2, height: .greatestFiniteMagnitude)).height)
            messageLabel.frame = CGRect(x: padding, y: y + 8, width: width - padding * 2, height: height)
            y += height + 12
        }
        for row in rows {
            row.frame = CGRect(x: 0, y: y, width: width, height: Self.rowHeight)
            y += Self.rowHeight
        }
        y += max(27, view.safeAreaInsets.bottom - Self.inset)
        let transform = card.transform
        card.transform = .identity
        card.frame = CGRect(x: Self.inset, y: view.bounds.height - Self.inset - y, width: width, height: y)
        card.transform = transform
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        view.layoutIfNeeded()
        dimming.alpha = 0
        card.transform = CGAffineTransform(translationX: 0, y: hiddenOffset)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        UIView.animate(springDuration: 0.42, bounce: 0.12, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            self.dimming.alpha = 1
            self.card.transform = .identity
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIAccessibility.post(notification: .screenChanged, argument: message == nil ? rows.first : messageLabel)
    }

    override func accessibilityPerformEscape() -> Bool {
        close()
        return true
    }

    /// Far enough down that the card is out of sight.
    private var hiddenOffset: CGFloat { card.bounds.height + Self.inset + 20 }

    @objc private func dimmingTapped() {
        close()
    }

    /// Slides the card away, then `action` (after the sheet is gone, so it can present).
    private func close(velocity: CGFloat = 0, then action: (() -> Void)? = nil) {
        guard !isClosing else { return }
        isClosing = true
        view.isUserInteractionEnabled = false
        let distance = hiddenOffset - card.transform.ty
        let duration = velocity > 0 ? min(0.25, max(0.12, distance / velocity)) : 0.22
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
            self.dimming.alpha = 0
            self.card.transform = CGAffineTransform(translationX: 0, y: self.hiddenOffset)
        } completion: { _ in
            self.presentingViewController?.dismiss(animated: false) { action?() }
        }
    }

    @objc private func cardPanned(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: view).y
        switch pan.state {
        case .changed:
            // Upward it gives a little and resists.
            let offset = translation >= 0 ? translation : -sqrt(-translation) * 2
            card.transform = CGAffineTransform(translationX: 0, y: offset)
            dimming.alpha = 1 - max(0, offset) / hiddenOffset
        case .ended, .cancelled:
            let velocity = pan.velocity(in: view).y
            if pan.state == .ended && (translation > card.bounds.height * 0.35 || velocity > 700) {
                close(velocity: max(velocity, 0))
            } else {
                UIView.animate(springDuration: 0.35, bounce: 0.2, initialSpringVelocity: 0,
                               options: [.allowUserInteraction, .beginFromCurrentState]) {
                    self.card.transform = .identity
                    self.dimming.alpha = 1
                }
            }
        default:
            break
        }
    }
}

private final class ActionSheetRow: UIControl {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()

    init(action: ActionSheetController.Action) {
        super.init(frame: .zero)
        let color: UIColor = action.isEnabled ? .hibari(.primaryText) : .hibari(.secondaryText)
        iconView.image = action.image?.withRenderingMode(.alwaysTemplate)
        iconView.tintColor = color
        iconView.contentMode = .scaleAspectFit
        addSubview(iconView)
        titleLabel.text = action.title
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = color
        addSubview(titleLabel)
        isEnabled = action.isEnabled
        isAccessibilityElement = true
        accessibilityLabel = action.title
        accessibilityTraits = action.isEnabled ? .button : [.button, .notEnabled]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let iconSize = ActionSheetController.iconSize
        iconView.frame = CGRect(x: 23, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        let x: CGFloat = 63
        titleLabel.frame = CGRect(x: x, y: 0, width: bounds.width - x - 16, height: bounds.height)
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            let color = isHighlighted ? UIColor.hibari(.primaryText).withAlphaComponent(0.08) : .clear
            if isHighlighted {
                backgroundColor = color
            } else {
                UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                    self.backgroundColor = color
                }
            }
        }
    }
}
