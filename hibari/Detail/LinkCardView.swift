import UIKit

/// The card for the page a note links to, on the detail screen: what the timeline draws
/// (`NoteLayoutBuilder.linkCard`), as views.
final class LinkCardView: UIControl {
    private let image = UIImageView()
    private let placeholder = UIImageView()
    private let play = UIImageView()
    private let band = UIView()
    private let title = UILabel()
    private let domain = UILabel()
    private var shownImage: LinkCard.Thumbnail?
    private var isLarge = false
    private var imageTask: ImageTask?
    private var loadedRequest: String?
    private var imagePipeline: ImagePipeline?
    private var scale: CGFloat = 3

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerCurve = .continuous
        clipsToBounds = true
        image.contentMode = .scaleAspectFill
        image.clipsToBounds = true
        image.backgroundColor = .hibari(.mediaPlaceholder)
        image.layer.cornerCurve = .continuous
        placeholder.contentMode = .center
        placeholder.tintColor = .hibari(.secondaryText)
        band.backgroundColor = .hibari(.linkTitleBackground)
        band.layer.cornerRadius = 4
        title.lineBreakMode = .byTruncatingTail
        domain.textColor = .hibari(.secondaryText)
        domain.lineBreakMode = .byTruncatingTail
        for view in [image, placeholder, play, band, title, domain] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        isAccessibilityElement = true
        accessibilityTraits = .link
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.applyBorder()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `fontSize`: the scaled point size for a base size (the timeline's).
    func configure(_ card: LinkCard, revealsSensitiveMedia: Bool, imagePipeline: ImagePipeline, scale: CGFloat,
                   fontSize: (CGFloat) -> CGFloat) {
        self.imagePipeline = imagePipeline
        self.scale = scale
        shownImage = card.image(revealingSensitiveMedia: revealsSensitiveMedia)
        isLarge = shownImage != nil && card.size == .large
        let preview = card.preview
        accessibilityLabel = "リンク: \(preview.title)、\(preview.domain)"
        title.text = preview.title.oneLine
        title.font = .systemFont(ofSize: fontSize(isLarge ? 13 : 16))
        title.textColor = isLarge ? .hibari(.overlayText) : .hibari(.primaryText)
        title.numberOfLines = isLarge ? 1 : 2
        domain.text = preview.domain
        domain.font = .systemFont(ofSize: fontSize(isLarge ? 14 : 16))
        band.isHidden = !isLarge
        placeholder.isHidden = shownImage != nil
        if shownImage == nil {
            let icon = LinkCardGeometry.placeholderIcon
            placeholder.image = IconStore.shared.templateImage(.link, size: CGSize(width: icon, height: icon), scale: scale)
        }
        play.isHidden = !isLarge || !preview.hasPlayer
        if !play.isHidden, let badge = OverlayImages.image(for: .play, scale: scale) {
            play.image = UIImage(cgImage: badge, scale: scale, orientation: .up)
        }
        applyBorder()
        setNeedsLayout()
    }

    /// Lays out at `width`; returns the height.
    @discardableResult
    func layout(width: CGFloat, apply: Bool) -> CGFloat {
        isLarge ? layoutLarge(width: width, apply: apply) : layoutSmall(width: width, apply: apply)
    }

    private func layoutLarge(width: CGFloat, apply: Bool) -> CGFloat {
        let imageFrame = CGRect(x: 0, y: 0, width: width, height: (width / LinkCardGeometry.aspect).rounded())
        let domainWidth = width - LinkCardGeometry.domainIndent
        let domainHeight = ceil(domain.sizeThatFits(CGSize(width: domainWidth, height: 100)).height)
        let domainTop = imageFrame.maxY + LinkCardGeometry.domainSpacing
        guard apply else { return domainTop + domainHeight }
        image.frame = imageFrame
        loadImage(size: imageFrame.size)
        play.frame = CGRect(x: imageFrame.midX - 24, y: imageFrame.midY - 24, width: 48, height: 48)
        let inset = LinkCardGeometry.titleInset
        let padding = LinkCardGeometry.titlePadding
        let titleMax = width - (inset + padding) * 2
        let titleSize = title.sizeThatFits(CGSize(width: titleMax, height: 100))
        let titleWidth = min(ceil(titleSize.width), titleMax)
        let bandHeight = ceil(titleSize.height) + 2
        band.frame = CGRect(x: inset, y: imageFrame.maxY - inset - bandHeight, width: titleWidth + padding * 2,
                            height: bandHeight)
        title.frame = CGRect(x: band.frame.minX + padding, y: band.frame.minY + 1, width: titleWidth,
                             height: ceil(titleSize.height))
        domain.frame = CGRect(x: LinkCardGeometry.domainIndent, y: domainTop, width: domainWidth, height: domainHeight)
        return domainTop + domainHeight
    }

    private func layoutSmall(width: CGFloat, apply: Bool) -> CGFloat {
        let side = LinkCardGeometry.side
        let textWidth = max(40, width - side - LinkCardGeometry.padding * 2)
        let titleHeight = ceil(title.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        let domainHeight = ceil(domain.sizeThatFits(CGSize(width: textWidth, height: 100)).height)
        let textHeight = titleHeight + domainHeight
        let height = max(side, textHeight + LinkCardGeometry.verticalPadding * 2)
        guard apply else { return height }
        let imageFrame = CGRect(x: 0, y: 0, width: side, height: height)
        image.frame = imageFrame
        placeholder.frame = imageFrame
        loadImage(size: imageFrame.size)
        let x = side + LinkCardGeometry.padding
        let top = ((height - textHeight) / 2).rounded()
        title.frame = CGRect(x: x, y: top, width: textWidth, height: titleHeight)
        domain.frame = CGRect(x: x, y: top + titleHeight, width: textWidth, height: domainHeight)
        return height
    }

    private func loadImage(size: CGSize) {
        guard let shownImage, let imagePipeline, size.width > 0 else {
            imageTask?.cancel()
            loadedRequest = nil
            image.image = nil
            return
        }
        let request = ImageRequest(url: shownImage.url, size: size, scale: scale)
        guard request.cacheKey != loadedRequest else { return }
        loadedRequest = request.cacheKey
        imageTask?.cancel()
        if let cached = imagePipeline.cachedImage(for: request) {
            image.image = UIImage(cgImage: cached, scale: scale, orientation: .up)
            return
        }
        image.image = nil
        let scale = self.scale
        imageTask = imagePipeline.load(request) { [weak self] loaded in
            guard let self, let loaded, self.loadedRequest == request.cacheKey else { return }
            self.image.image = UIImage(cgImage: loaded, scale: scale, orientation: .up)
        }
    }

    /// The large card frames its image; the small one the whole card.
    private func applyBorder() {
        let border = UIColor.hibari(.border).resolvedColor(with: traitCollection).cgColor
        let width = 1 / scale
        image.layer.cornerRadius = isLarge ? 16 : 0
        image.layer.borderWidth = isLarge ? width : 0
        image.layer.borderColor = border
        layer.cornerRadius = isLarge ? 0 : 16
        layer.borderWidth = isLarge ? 0 : width
        layer.borderColor = border
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layout(width: bounds.width, apply: true)
    }

    override var isHighlighted: Bool {
        didSet {
            alpha = isHighlighted ? 0.7 : 1
        }
    }
}
