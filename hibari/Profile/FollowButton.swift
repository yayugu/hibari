import UIKit

final class FollowButton: UIControl {
    private(set) var followState: FollowState = .follow
    /// Titles in place of `FollowState.title` (a list's "フォローバックする").
    var titles: [FollowState: String] = [:] {
        didSet { apply(followState) }
    }
    /// As wide as the widest title of these states, whatever the state: buttons in a list
    /// line up, and do not change size when tapped.
    var widthStates: [FollowState] = [] {
        didSet { invalidateIntrinsicContentSize() }
    }
    /// The space on either side of the title. Half the height if nil.
    var titlePadding: CGFloat? {
        didSet { invalidateIntrinsicContentSize() }
    }
    private let label = UILabel()
    private let height: CGFloat
    private let fontSize: CGFloat
    private let overlay: Bool

    init(height: CGFloat, fontSize: CGFloat? = nil, overlay: Bool = false) {
        self.height = height
        self.fontSize = fontSize ?? (height >= 36 ? 15 : 14)
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
        label.text = title(of: state)
        accessibilityLabel = label.text
        applyStyle()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func applyStyle() {
        label.font = .systemFont(ofSize: fontSize, weight: .bold)
        layer.cornerRadius = height / 2
        if overlay && followState != .blocking {
            backgroundColor = UIColor(white: 0, alpha: 0.5)
            label.textColor = .white
            layer.borderWidth = 0
            return
        }
        switch followState {
        case .follow, .followBack:
            backgroundColor = .hibari(.filledButton)
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

    private func title(of state: FollowState) -> String {
        titles[state] ?? state.title
    }

    override var intrinsicContentSize: CGSize {
        let font = label.font ?? .systemFont(ofSize: fontSize, weight: .bold)
        let textWidth = ([followState] + widthStates).map {
            ceil((title(of: $0) as NSString).size(withAttributes: [.font: font]).width)
        }.max() ?? 0
        let width = textWidth + 2 * (titlePadding ?? height / 2)
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
