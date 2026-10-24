import UIKit

final class HeaderView: UIView {
    static let topRowHeight: CGFloat = 44
    static let tabsHeight: CGFloat = 44

    let tabStrip: TabStripView
    let contentView = UIView()

    let accountButton = UIButton(type: .custom)

    /// Beside the side rail, which has the account and the mark: without them, and the
    /// row above the tabs only for a title (X on iPad).
    var usesRail = false {
        didSet {
            guard usesRail != oldValue else { return }
            accountButton.isHidden = usesRail
            logo.isHidden = usesRail
            setNeedsLayout()
        }
    }

    private let hasTitle: Bool
    private let avatar = AvatarView()
    private let logo = UIImageView()
    private let titleLabel = UILabel()
    private let hairline = UIView()
    private static let avatarSize: CGFloat = 32

    init(tabs: [TabStripView.Tab], title: String? = nil) {
        tabStrip = TabStripView(tabs: tabs)
        hasTitle = title != nil
        super.init(frame: .zero)
        backgroundColor = .hibari(.background)
        addSubview(contentView)

        avatar.isUserInteractionEnabled = false
        accountButton.addSubview(avatar)
        accountButton.accessibilityLabel = "メニュー"
        accountButton.accessibilityHint = "アカウントのメニューを開きます"
        accountButton.accessibilityIdentifier = "header.account"
        contentView.addSubview(accountButton)

        if let title {
            titleLabel.text = title
            titleLabel.font = .systemFont(ofSize: 17, weight: .bold)
            titleLabel.textColor = .hibari(.primaryText)
            titleLabel.textAlignment = .center
            titleLabel.accessibilityTraits = .header
            contentView.addSubview(titleLabel)
        } else {
            logo.image = UIImage(named: "BirdMark")?.withRenderingMode(.alwaysTemplate)
            logo.tintColor = .hibari(.primaryText)
            logo.contentMode = .scaleAspectFit
            logo.isAccessibilityElement = true
            logo.accessibilityLabel = "Hibari"
            contentView.addSubview(logo)
        }

        contentView.addSubview(tabStrip)
        hairline.backgroundColor = .hibari(.separator)
        addSubview(hairline)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var shownTopRowHeight: CGFloat { usesRail && !hasTitle ? 0 : Self.topRowHeight }

    /// The rows, without the status bar.
    var height: CGFloat { shownTopRowHeight + Self.tabsHeight }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        contentView.frame = bounds
        let insets = topBarInsets
        accountButton.frame = CGRect(x: insets.left + 10, y: 0, width: 44, height: Self.topRowHeight)
        avatar.frame = CGRect(x: 6, y: (Self.topRowHeight - Self.avatarSize) / 2, width: Self.avatarSize, height: Self.avatarSize)
        logo.frame = CGRect(x: (w - 28) / 2, y: (Self.topRowHeight - 28) / 2, width: 28, height: 28)
        let side = 64 + max(insets.left, insets.right)
        titleLabel.frame = CGRect(x: side, y: 0, width: max(0, w - 2 * side), height: Self.topRowHeight)
        tabStrip.frame = CGRect(x: 0, y: shownTopRowHeight, width: w, height: Self.tabsHeight)
        let scale = window?.screen.scale ?? traitCollection.displayScale
        hairline.frame = CGRect(x: 0, y: bounds.height - 1 / scale, width: w, height: 1 / scale)
    }
}

extension HeaderView {
    func setAvatar(_ url: String?) {
        avatar.setURL(url)
    }
}

final class TabStripView: UIView {
    struct Tab: Equatable {
        enum Mark {
            /// Only the notes with files.
            case media
        }

        var title: String
        /// Before the title.
        var mark: Mark?
        /// Read instead of the title, for what the mark says.
        var accessibilityLabel: String?
    }

    var onSelect: ((Int) -> Void)?

    private let scrollView = UIScrollView()
    private let identifierPrefix: String
    private var tabs: [Tab] = []
    private var labels: [UILabel] = []
    private let indicator = TabIndicator.make()
    private(set) var selectedIndex = 0
    private var progress: CGFloat = 0
    private var userScroll: (offset: CGFloat, progress: CGFloat)?
    private let feedback = UISelectionFeedbackGenerator()

    private static let titlePadding: CGFloat = 22
    private static let font = UIFont.systemFont(ofSize: 16, weight: .bold)
    private static let mediaMark = UIImage(named: "MediaMark")
    private static let markGap: CGFloat = 3
    private static let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width

    convenience init(titles: [String], identifierPrefix: String = "tab") {
        self.init(tabs: titles.map { Tab(title: $0) }, identifierPrefix: identifierPrefix)
    }

    /// Tabs are identified as "<identifierPrefix>.<index>" for accessibility.
    init(tabs: [Tab], identifierPrefix: String = "tab") {
        self.identifierPrefix = identifierPrefix
        super.init(frame: .zero)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.scrollsToTop = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = self
        addSubview(scrollView)
        scrollView.addSubview(indicator)
        setTabs(tabs)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.updateLabels() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Replaces the tabs. `setProgress` says which is selected after it.
    func setTabs(_ tabs: [Tab]) {
        self.tabs = tabs
        labels.forEach { $0.removeFromSuperview() }
        labels = tabs.enumerated().map { index, tab in
            let label = UILabel()
            label.isUserInteractionEnabled = true
            label.accessibilityLabel = tab.accessibilityLabel
            label.accessibilityIdentifier = "\(identifierPrefix).\(index)"
            label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
            scrollView.insertSubview(label, belowSubview: indicator)
            return label
        }
        progress = min(progress, CGFloat(max(0, labels.count - 1)))
        selectedIndex = Int(progress.rounded())
        userScroll = nil
        updateLabels()
        setNeedsLayout()
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard let label = gesture.view as? UILabel, let index = labels.firstIndex(of: label) else { return }
        feedback.selectionChanged()
        onSelect?(index)
    }

    /// Continuous page position from the pager (0 = first tab, 1 = second, ...).
    func setProgress(_ value: CGFloat) {
        progress = max(0, min(CGFloat(labels.count - 1), value))
        let nearest = Int(progress.rounded())
        if nearest != selectedIndex {
            selectedIndex = nearest
            updateLabels()
        }
        layoutIndicator()
        scrollToProgress()
    }

    private func updateLabels() {
        for (index, label) in labels.enumerated() {
            let selected = index == selectedIndex
            let color = UIColor.hibari(selected ? .primaryText : .secondaryText).resolvedColor(with: traitCollection)
            label.attributedText = Self.text(of: tabs[index], color: color)
            label.textAlignment = .center
            label.accessibilityTraits = selected ? [.button, .selected] : .button
        }
    }

    /// The title, after the mark (tinted like it, centered on the letters).
    private static func text(of tab: Tab, color: UIColor) -> NSAttributedString {
        let text = NSMutableAttributedString()
        if tab.mark == .media, let mark = mediaMark {
            let attachment = NSTextAttachment(image: mark.withTintColor(color, renderingMode: .alwaysOriginal))
            let size = mark.size
            attachment.bounds = CGRect(x: 0, y: (font.capHeight - size.height) / 2, width: size.width, height: size.height)
            text.append(NSAttributedString(attachment: attachment))
            // A space narrowed to the gap: an attachment's own kern goes unused.
            text.append(NSAttributedString(string: " ", attributes: [.font: font, .kern: markGap - spaceWidth]))
        }
        text.append(NSAttributedString(string: tab.title, attributes: [.font: font, .foregroundColor: color]))
        return text
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        guard !labels.isEmpty else { return }
        let count = CGFloat(labels.count)
        let textWidths = labels.map { ceil($0.attributedText?.size().width ?? 0) }
        let equal = bounds.width / count
        let widths: [CGFloat]
        if textWidths.allSatisfy({ $0 + 16 <= equal }) {
            widths = Array(repeating: equal, count: labels.count)
        } else {
            let padded = textWidths.map { $0 + 2 * Self.titlePadding }
            let spare = max(0, bounds.width - padded.reduce(0, +)) / count
            widths = padded.map { $0 + spare }
        }
        var x: CGFloat = 0
        for (label, width) in zip(labels, widths) {
            label.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            x += width
        }
        scrollView.contentSize = CGSize(width: x, height: bounds.height)
        layoutIndicator()
        scrollToProgress()
    }

    private func layoutIndicator() {
        guard !labels.isEmpty else { return }
        let lower = Int(progress.rounded(.down))
        let upper = min(labels.count - 1, lower + 1)
        let t = progress - CGFloat(lower)
        let y = TabIndicator.minY(inHeight: bounds.height, scale: traitCollection.displayScale)
        func frame(_ index: Int) -> CGRect {
            let label = labels[index]
            let textWidth = label.intrinsicContentSize.width + 16
            return CGRect(x: label.frame.midX - textWidth / 2, y: y, width: textWidth, height: TabIndicator.height)
        }
        let a = frame(lower)
        let b = frame(upper)
        indicator.frame = CGRect(
            x: a.minX + (b.minX - a.minX) * t, y: a.minY,
            width: a.width + (b.width - a.width) * t, height: a.height)
    }

    private func scrollToProgress() {
        guard !labels.isEmpty, !scrollView.isTracking, !scrollView.isDecelerating else { return }
        let maxOffset = max(0, scrollView.contentSize.width - scrollView.bounds.width)
        func offset(_ index: Int) -> CGFloat {
            min(maxOffset, max(0, labels[index].frame.midX - scrollView.bounds.width / 2))
        }
        let lower = Int(progress.rounded(.down))
        let upper = min(labels.count - 1, lower + 1)
        let t = progress - CGFloat(lower)
        var x = offset(lower) + (offset(upper) - offset(lower)) * t
        if let userScroll {
            let moved = min(1, abs(progress - userScroll.progress))
            x = userScroll.offset + (x - userScroll.offset) * moved
            if moved == 1 { self.userScroll = nil }
        }
        scrollView.contentOffset.x = min(maxOffset, max(0, x))
    }
}

extension TabStripView: UIScrollViewDelegate {
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { userScroll = (scrollView.contentOffset.x, progress) }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        userScroll = (scrollView.contentOffset.x, progress)
    }
}

enum TabIndicator {
    static let height: CGFloat = 2

    @MainActor static func make() -> UIView {
        let view = UIView()
        view.backgroundColor = .hibari(.primaryText)
        view.layer.cornerRadius = height / 2
        return view
    }

    static func minY(inHeight height: CGFloat, scale: CGFloat) -> CGFloat {
        height - 1 / max(1, scale) - Self.height
    }
}
