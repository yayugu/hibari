import UIKit

@MainActor
enum Toast {
    private static weak var current: UIView?
    private static weak var important: UIView?

    /// In the app's key window.
    static func show(_ message: String) {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        show(message, in: window)
    }

    /// `important`: ordinary messages that follow do not cover it (an account signed out,
    /// over the errors of its screens still coming in).
    static func show(_ message: String, in window: UIWindow?, important: Bool = false) {
        guard let window, important || Self.important == nil else { return }
        current?.removeFromSuperview()

        let label = PaddedLabel()
        label.text = message
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .white
        label.numberOfLines = 2
        label.textAlignment = .center
        label.backgroundColor = UIColor.hibari(.accent)
        label.layer.cornerRadius = 12
        label.layer.masksToBounds = true
        label.accessibilityIdentifier = "toast"
        let maxWidth = window.bounds.width - 32
        let size = label.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        let width = min(maxWidth, size.width)
        let bottom = window.bounds.height - window.safeAreaInsets.bottom - BottomBarView.barHeight - 16
        label.frame = CGRect(x: (window.bounds.width - width) / 2, y: bottom - size.height, width: width, height: size.height)
        window.addSubview(label)
        current = label
        if important { Self.important = label }
        UIAccessibility.post(notification: .announcement, argument: message)

        label.alpha = 0
        label.transform = CGAffineTransform(translationX: 0, y: 16)
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
            label.alpha = 1
            label.transform = .identity
        }
        UIView.animate(withDuration: 0.25, delay: 2.5, options: [.beginFromCurrentState]) {
            label.alpha = 0
        } completion: { _ in
            label.removeFromSuperview()
        }
    }
}

private final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fitted = super.sizeThatFits(CGSize(width: size.width - insets.left - insets.right, height: size.height))
        return CGSize(width: ceil(fitted.width) + insets.left + insets.right,
                      height: ceil(fitted.height) + insets.top + insets.bottom)
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }
}
