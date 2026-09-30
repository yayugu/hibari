import UIKit

final class ReactionChipsView: UIView {
    /// A chip was tapped: its reaction key, and the chip in window coordinates.
    var onTap: ((String, CGRect) -> Void)?

    /// Custom emojis shown square because their size was not known: configure again once
    /// it is.
    private(set) var provisionalEmojis: Set<String> = []

    private var chips: [ReactionChip] = []
    private static let spacing: CGFloat = 6

    func configure(_ note: Note, resolver: EmojiResolver, imagePipeline: ImagePipeline, scale: CGFloat) {
        chips.forEach { $0.removeFromSuperview() }
        provisionalEmojis = []
        chips = note.reactions
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { key, count in
                let chip = ReactionChip(key: key, count: count, reacted: key == note.myReaction)
                if let provisional = chip.load(resolver.reaction(key, reactionEmojis: note.reactionEmojis),
                                               imagePipeline: imagePipeline, scale: scale) {
                    provisionalEmojis.insert(provisional)
                }
                chip.addAction(UIAction { [weak self, weak chip] _ in
                    guard let self, let chip else { return }
                    self.onTap?(key, chip.convert(chip.bounds, to: nil))
                }, for: .touchUpInside)
                addSubview(chip)
                return chip
            }
        setNeedsLayout()
    }

    /// Height of the chips wrapped at `width`.
    func height(for width: CGFloat) -> CGFloat {
        frames(for: width).last.map(\.maxY) ?? 0
    }

    private func frames(for width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        for chip in chips {
            let size = chip.intrinsicContentSize
            if x > 0 && x + size.width > width {
                x = 0
                y += ReactionChip.height + Self.spacing
            }
            frames.append(CGRect(x: x, y: y, width: min(size.width, width), height: ReactionChip.height))
            x += size.width + Self.spacing
        }
        return frames
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (chip, frame) in zip(chips, frames(for: bounds.width)) {
            // Not `frame`: chips scale while pressed.
            chip.bounds.size = frame.size
            chip.center = CGPoint(x: frame.midX, y: frame.midY)
        }
    }
}

private final class ReactionChip: UIControl {
    static let height: CGFloat = 32
    private static let emojiHeight: CGFloat = 22

    private let emojiLabel = UILabel()
    private let imageView = UIImageView()
    private let countLabel = UILabel()
    private var emojiWidth: CGFloat = 22
    private var task: ImageTask?

    init(key: String, count: Int, reacted: Bool) {
        super.init(frame: .zero)
        layer.cornerRadius = Self.height / 2
        layer.cornerCurve = .continuous
        backgroundColor = reacted ? .hibari(.chipReactedBackground) : .hibari(.chipBackground)
        if reacted {
            layer.borderWidth = 1
            layer.borderColor = UIColor.hibari(.accent).cgColor
        }
        emojiLabel.font = .systemFont(ofSize: 18)
        addSubview(emojiLabel)
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: reacted ? .semibold : .regular)
        countLabel.textColor = reacted ? .hibari(.accent) : .hibari(.secondaryText)
        countLabel.text = CountLabel.format(count)
        addSubview(countLabel)
        isAccessibilityElement = true
        accessibilityTraits = reacted ? [.button, .selected] : .button
        accessibilityValue = "\(count)"
        accessibilityLabel = ReactionKey.customName(key) ?? key
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            if self.layer.borderWidth > 0 {
                self.layer.borderColor = UIColor.hibari(.accent).resolvedColor(with: self.traitCollection).cgColor
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Returns the URL of a custom emoji whose size is not known yet: it is square until
    /// then, like in the timeline.
    func load(_ reaction: EmojiResolver.Reaction, imagePipeline: ImagePipeline, scale: CGFloat) -> String? {
        switch reaction {
        case .unicode(let emoji):
            emojiLabel.text = emoji
            emojiWidth = emojiLabel.intrinsicContentSize.width
            return nil
        case .custom(let name, let url):
            let size = url.map { imagePipeline.mediaSize(for: $0) } ?? .unavailable
            guard let url, size != .unavailable else {
                emojiLabel.text = ":\(name):"
                emojiLabel.font = .systemFont(ofSize: 13)
                emojiLabel.textColor = .hibari(.secondaryText)
                emojiWidth = min(120, emojiLabel.intrinsicContentSize.width)
                return nil
            }
            let aspect: CGFloat = if case .known(let pixels) = size { pixels.width / pixels.height } else { 1 }
            emojiWidth = (Self.emojiHeight * min(3, max(0.6, aspect))).rounded()
            let request = ImageRequest(url: url, size: CGSize(width: emojiWidth, height: Self.emojiHeight), scale: scale,
                                       mode: .aspectFit)
            if let image = imagePipeline.cachedImage(for: request) {
                imageView.image = UIImage(cgImage: image, scale: scale, orientation: .up)
            } else {
                task = imagePipeline.load(request) { [weak self] image in
                    guard let image else { return }
                    self?.imageView.image = UIImage(cgImage: image, scale: scale, orientation: .up)
                }
            }
            return size == .unknown ? url : nil
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: 10 + emojiWidth + 6 + countLabel.intrinsicContentSize.width + 12, height: Self.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let emojiFrame = CGRect(x: 10, y: (bounds.height - Self.emojiHeight) / 2, width: emojiWidth, height: Self.emojiHeight)
        emojiLabel.frame = emojiFrame
        imageView.frame = emojiFrame
        let count = countLabel.intrinsicContentSize
        countLabel.frame = CGRect(x: emojiFrame.maxX + 6, y: (bounds.height - count.height) / 2,
                                  width: count.width, height: count.height)
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.92, y: 0.92) : .identity
            }
        }
    }
}
