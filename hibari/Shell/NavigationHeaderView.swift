import UIKit

final class NavigationHeaderView: UIView {
    static let rowHeight = HeaderView.topRowHeight
    static let tabsHeight = HeaderView.tabsHeight

    let rowView = UIView()

    private let backButton: UIButton
    private let titleLabel = UILabel()
    private let trailingButton: UIButton?
    private let tabs: UIView?
    private let hairline = UIView()

    /// `identifier`: the screen's (the back arrow is "<identifier>.back").
    init(title: String, identifier: String, trailingButton: UIButton? = nil, tabs: UIView? = nil) {
        backButton = ChromeButton.back(identifier: "\(identifier).back")
        self.trailingButton = trailingButton
        self.tabs = tabs
        super.init(frame: .zero)
        backgroundColor = .hibari(.background)
        addSubview(rowView)
        rowView.addSubview(backButton)

        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 17, weight: .bold)
        titleLabel.textColor = .hibari(.primaryText)
        titleLabel.textAlignment = .center
        titleLabel.accessibilityTraits = .header
        rowView.addSubview(titleLabel)
        if let trailingButton { rowView.addSubview(trailingButton) }

        if let tabs { addSubview(tabs) }
        hairline.backgroundColor = .hibari(.separator)
        addSubview(hairline)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The row and the tabs, without the status bar.
    var height: CGFloat { Self.rowHeight + (tabs == nil ? 0 : Self.tabsHeight) }

    /// Puts the bar at the top of `controller`'s view, behind the status bar too. The
    /// screen's safe area starts below it, as it would below UIKit's bar.
    func install(in controller: UIViewController) {
        let view: UIView = controller.view
        controller.additionalSafeAreaInsets.top = height
        translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(self)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: view.leadingAnchor),
            trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topAnchor.constraint(equalTo: view.topAnchor),
            bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        let tabsHeight = tabs == nil ? 0 : Self.tabsHeight
        rowView.frame = CGRect(x: 0, y: bounds.height - tabsHeight - Self.rowHeight, width: w, height: Self.rowHeight)
        backButton.frame = CGRect(x: 6, y: 0, width: 44, height: Self.rowHeight)
        trailingButton?.frame = CGRect(x: w - 6 - 44, y: 0, width: 44, height: Self.rowHeight)
        titleLabel.frame = CGRect(x: 64, y: 0, width: max(0, w - 128), height: Self.rowHeight)
        tabs?.frame = CGRect(x: 0, y: bounds.height - tabsHeight, width: w, height: tabsHeight)
        let scale = window?.screen.scale ?? traitCollection.displayScale
        hairline.frame = CGRect(x: 0, y: bounds.height - 1 / scale, width: w, height: 1 / scale)
    }
}

@MainActor
enum ChromeButton {
    static func plain(_ symbol: String, label: String, identifier: String) -> UIButton {
        let button = UIButton(type: .custom)
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(
            pointSize: 20, weight: .medium)), for: .normal)
        button.tintColor = .hibari(.primaryText)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        return button
    }

    static func overlay(_ symbol: String, pointSize: CGFloat = 15, label: String, identifier: String) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(
            pointSize: pointSize, weight: .semibold))
        configuration.baseBackgroundColor = UIColor(white: 0, alpha: 0.5)
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        configuration.contentInsets = .zero
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        return button
    }

    static func back(identifier: String, overlay: Bool = false) -> UIButton {
        let button = overlay
            ? self.overlay("arrow.left", label: "戻る", identifier: identifier)
            : plain("arrow.left", label: "戻る", identifier: identifier)
        button.addAction(UIAction { action in
            guard let sender = action.sender as? UIResponder else { return }
            let screen = sequence(first: sender, next: \.next).lazy.compactMap { $0 as? UIViewController }.first
            screen?.navigationController?.popViewController(animated: true)
        }, for: .touchUpInside)
        return button
    }
}
