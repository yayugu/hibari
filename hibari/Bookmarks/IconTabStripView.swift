import UIKit

final class IconTabStripView: UIView {
    struct Tab {
        let title: String
        /// A template image.
        let icon: UIImage?
    }

    var onSelect: ((Int) -> Void)?
    /// Moves the tabs' contents up from the middle, off the indicator (X's lists of users).
    var contentBottomInset: CGFloat = 0 {
        didSet { setNeedsLayout() }
    }

    private var buttons: [TabButton] = []
    private let indicator = TabIndicator.make()
    private(set) var selectedIndex = 0
    private var progress: CGFloat = 0
    private let feedback = UISelectionFeedbackGenerator()

    private static let iconSize: CGFloat = 22
    private static let titleSpacing: CGFloat = 8
    private static let font = UIFont.systemFont(ofSize: 16, weight: .bold)

    /// Tabs are identified as "<identifierPrefix>.<index>" for accessibility.
    /// `showsTitles`: every tab has its title, and the selected one its icon too (otherwise
    /// every tab has its icon, and the selected one its title too).
    init(tabs: [Tab], identifierPrefix: String, showsTitles: Bool = false) {
        super.init(frame: .zero)
        for (index, tab) in tabs.enumerated() {
            let button = TabButton(tab: tab, font: Self.font, showsTitle: showsTitles)
            button.accessibilityIdentifier = "\(identifierPrefix).\(index)"
            button.addAction(UIAction { [weak self] _ in
                self?.feedback.selectionChanged()
                self?.onSelect?(index)
            }, for: .touchUpInside)
            addSubview(button)
            buttons.append(button)
        }
        addSubview(indicator)
        updateSelection()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Continuous page position from the pager (0 = first tab, 1 = second, ...).
    func setProgress(_ value: CGFloat) {
        progress = max(0, min(CGFloat(buttons.count - 1), value))
        let nearest = Int(progress.rounded())
        if nearest != selectedIndex {
            selectedIndex = nearest
            updateSelection()
        }
        setNeedsLayout()
        layoutIfNeeded()
    }

    private func updateSelection() {
        for (index, button) in buttons.enumerated() {
            button.isSelected = index == selectedIndex
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !buttons.isEmpty else { return }
        let width = bounds.width / CGFloat(buttons.count)
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: width * CGFloat(index), y: 0, width: width,
                                  height: max(0, bounds.height - contentBottomInset))
            button.reveal = max(0, 1 - abs(progress - CGFloat(index)))
        }
        let lower = Int(progress.rounded(.down))
        let upper = min(buttons.count - 1, lower + 1)
        let t = progress - CGFloat(lower)
        let a = buttons[lower].contentFrame(revealed: true)
        let b = buttons[upper].contentFrame(revealed: true)
        let minX = a.minX + (b.minX - a.minX) * t
        let maxX = a.maxX + (b.maxX - a.maxX) * t
        let y = TabIndicator.minY(inHeight: bounds.height, scale: traitCollection.displayScale)
        indicator.frame = CGRect(x: minX - 8, y: y, width: maxX - minX + 16, height: TabIndicator.height)
    }

    private final class TabButton: UIControl {
        var reveal: CGFloat = 0 {
            didSet { setNeedsLayout() }
        }

        private let iconView = UIImageView()
        private let titleLabel = UILabel()
        private let titleWidth: CGFloat
        private let showsTitle: Bool

        init(tab: Tab, font: UIFont, showsTitle: Bool) {
            titleWidth = ceil((tab.title as NSString).size(withAttributes: [.font: font]).width)
            self.showsTitle = showsTitle
            super.init(frame: .zero)
            iconView.image = tab.icon
            iconView.contentMode = .scaleAspectFit
            addSubview(iconView)
            titleLabel.text = tab.title
            titleLabel.font = font
            addSubview(titleLabel)
            isAccessibilityElement = true
            accessibilityLabel = tab.title
            updateColors()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var isSelected: Bool {
            didSet { updateColors() }
        }

        override var isHighlighted: Bool {
            didSet { alpha = isHighlighted ? 0.5 : 1 }
        }

        private func updateColors() {
            iconView.tintColor = isSelected ? .hibari(.primaryText) : .hibari(.secondaryText)
            titleLabel.textColor = isSelected || !showsTitle ? .hibari(.primaryText) : .hibari(.secondaryText)
            accessibilityTraits = isSelected ? [.button, .selected] : .button
        }

        func contentFrame(revealed: Bool? = nil) -> CGRect {
            let reveal = revealed.map { $0 ? 1 : 0 } ?? self.reveal
            let width = showsTitle
                ? titleWidth + (IconTabStripView.iconSize + IconTabStripView.titleSpacing) * reveal
                : IconTabStripView.iconSize + (IconTabStripView.titleSpacing + titleWidth) * reveal
            let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
            return CGRect(x: frame.minX + ((bounds.width - width) / 2).pixelAligned(scale: scale), y: 0,
                          width: width, height: bounds.height)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let size = IconTabStripView.iconSize
            let x = contentFrame().minX - frame.minX
            iconView.frame = CGRect(x: x, y: ((bounds.height - size) / 2).rounded(), width: size, height: size)
            let titleHeight = ceil(titleLabel.font.lineHeight)
            let titleX = showsTitle
                ? x + (size + IconTabStripView.titleSpacing) * reveal
                : iconView.frame.maxX + IconTabStripView.titleSpacing
            titleLabel.frame = CGRect(x: titleX, y: ((bounds.height - titleHeight) / 2).rounded(), width: titleWidth,
                                      height: titleHeight)
            if showsTitle {
                iconView.alpha = reveal
            } else {
                titleLabel.alpha = reveal
            }
        }
    }
}
