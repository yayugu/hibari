import UIKit

final class MediaGridView: UIView {
    /// A tile was tapped: its index in the visual files.
    var onTap: ((Int) -> Void)?
    /// A hidden (sensitive) tile was tapped.
    var onReveal: (() -> Void)?

    private var files: [DriveFile] = []
    private var tiles: [UIImageView] = []
    private var overlays: [UIImageView] = []
    private var tasks: [ImageTask] = []
    private var configuredKey: String?
    private var revealed = false
    private var hiddenIndex: Int?

    /// Rounded and bordered on its own; off inside a box that clips it (a quote).
    var isFramed = true {
        didSet {
            layer.cornerRadius = isFramed ? 16 : 0
            layer.borderWidth = isFramed ? layer.borderWidth : 0
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        layer.borderColor = UIColor.hibari(.border).cgColor
        clipsToBounds = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.layer.borderColor = UIColor.hibari(.border).resolvedColor(with: self.traitCollection).cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func height(for files: [DriveFile], width: CGFloat) -> CGFloat {
        guard !files.isEmpty else { return 0 }
        let frames = MediaGrid.frames(count: min(files.count, 4), width: width, gap: 2, firstAspect: files[0].aspectRatio)
        return frames.map(\.maxY).max() ?? 0
    }

    func configure(files: [DriveFile], revealed: Bool, width: CGFloat, imagePipeline: ImagePipeline, scale: CGFloat) {
        let key = "\(files.map(\.id))|\(revealed)|\(width)|\(scale)"
        guard key != configuredKey else { return }
        configuredKey = key
        self.files = files
        self.revealed = revealed
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        tiles.forEach { $0.removeFromSuperview() }
        overlays.forEach { $0.removeFromSuperview() }
        tiles.removeAll()
        overlays.removeAll()
        layer.borderWidth = isFramed ? 1 / scale : 0
        let frames = MediaGrid.frames(count: min(files.count, 4), width: width, gap: 2, firstAspect: files.first?.aspectRatio)
        for (index, frame) in frames.enumerated() {
            let file = files[index]
            let hidden = file.isSensitive && !revealed
            let tile = UIImageView(frame: frame)
            tile.contentMode = .scaleAspectFill
            tile.clipsToBounds = true
            tile.backgroundColor = .hibari(.mediaPlaceholder)
            tile.isAccessibilityElement = true
            tile.accessibilityTraits = [.image, .button]
            tile.accessibilityLabel = hidden ? "センシティブな内容" : (file.comment ?? (file.isVideo ? "動画" : "画像"))
            addSubview(tile)
            tiles.append(tile)
            if let blurhash = file.blurhash {
                tile.image = Blurhash.cachedImage(for: blurhash).map { UIImage(cgImage: $0) }
                if tile.image == nil {
                    Blurhash.load(blurhash) { [weak tile] image in
                        guard let tile, tile.image == nil, let image else { return }
                        tile.image = UIImage(cgImage: image)
                    }
                }
            }
            if !hidden, let url = MediaRequestPolicy.previewURL(for: file) {
                let request = ImageRequest(url: url, size: frame.size, scale: scale)
                if let image = imagePipeline.cachedImage(for: request) {
                    tile.image = UIImage(cgImage: image, scale: scale, orientation: .up)
                } else {
                    tasks.append(imagePipeline.load(request) { [weak tile] image in
                        guard let tile, let image else { return }
                        tile.image = UIImage(cgImage: image, scale: scale, orientation: .up)
                    })
                }
            }
            let overlay: MediaOverlay? = index == 3 && files.count > 4 ? .more(files.count - 4)
                : hidden ? .sensitive : file.isVideo ? .play : file.isGIF ? .gif : nil
            if let overlay, let badge = OverlayImages.image(for: overlay, scale: scale) {
                let view = UIImageView(image: UIImage(cgImage: badge, scale: scale, orientation: .up))
                let size = view.image?.size ?? .zero
                switch overlay {
                case .play:
                    view.frame = CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                                        width: size.width, height: size.height)
                case .gif:
                    view.frame = CGRect(x: frame.minX + 8, y: frame.maxY - 8 - size.height, width: size.width, height: size.height)
                case .sensitive, .more:
                    view.frame = frame
                    view.contentMode = .center
                    view.backgroundColor = UIColor.black.withAlphaComponent(overlay == .sensitive ? 0.3 : 0.5)
                }
                addSubview(view)
                overlays.append(view)
            }
        }
        applyHidden()
    }

    /// Where tile `index` is, in this view, with what it shows.
    func tile(at index: Int) -> (frame: CGRect, image: CGImage?)? {
        guard tiles.indices.contains(index) else { return nil }
        return (tiles[index].frame, tiles[index].image?.cgImage)
    }

    /// Hides tile `index` while the media viewer shows it (nil shows all).
    func setHiddenTile(_ index: Int?) {
        hiddenIndex = index
        applyHidden()
    }

    private func applyHidden() {
        for (index, tile) in tiles.enumerated() {
            tile.alpha = index == hiddenIndex ? 0 : 1
        }
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        guard let index = tiles.firstIndex(where: { $0.frame.contains(point) }) else { return }
        if files[index].isSensitive && !revealed {
            onReveal?()
        } else {
            onTap?(index)
        }
    }
}
