import UIKit

final class AttachmentStripView: UIScrollView {
    var onRemove: ((ComposeAttachment) -> Void)?
    /// Off while the note is being sent: what it is sent with stays.
    var isEditable = true {
        didSet {
            for tile in tiles.values { tile.isEditable = isEditable }
        }
    }

    private(set) var attachments: [ComposeAttachment] = []
    private var tiles: [UUID: AttachmentTileView] = [:]
    /// Where the text column starts; the row scrolls out to the screen's edge from there.
    var leadingInset: CGFloat = 0 {
        didSet { setNeedsLayout() }
    }
    var trailingInset: CGFloat = 16 {
        didSet { setNeedsLayout() }
    }

    static let spacing: CGFloat = 8
    static let rowHeight: CGFloat = 200

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsHorizontalScrollIndicator = false
        alwaysBounceHorizontal = false
        clipsToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ attachments: [ComposeAttachment]) {
        self.attachments = attachments
        let ids = Set(attachments.map(\.id))
        for (id, tile) in tiles where !ids.contains(id) {
            tile.removeFromSuperview()
            tiles[id] = nil
        }
        for (index, attachment) in attachments.enumerated() {
            let tile = tiles[attachment.id] ?? {
                let tile = AttachmentTileView()
                tile.onRemove = { [weak self, weak attachment] in
                    guard let attachment else { return }
                    self?.onRemove?(attachment)
                }
                tile.onRetry = { [weak attachment] in attachment?.retry() }
                tile.isEditable = isEditable
                addSubview(tile)
                tiles[attachment.id] = tile
                return tile
            }()
            tile.accessibilityIdentifier = "compose.attachment.\(index)"
            tile.update(attachment, index: index, count: attachments.count)
        }
        setNeedsLayout()
    }

    func update(_ attachment: ComposeAttachment) {
        guard let index = attachments.firstIndex(where: { $0.id == attachment.id }) else { return }
        tiles[attachment.id]?.update(attachment, index: index, count: attachments.count)
        setNeedsLayout()
    }

    /// The height at `columnWidth` (the text column's width).
    func height(columnWidth: CGFloat) -> CGFloat {
        guard let first = attachments.first else { return 0 }
        guard attachments.count == 1 else { return Self.rowHeight }
        return Self.singleHeight(aspectRatio: first.aspectRatio, width: columnWidth)
    }

    private static func singleHeight(aspectRatio: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return min(max(width / max(0.1, aspectRatio), width * 0.5), width * 1.25).rounded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let columnWidth = bounds.width - leadingInset - trailingInset
        var x = leadingInset
        for attachment in attachments {
            guard let tile = tiles[attachment.id] else { continue }
            let width = attachments.count == 1 ? columnWidth : ((columnWidth - Self.spacing) / 2).rounded()
            tile.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            x += width + Self.spacing
        }
        contentSize = CGSize(width: x - Self.spacing + trailingInset, height: bounds.height)
    }
}

private final class AttachmentTileView: UIView {
    var onRemove: (() -> Void)?
    var onRetry: (() -> Void)?
    var isEditable = true {
        didSet {
            removeButton.isEnabled = isEditable
            retryButton.isEnabled = isEditable
        }
    }

    private let imageView = UIImageView()
    private let dimming = UIView()
    private let progress = ProgressRing()
    private let retryButton = UIButton(type: .system)
    private let removeButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        clipsToBounds = true
        backgroundColor = .hibari(.mediaPlaceholder)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)
        dimming.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        dimming.isUserInteractionEnabled = false
        addSubview(dimming)
        addSubview(progress)

        retryButton.setImage(UIImage(systemName: "arrow.clockwise",
                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)),
                             for: .normal)
        retryButton.tintColor = .white
        retryButton.accessibilityLabel = "もう一度アップロード"
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)
        addSubview(retryButton)

        var remove = UIButton.Configuration.filled()
        remove.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
        remove.baseBackgroundColor = UIColor.black.withAlphaComponent(0.75)
        remove.baseForegroundColor = .white
        remove.cornerStyle = .capsule
        remove.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        removeButton.configuration = remove
        removeButton.accessibilityLabel = "画像を削除"
        removeButton.addAction(UIAction { [weak self] _ in self?.onRemove?() }, for: .touchUpInside)
        addSubview(removeButton)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(_ attachment: ComposeAttachment, index: Int, count: Int) {
        imageView.image = attachment.thumbnail
        removeButton.accessibilityIdentifier = "\(accessibilityIdentifier ?? "").remove"
        switch attachment.state {
        case .preparing:
            progress.progress = nil
        case .uploading(let share):
            progress.progress = share
        case .uploaded, .failed:
            break
        }
        let uploading = attachment.state != .uploaded && attachment.state != .failed
        progress.isHidden = !uploading
        retryButton.isHidden = attachment.state != .failed
        UIView.animate(withDuration: 0.2) {
            self.dimming.alpha = attachment.state == .uploaded ? 0 : 1
        }
        accessibilityValue = switch attachment.state {
        case .preparing, .uploading: "アップロード中"
        case .uploaded: "アップロード済み"
        case .failed: "アップロードできませんでした"
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        dimming.frame = bounds
        progress.frame = CGRect(x: bounds.midX - 16, y: bounds.midY - 16, width: 32, height: 32)
        retryButton.frame = CGRect(x: bounds.midX - 30, y: bounds.midY - 30, width: 60, height: 60)
        let size = removeButton.sizeThatFits(CGSize(width: 44, height: 44))
        removeButton.frame = CGRect(x: bounds.width - size.width - 8, y: 8, width: size.width, height: size.height)
    }
}

private final class ProgressRing: UIView {
    private let track = CAShapeLayer()
    private let bar = CAShapeLayer()

    var progress: Double? {
        didSet { update() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for layer in [track, bar] {
            layer.fillColor = nil
            layer.lineWidth = 3
            layer.lineCap = .round
            self.layer.addSublayer(layer)
        }
        track.strokeColor = UIColor.white.withAlphaComponent(0.3).cgColor
        bar.strokeColor = UIColor.white.cgColor
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let path = UIBezierPath(arcCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: bounds.width / 2 - 2,
                                startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true).cgPath
        track.frame = bounds
        bar.frame = bounds
        track.path = path
        bar.path = path
    }

    private func update() {
        CATransaction.begin()
        CATransaction.setDisableActions(progress == nil)
        if let progress {
            bar.removeAnimation(forKey: "spin")
            bar.strokeEnd = max(0.02, progress)
        } else {
            bar.strokeEnd = 0.25
            if bar.animation(forKey: "spin") == nil {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.toValue = CGFloat.pi * 2
                spin.duration = 0.9
                spin.repeatCount = .infinity
                bar.add(spin, forKey: "spin")
            }
        }
        CATransaction.commit()
    }
}
