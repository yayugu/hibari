import UIKit

final class AvatarView: UIImageView {
    private var url: String?
    private var loaded: ImageRequest?
    private var task: ImageTask?
    private let imagePipeline: ImagePipeline

    init(imagePipeline: ImagePipeline = .shared) {
        self.imagePipeline = imagePipeline
        super.init(frame: .zero)
        contentMode = .scaleAspectFill
        tintColor = .hibari(.secondaryText)
        showPlaceholder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func request(url: String, size: CGSize, scale: CGFloat) -> ImageRequest {
        ImageRequest(url: url, size: size, scale: scale, shape: .circle)
    }

    func setURL(_ url: String?) {
        guard url != self.url else { return }
        self.url = url
        loaded = nil
        task?.cancel()
        showPlaceholder()
        loadIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        loadIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        loadIfNeeded()
    }

    private func showPlaceholder() {
        image = UIImage(systemName: "person.crop.circle.fill")
    }

    private func loadIfNeeded() {
        guard let window, let url, bounds.width > 0 else { return }
        let scale = window.screen.scale
        let request = Self.request(url: url, size: bounds.size, scale: scale)
        guard request != loaded else { return }
        loaded = request
        task?.cancel()
        if let image = imagePipeline.cachedImage(for: request) {
            self.image = UIImage(cgImage: image, scale: scale, orientation: .up)
            return
        }
        task = imagePipeline.load(request) { [weak self] image in
            guard let self, self.loaded == request, let image else { return }
            self.image = UIImage(cgImage: image, scale: scale, orientation: .up)
        }
    }
}

final class AccountNameLabel: UILabel {
    private var account: Account?
    private var nameFont: UIFont = .systemFont(ofSize: 17, weight: .bold)
    private var reloadPending = false
    private var provisional: Set<String> = []
    private let imagePipeline: ImagePipeline

    init(imagePipeline: ImagePipeline = .shared) {
        self.imagePipeline = imagePipeline
        super.init(frame: .zero)
        lineBreakMode = .byTruncatingTail
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) { (self: Self, _) in
            self.reload()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(mediaSizesDidChange),
                                               name: ImagePipeline.mediaSizesDidChange, object: imagePipeline)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ account: Account, font: UIFont) {
        guard account != self.account || font != nameFont else { return }
        self.account = account
        nameFont = font
        reload()
    }

    private func reload() {
        guard let account else { return }
        accessibilityLabel = account.displayName
        let emojis = account.nameEmojis ?? [:]
        guard !emojis.isEmpty else {
            attributedText = nil
            font = nameFont
            textColor = .hibari(.primaryText)
            text = account.displayName
            return
        }
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        let rich = UIKitRichText(resolver: EmojiResolver(localEmojis: emojis, mediaProxy: nil),
                                 imagePipeline: imagePipeline,
                                 palette: .palette(for: ThemeStyle(traitCollection.userInterfaceStyle)),
                                 scale: scale, linkURL: { _ in nil })
        let result = rich.build(account.displayName, emojis: EmojiContext(host: nil, remoteEmojis: [:]),
                                font: nameFont as CTFont, color: .primaryText, simple: true)
        let text = NSMutableAttributedString(attributedString: result.text)
        text.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: text.length))
        attributedText = text
        provisional = result.provisionalEmojis
        loadMissing(result.missingEmojis)
    }

    private func loadMissing(_ requests: [ImageRequest]) {
        guard !requests.isEmpty, !reloadPending else { return }
        reloadPending = true
        let group = DispatchGroup()
        for request in requests {
            group.enter()
            imagePipeline.load(request) { _ in group.leave() }
        }
        group.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reloadPending = false
                if requests.contains(where: { self.imagePipeline.cachedImage(for: $0) != nil }) {
                    self.reload()
                }
            }
        }
    }

    @objc private func mediaSizesDidChange() {
        guard provisional.contains(where: { imagePipeline.mediaSize(for: $0) != .unknown }) else { return }
        reload()
    }
}

/// "2,570 フォロー中   1,885 フォロワー", counts in the primary color. Each opens its list.
final class FollowCountsView: UIView {
    var onSelect: ((FollowList) -> Void)?

    private let following = CountButton(list: .following)
    private let followers = CountButton(list: .followers)

    private static let spacing: CGFloat = 14

    override init(frame: CGRect) {
        super.init(frame: frame)
        for button in [following, followers] {
            button.addAction(UIAction { [weak self, list = button.list] _ in self?.onSelect?(list) }, for: .touchUpInside)
            addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Neither count (the user hides both).
    var isEmpty: Bool { following.isHidden && followers.isHidden }

    /// `identifier`: the counts are "<identifier>.following" and "<identifier>.followers".
    func configure(following followingCount: Int?, followers followersCount: Int?, size: CGFloat, identifier: String) {
        following.configure(count: followingCount, size: size, identifier: "\(identifier).following")
        followers.configure(count: followersCount, size: size, identifier: "\(identifier).followers")
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let shown = [following, followers].filter { !$0.isHidden }.map { $0.sizeThatFits(size) }
        let width = shown.map(\.width).reduce(0, +) + Self.spacing * CGFloat(max(0, shown.count - 1))
        return CGSize(width: min(size.width, width), height: shown.map(\.height).max() ?? 0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var x: CGFloat = 0
        for button in [following, followers] where !button.isHidden {
            let size = button.sizeThatFits(bounds.size)
            button.frame = CGRect(x: x, y: (bounds.height - size.height) / 2, width: min(size.width, bounds.width - x),
                                  height: size.height)
            x += size.width + Self.spacing
        }
    }

    /// The counts take touches a little around them.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -6, dy: -10).contains(point)
    }

    private final class CountButton: UIControl {
        let list: FollowList
        private let label = UILabel()

        init(list: FollowList) {
            self.list = list
            super.init(frame: .zero)
            label.lineBreakMode = .byTruncatingTail
            label.isUserInteractionEnabled = false
            addSubview(label)
            isAccessibilityElement = true
            accessibilityTraits = .button
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        func configure(count: Int?, size: CGFloat, identifier: String) {
            isHidden = count == nil
            accessibilityIdentifier = identifier
            guard let count else { return }
            let text = NSMutableAttributedString(string: count.formatted(), attributes: [
                .font: UIFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: UIColor.hibari(.primaryText),
            ])
            text.append(NSAttributedString(string: " \(list.title)", attributes: [
                .font: UIFont.systemFont(ofSize: size), .foregroundColor: UIColor.hibari(.secondaryText),
            ]))
            label.attributedText = text
            accessibilityLabel = "\(count.formatted()) \(list.title)"
        }

        override func sizeThatFits(_ size: CGSize) -> CGSize {
            let fitted = label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: size.height))
            return CGSize(width: ceil(fitted.width), height: ceil(fitted.height))
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            label.frame = bounds
        }

        override var isHighlighted: Bool {
            didSet { label.alpha = isHighlighted ? 0.5 : 1 }
        }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            bounds.insetBy(dx: -6, dy: -10).contains(point)
        }
    }
}

final class UnreadDot: UIView {
    static let size: CGFloat = 12

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        isUserInteractionEnabled = false
        backgroundColor = .hibari(.accent)
        layer.cornerRadius = Self.size / 2
        layer.borderWidth = 2
        layer.borderColor = UIColor.hibari(.background).resolvedColor(with: traitCollection).cgColor
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.layer.borderColor = UIColor.hibari(.background).resolvedColor(with: self.traitCollection).cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// On the edge of a round avatar (or symbol) in `frame`, at its top right.
    func place(atTopRightOf frame: CGRect) {
        let offset = frame.width / 2 * 0.7071
        let center = CGPoint(x: frame.midX + offset, y: frame.midY - offset)
        self.frame = CGRect(x: center.x - Self.size / 2, y: center.y - Self.size / 2, width: Self.size, height: Self.size)
    }
}
