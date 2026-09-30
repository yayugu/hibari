import UIKit

final class FollowButton: UIControl {
    private(set) var followState: FollowState = .follow
    private let label = UILabel()
    private let height: CGFloat
    private let overlay: Bool

    init(height: CGFloat, overlay: Bool = false) {
        self.height = height
        self.overlay = overlay
        super.init(frame: .zero)
        label.textAlignment = .center
        label.isUserInteractionEnabled = false
        addSubview(label)
        layer.cornerCurve = .continuous
        isAccessibilityElement = true
        accessibilityTraits = .button
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.applyStyle()
        }
        apply(.follow)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ state: FollowState) {
        followState = state
        label.text = state.title
        accessibilityLabel = state.title
        applyStyle()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func applyStyle() {
        label.font = .systemFont(ofSize: height >= 36 ? 15 : 14, weight: .bold)
        layer.cornerRadius = height / 2
        if overlay && followState != .blocking {
            backgroundColor = UIColor(white: 0, alpha: 0.5)
            label.textColor = .white
            layer.borderWidth = 0
            return
        }
        switch followState {
        case .follow, .followBack:
            backgroundColor = .hibari(.primaryText)
            label.textColor = .hibari(.background)
            layer.borderWidth = 0
        case .following, .requested:
            backgroundColor = .hibari(.background)
            label.textColor = .hibari(.primaryText)
            layer.borderWidth = 1
            layer.borderColor = UIColor.hibari(.border).resolvedColor(with: traitCollection).cgColor
        case .blocking:
            backgroundColor = Self.blockRed
            label.textColor = .white
            layer.borderWidth = 0
        }
    }

    private static let blockRed = UIColor(red: 0.957, green: 0.129, blue: 0.180, alpha: 1)

    override var intrinsicContentSize: CGSize {
        let width = ceil(label.sizeThatFits(CGSize(width: 400, height: height)).width) + (height >= 36 ? 36 : 32)
        return CGSize(width: max(height * 2.4, width), height: height)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize { intrinsicContentSize }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.7 : 1 }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
    }
}
