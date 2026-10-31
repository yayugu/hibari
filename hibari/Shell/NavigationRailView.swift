import UIKit

/// The side rail has the back button (in iPhone Duo's column of bars, where the system puts
/// it, at the top): the screens leave theirs out.
struct BackButtonInRailTrait: UITraitDefinition {
    static let defaultValue = false
}

extension UITraitCollection {
    var hasBackButtonInRail: Bool { self[BackButtonInRailTrait.self] }
}

extension UIMutableTraits {
    var hasBackButtonInRail: Bool {
        get { self[BackButtonInRailTrait.self] }
        set { self[BackButtonInRailTrait.self] = newValue }
    }
}

/// The tab bar and the side drawer in one column along a side of the window, like X on
/// iPad: the tabs, bookmarks, the account (its profile), a menu with the rest, and the
/// compose button at the bottom. Where the window is wide (iPad, iPhone Duo open), and
/// where the system puts its bars at the side (iPhone Duo: the column of the status bar,
/// below it).
final class NavigationRailView: UIView {
    static let minimumWidth: CGFloat = 76

    /// A tab was tapped (also the one shown).
    var onSelect: ((RootViewController.Tab) -> Void)?
    /// Home or the avatar was long-pressed, or "アカウント" chosen in the menu: the account list.
    var onShowAccounts: (() -> Void)? {
        didSet {
            for press in longPresses { press.isEnabled = onShowAccounts != nil }
            updateMenu()
        }
    }
    var onShowBookmarks: (() -> Void)?
    var onShowLists: ((ListsViewController.Kind) -> Void)? {
        didSet { updateMenu() }
    }
    var onShowSettings: (() -> Void)?
    /// The back button was tapped.
    var onBack: (() -> Void)?
    let composeButton = ComposeButton()

    /// The window's edge it's at: the hairline goes on the other side, against the content.
    var edge: UIRectEdge = .left {
        didSet { setNeedsLayout() }
    }
    /// In the column the system keeps for its bars (iPhone Duo): lined up in its lane,
    /// below the status bar and in line with it, and no mark.
    var isInBarColumn = false {
        didSet { setNeedsLayout() }
    }
    /// The back button at the top (where iPhone Duo puts it in its bars).
    private(set) var showsBack = false

    private enum Item: CaseIterable {
        case home, search, notifications, bookmarks, profile, more

        var tab: RootViewController.Tab? {
            switch self {
            case .home: .home
            case .search: .search
            case .notifications: .notifications
            case .profile: .profile
            case .bookmarks, .more: nil
            }
        }

        var label: String {
            switch self {
            case .home: "ホーム"
            case .search: "検索"
            case .notifications: "通知"
            case .bookmarks: "ブックマーク"
            case .profile: "プロフィール"
            case .more: "その他"
            }
        }

        var identifier: String { "rail.\(self)" }

        func icon(selected: Bool) -> UIImage? {
            let name: String
            switch self {
            case .home: name = selected ? "TabHomeSelected" : "TabHome"
            case .search: name = selected ? "TabSearchSelected" : "TabSearch"
            case .notifications: name = selected ? "TabBellSelected" : "TabBell"
            case .bookmarks: name = "Bookmark"
            case .profile: name = "Profile"
            case .more:
                return UIImage(systemName: "ellipsis.circle",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .regular))
            }
            return UIImage(named: name)?.withRenderingMode(.alwaysTemplate)
        }

        /// Which go into the menu first when the column is too short (an island growing
        /// on iPhone Duo, a short window). Home and the menu always stay.
        static let overflowOrder: [Item] = [.bookmarks, .profile, .notifications, .search]
    }

    private let hairline = UIView()
    private let logo = UIImageView()
    private let backButton = ChromeButton.plain("arrow.left", label: "戻る", identifier: "rail.back")
    private var buttons: [Item: UIButton] = [:]
    private let avatarButton = RailAvatarButton()
    private let homeBadge = TabBadge()
    private let notificationsBadge = TabBadge()
    private var selected = RootViewController.Tab.home
    private var overflow: [Item] = []
    private let longPresses = [UILongPressGestureRecognizer(), UILongPressGestureRecognizer()]
    private let feedback = UIImpactFeedbackGenerator(style: .light)
    private let longPressFeedback = UIImpactFeedbackGenerator(style: .medium)

    private static let minimumItemHeight: CGFloat = 48
    private static let maximumItemHeight: CGFloat = 64
    private static let logoSize: CGFloat = 30
    /// The width of the system's bar items, for its lane.
    private static let laneExtent: CGFloat = 44
    /// Between the back button and the tabs.
    private static let backSpacing: CGFloat = 8

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .hibari(.background)
        accessibilityIdentifier = "rail"
        hairline.backgroundColor = .hibari(.separator)
        addSubview(hairline)

        logo.image = UIImage(named: "BirdMark")?.withRenderingMode(.alwaysTemplate)
        logo.tintColor = .hibari(.primaryText)
        logo.contentMode = .scaleAspectFit
        logo.isAccessibilityElement = true
        logo.accessibilityLabel = "Hibari"
        addSubview(logo)
        backButton.isPointerInteractionEnabled = true
        backButton.isHidden = true
        backButton.alpha = 0
        backButton.accessibilityElementsHidden = true
        backButton.addAction(UIAction { [weak self] _ in self?.onBack?() }, for: .touchUpInside)
        addSubview(backButton)

        for item in Item.allCases {
            let button: UIButton = item == .profile ? avatarButton : UIButton(type: .system)
            button.tintColor = .hibari(.primaryText)
            button.isPointerInteractionEnabled = true
            button.accessibilityLabel = item.label
            button.accessibilityIdentifier = item.identifier
            if item == .more {
                button.showsMenuAsPrimaryAction = true
                button.preferredMenuElementOrder = .fixed
            } else {
                button.addAction(UIAction { [weak self] _ in self?.tapped(item) }, for: .touchUpInside)
            }
            addSubview(button)
            buttons[item] = button
        }
        buttons[.home]?.addSubview(homeBadge)
        buttons[.notifications]?.addSubview(notificationsBadge)
        for (press, item) in zip(longPresses, [Item.home, .profile]) {
            press.minimumPressDuration = 0.4
            press.isEnabled = false
            press.addTarget(self, action: #selector(longPressed(_:)))
            buttons[item]?.addGestureRecognizer(press)
        }
        addSubview(composeButton)
        composeButton.accessibilityIdentifier = "rail.compose"
        updateButtons()
        updateMenu()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func select(_ tab: RootViewController.Tab) {
        guard tab != selected else { return }
        selected = tab
        updateButtons()
    }

    func setBadge(_ value: TabBadge.Value?, on tab: RootViewController.Tab) {
        let badge: TabBadge
        switch tab {
        case .home: badge = homeBadge
        case .notifications: badge = notificationsBadge
        case .search, .profile: return
        }
        let button = tab == .home ? buttons[.home] : buttons[.notifications]
        button?.accessibilityValue = badge.show(value)
        setNeedsLayout()
    }

    /// Called inside the push's or pop's animation, if any.
    func setShowsBack(_ shows: Bool) {
        guard shows != showsBack else { return }
        showsBack = shows
        backButton.isHidden = false
        backButton.alpha = shows ? 1 : 0
        backButton.accessibilityElementsHidden = !shows
        setNeedsLayout()
        layoutIfNeeded()
    }

    func setAccount(_ account: Account) {
        avatarButton.avatar.setURL(account.avatarUrl)
        avatarButton.accessibilityValue = account.acct
    }

    private func tapped(_ item: Item) {
        feedback.impactOccurred()
        if let tab = item.tab {
            onSelect?(tab)
        } else if item == .bookmarks {
            onShowBookmarks?()
        }
    }

    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        longPressFeedback.impactOccurred()
        onShowAccounts?()
    }

    private func updateButtons() {
        for (item, button) in buttons where item != .profile {
            let isSelected = item.tab == selected
            button.setImage(item.icon(selected: isSelected), for: .normal)
            button.accessibilityTraits = isSelected ? [.button, .selected] : .button
        }
        avatarButton.isSelected = selected == .profile
        avatarButton.accessibilityTraits = selected == .profile ? [.button, .selected] : .button
    }

    /// The items that don't fit, the lists, antennas and channels, then the account list and
    /// the settings.
    private func updateMenu() {
        let moved = overflow.map { item in
            UIAction(title: item.label, image: item.icon(selected: false)) { [weak self] _ in self?.tapped(item) }
        }
        let kinds: [ListsViewController.Kind] = [.lists, .antennas, .channels]
        let lists: [UIMenuElement] = onShowLists == nil ? [] : kinds.map { kind in
            UIAction(title: kind.title, image: UIImage(named: kind.icon)?.withRenderingMode(.alwaysTemplate)) {
                [weak self] _ in self?.onShowLists?(kind)
            }
        }
        var rest: [UIMenuElement] = []
        if onShowAccounts != nil {
            rest.append(UIAction(title: "アカウント", subtitle: "切り替え・追加",
                                 image: UIImage(systemName: "person.2")) { [weak self] _ in
                self?.onShowAccounts?()
            })
        }
        rest.append(UIAction(title: "設定", image: UIImage(systemName: "gearshape")) { [weak self] _ in
            self?.onShowSettings?()
        })
        buttons[.more]?.menu = UIMenu(children: [UIMenu(options: .displayInline, children: moved),
                                                 UIMenu(options: .displayInline, children: lists),
                                                 UIMenu(options: .displayInline, children: rest)])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        let scale = traitCollection.displayScale
        hairline.frame = CGRect(x: edge == .left ? w - 1 / scale : 0, y: 0, width: 1 / scale, height: bounds.height)

        // In the system's column, the lane it puts its own bar in: below the status bar, in
        // line with it and the camera. Elsewhere the safe area, below the window's controls
        // on iPad (they sit over the top leading corner).
        var lane = edgeInsets(for: .safeArea(cornerAdaptation: .vertical))
        var midX = w / 2
        if #available(iOS 27.1, *), isInBarColumn {
            lane = edgeInsets(for: .bar(onEdge: edge, extent: Self.laneExtent))
            midX = (lane.left + (w - lane.left - lane.right) / 2).rounded()
        }
        let spans = reservedFrames().map { $0.minY...$0.maxY }.sorted { $0.lowerBound < $1.lowerBound }
        func clearing(_ y: CGFloat, height: CGFloat, upward: Bool = false) -> CGFloat {
            var y = y
            while let span = spans.first(where: { $0.lowerBound < y + height && $0.upperBound > y }) {
                y = upward ? span.lowerBound - height : span.upperBound
            }
            return y
        }

        let size = ComposeButton.size
        let composeY = clearing(bounds.height - lane.bottom - 16 - size, height: size, upward: true)
        composeButton.frame = CGRect(x: (midX - size / 2).rounded(), y: composeY, width: size, height: size)

        let start = lane.top + 4
        let top = clearing(start, height: Self.minimumItemHeight)
        let end = composeY - 12
        let backRoom = showsBack ? Self.backSpacing : 0
        let room = end - top - backRoom - spans.reduce(0) { sum, span in
            sum + max(0, min(span.upperBound, end) - max(span.lowerBound, top))
        }
        var shown = Item.allCases
        // The mark only where nothing of the system's sits above the items.
        var showsLogo = !isInBarColumn && !showsBack && top == start
        func slots() -> Int { shown.count + (showsLogo ? 1 : 0) + (showsBack ? 1 : 0) }
        func fits() -> Bool { CGFloat(slots()) * Self.minimumItemHeight <= room }
        if !fits() { showsLogo = false }
        for item in Item.overflowOrder where !fits() {
            shown.removeAll { $0 == item }
        }
        let height = max(Self.minimumItemHeight,
                         min(Self.maximumItemHeight, (room / CGFloat(max(1, slots()))).rounded(.down)))

        var y = top
        logo.isHidden = !showsLogo
        if showsLogo {
            logo.frame = CGRect(x: (midX - Self.logoSize / 2).rounded(), y: y + (height - Self.logoSize) / 2,
                                width: Self.logoSize, height: Self.logoSize)
            y += height
        }
        // Where it goes even while hidden, so it fades in and out in place.
        backButton.frame = CGRect(x: (midX - w / 2).rounded(), y: y, width: w, height: height)
        if showsBack { y += height + Self.backSpacing }
        for item in Item.allCases {
            guard let button = buttons[item] else { continue }
            y = clearing(y, height: height)
            let isShown = shown.contains(item) && (y + height <= end || item == .home || item == .more)
            button.isHidden = !isShown
            guard isShown else { continue }
            button.frame = CGRect(x: (midX - w / 2).rounded(), y: y, width: w, height: height)
            y += height
        }
        let center = CGPoint(x: w / 2, y: height / 2)
        homeBadge.place(atTopRightOfIconAt: center)
        notificationsBadge.place(atTopRightOfIconAt: center)

        let overflow = Item.allCases.filter { buttons[$0]?.isHidden == true }
        if overflow != self.overflow {
            self.overflow = overflow
            updateMenu()
        }
    }

    /// The parts of the column the system keeps for itself: the status bar and the camera
    /// (iPhone Duo), and the fold while the device is half open.
    private func reservedFrames() -> [CGRect] {
        guard #available(iOS 27.1, *) else { return [] }
        let regions = reservedRegions(kind: .occlusion) + reservedRegions(kind: .division)
        return regions.filter { $0.isActive && $0.frame.intersects(bounds) }.map(\.frame)
    }
}

/// The account's avatar, a ring around it while its profile is shown.
private final class RailAvatarButton: UIButton {
    let avatar = AvatarView()
    private let ring = UIView()

    private static let size: CGFloat = 28

    override init(frame: CGRect) {
        super.init(frame: frame)
        ring.isUserInteractionEnabled = false
        ring.layer.borderWidth = 2
        ring.isHidden = true
        addSubview(ring)
        avatar.isUserInteractionEnabled = false
        avatar.layer.cornerRadius = Self.size / 2
        avatar.clipsToBounds = true
        addSubview(avatar)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.updateRing() }
        updateRing()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isSelected: Bool {
        didSet { ring.isHidden = !isSelected }
    }

    override var isHighlighted: Bool {
        didSet { avatar.alpha = isHighlighted ? 0.5 : 1 }
    }

    private func updateRing() {
        ring.layer.borderColor = UIColor.hibari(.primaryText).resolvedColor(with: traitCollection).cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = Self.size
        avatar.frame = CGRect(x: ((bounds.width - size) / 2).rounded(), y: ((bounds.height - size) / 2).rounded(),
                              width: size, height: size)
        ring.frame = avatar.frame.insetBy(dx: -4, dy: -4)
        ring.layer.cornerRadius = ring.bounds.width / 2
    }
}
