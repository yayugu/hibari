import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

final class ProfileBannerView: UIView {
    let titleView = ProfileTitleView()
    let spinner = UIActivityIndicatorView(style: .medium)

    private let imageView = UIImageView()
    private let blurredView = UIImageView()
    private let titleClip = UIView()
    private let dim = UIView()
    private let scrim = CAGradientLayer()
    private var url: String?
    private var task: ImageTask?

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 0.2, green: 0.212, blue: 0.224, alpha: 1)
            : UIColor(red: 0.812, green: 0.851, blue: 0.871, alpha: 1) }
        for view in [imageView, blurredView] {
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            addSubview(view)
        }
        blurredView.alpha = 0
        dim.backgroundColor = .black
        dim.alpha = 0
        addSubview(dim)
        scrim.colors = [UIColor(white: 0, alpha: 0.28).cgColor, UIColor(white: 0, alpha: 0).cgColor]
        layer.addSublayer(scrim)
        titleClip.clipsToBounds = true
        titleClip.isUserInteractionEnabled = false
        titleClip.addSubview(titleView)
        addSubview(titleClip)
        spinner.color = .white
        spinner.hidesWhenStopped = false
        spinner.alpha = 0
        addSubview(spinner)
        accessibilityIdentifier = "profile.banner"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `imageFrame`: where the whole image is, in the banner's coordinates (it moves up as
    /// the banner shrinks, and grows as it stretches). `scrimHeight`: the status bar's.
    /// `barHeight`: the top bar's, the status bar's included (the title shows within it).
    func layout(imageFrame: CGRect, scrimHeight: CGFloat, barHeight: CGFloat) {
        imageView.frame = imageFrame
        blurredView.frame = imageFrame
        dim.frame = bounds
        titleClip.frame = CGRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrim.frame = CGRect(x: 0, y: 0, width: bounds.width, height: scrimHeight + 24)
        CATransaction.commit()
    }

    /// 0 = sharp, 1 = blurred and a little dimmed (under the title).
    func setBlur(_ amount: CGFloat) {
        blurredView.alpha = amount
        dim.alpha = amount * 0.25
    }

    var image: CGImage? { imageView.image?.cgImage }

    func setImage(url: String?, blurhash: String?, size: CGSize, scale: CGFloat, imagePipeline: ImagePipeline) {
        guard url != self.url, size.width > 0 else { return }
        self.url = url
        task?.cancel()
        imageView.image = nil
        blurredView.image = nil
        guard let url else { return }
        if let blurhash {
            Blurhash.load(blurhash) { [weak self] placeholder in
                guard let self, self.url == url, self.imageView.image == nil, let placeholder else { return }
                self.imageView.image = UIImage(cgImage: placeholder)
                self.blurredView.image = UIImage(cgImage: placeholder)
            }
        }
        let request = ImageRequest(url: url, size: size, scale: scale, mode: .aspectFill)
        if let image = imagePipeline.cachedImage(for: request) {
            show(image, for: url, scale: scale)
            return
        }
        task = imagePipeline.load(request) { [weak self] image in
            guard let self, self.url == url, let image else { return }
            self.show(image, for: url, scale: scale)
        }
    }

    private func show(_ image: CGImage, for url: String, scale: CGFloat) {
        imageView.image = UIImage(cgImage: image, scale: scale, orientation: .up)
        Task { [weak self] in
            let blurred = await Task.detached(priority: .userInitiated) { Self.blurred(image, radius: 14 * scale) }.value
            guard let self, self.url == url, let blurred else { return }
            self.blurredView.image = UIImage(cgImage: blurred, scale: scale, orientation: .up)
        }
    }

    nonisolated private static let context = CIContext(options: [.cacheIntermediates: false])

    nonisolated private static func blurred(_ image: CGImage, radius: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input.clampedToExtent()
        filter.radius = Float(radius)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return context.createCGImage(output, from: input.extent)
    }
}

final class ProfileTitleView: UIView {
    private let nameLabel = UILabel()
    private let subtitleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        nameLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = UIColor(white: 1, alpha: 0.85)
        addSubview(nameLabel)
        addSubview(subtitleLabel)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(name: NSAttributedString, subtitle: String?) {
        nameLabel.attributedText = name
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle == nil
        setNeedsLayout()
    }

    var fittingHeight: CGFloat {
        let name = ceil(nameLabel.sizeThatFits(CGSize(width: 1000, height: 100)).height)
        return subtitleLabel.isHidden ? name : name + ceil(subtitleLabel.sizeThatFits(CGSize(width: 1000, height: 100)).height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let name = ceil(nameLabel.sizeThatFits(CGSize(width: bounds.width, height: 100)).height)
        let subtitle = subtitleLabel.isHidden ? 0 : ceil(subtitleLabel.sizeThatFits(CGSize(width: bounds.width, height: 100)).height)
        let top = ((bounds.height - name - subtitle) / 2).rounded()
        nameLabel.frame = CGRect(x: 0, y: top, width: bounds.width, height: name)
        subtitleLabel.frame = CGRect(x: 0, y: top + name, width: bounds.width, height: subtitle)
    }
}

final class ProfileTopBar: UIView {
    let backButton = ChromeButton.back(identifier: "profile.back", overlay: true)
    let searchButton = ChromeButton.overlay("magnifyingglass", label: "検索", identifier: "profile.search")
    let moreButton = ChromeButton.overlay("ellipsis", label: "その他", identifier: "profile.more")
    let followButton = FollowButton(height: 32, overlay: true)
    /// Called inside the animation when the trailing buttons move (the title's room changes).
    var onLayoutChange: (() -> Void)?

    /// The status bar's height: the buttons sit below it.
    var topInset: CGFloat = 0 {
        didSet { setNeedsLayout() }
    }
    /// Not at the root of a tab (the account's own profile tab): nothing to go back to.
    var showsBackButton = true {
        didSet {
            guard showsBackButton != oldValue else { return }
            backButton.isHidden = !showsBackButton
            setNeedsLayout()
        }
    }
    /// Whether the follow button can appear (not on the account's own profile).
    var hasFollowButton = false {
        didSet {
            if !hasFollowButton { setShowsFollow(false, animated: false) }
        }
    }
    private(set) var showsFollow = false

    init() {
        super.init(frame: .zero)
        followButton.accessibilityIdentifier = "profile.barFollow"
        for view in [backButton, searchButton, moreButton, followButton] as [UIView] {
            addSubview(view)
        }
        apply(showsFollow: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        return view === self ? nil : view
    }

    func setShowsFollow(_ shows: Bool, animated: Bool) {
        let shows = shows && hasFollowButton
        guard shows != showsFollow else { return }
        showsFollow = shows
        guard animated else {
            apply(showsFollow: shows)
            setNeedsLayout()
            layoutIfNeeded()
            onLayoutChange?()
            return
        }
        UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.apply(showsFollow: shows)
            self.setNeedsLayout()
            self.layoutIfNeeded()
            self.onLayoutChange?()
        }
    }

    private func apply(showsFollow: Bool) {
        searchButton.alpha = showsFollow ? 0 : 1
        searchButton.transform = showsFollow ? CGAffineTransform(scaleX: 0.5, y: 0.5) : .identity
        followButton.alpha = showsFollow ? 1 : 0
        followButton.transform = showsFollow ? .identity : CGAffineTransform(scaleX: 0.6, y: 0.6)
        followButton.isAccessibilityElement = showsFollow
        followButton.isUserInteractionEnabled = showsFollow
        searchButton.isUserInteractionEnabled = !showsFollow
    }

    /// Where the trailing buttons start: the title ends before it.
    var trailingButtonsMinX: CGFloat {
        let size = ProfileMetrics.barButtonSize
        let edge = ProfileMetrics.padding - 4
        let first = showsFollow ? bounds.width - edge - followButton.intrinsicContentSize.width : bounds.width - edge - size
        return first - 8 - size
    }

    var rowMidY: CGFloat { topInset + ProfileMetrics.barRowHeight / 2 }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = ProfileMetrics.barButtonSize
        let edge = ProfileMetrics.padding - 4
        func place(_ view: UIView, x: CGFloat, width: CGFloat, height: CGFloat) {
            let transform = view.transform
            view.transform = .identity
            view.frame = CGRect(x: x, y: (rowMidY - height / 2).rounded(), width: width, height: height)
            view.transform = transform
        }
        let insets = topBarInsets
        place(backButton, x: insets.left + edge, width: size, height: size)
        let followSize = followButton.intrinsicContentSize
        let followX = bounds.width - insets.right - edge - followSize.width
        place(followButton, x: followX, width: followSize.width, height: followSize.height)
        let trailing = bounds.width - insets.right - edge - size
        place(searchButton, x: trailing - 8 - size, width: size, height: size)
        place(moreButton, x: showsFollow ? followX - 8 - size : trailing, width: size, height: size)
    }
}

final class ProfileAvatarView: UIView {
    let imageView: AvatarView

    init(imagePipeline: ImagePipeline) {
        imageView = AvatarView(imagePipeline: imagePipeline)
        super.init(frame: .zero)
        backgroundColor = .hibari(.background)
        imageView.backgroundColor = .hibari(.mediaPlaceholder)
        imageView.clipsToBounds = true
        addSubview(imageView)
        isAccessibilityElement = true
        accessibilityLabel = "アイコン"
        accessibilityTraits = .image
        accessibilityIdentifier = "profile.avatar"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        imageView.frame = bounds.insetBy(dx: ProfileMetrics.avatarRing, dy: ProfileMetrics.avatarRing)
        imageView.layer.cornerRadius = imageView.bounds.width / 2
    }
}
