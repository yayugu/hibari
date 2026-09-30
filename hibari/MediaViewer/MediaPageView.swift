import ImageIO
import UIKit

final class MediaPageView: UIScrollView, UIScrollViewDelegate {
    let file: DriveFile
    let url: String?
    let imageView = UIImageView()
    var onPlay: (() -> Void)?

    private let imagePipeline: ImagePipeline
    private let spinner = UIActivityIndicatorView(style: .large)
    private var playButton: UIButton?
    private var pixelSize: CGSize?
    private var isLoading = false
    private(set) var isLoaded = false
    private var loadGeneration = 0
    private var loadTask: ImageTask?
    private var fittedImage: UIImage?
    private var sharpening: Task<Void, Never>?
    private var isAnimated: Bool?
    private var animation: AnimationToken?
    private var laidOutSize: CGSize = .zero

    static let maximumZoom: CGFloat = 4

    init(file: DriveFile, imagePipeline: ImagePipeline) {
        self.file = file
        self.imagePipeline = imagePipeline
        url = MediaRequestPolicy.viewerURL(for: file)
        super.init(frame: .zero)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        minimumZoomScale = 1
        maximumZoomScale = Self.maximumZoom
        bouncesZoom = true

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        imageView.accessibilityLabel = file.comment.flatMap { $0.isEmpty ? nil : $0 } ?? (file.isVideo ? "動画" : "画像")
        addSubview(imageView)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        addSubview(spinner)

        if let size = file.properties.width.flatMap({ w in file.properties.height.map { CGSize(width: w, height: $0) } }),
           size.width > 0, size.height > 0 {
            pixelSize = size
        }
        if file.isVideo {
            let button = ChromeButton.overlay("play.fill", pointSize: 28, label: "再生", identifier: "mediaViewer.play")
            button.addAction(UIAction { [weak self] _ in self?.onPlay?() }, for: .touchUpInside)
            addSubview(button)
            playButton = button
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isZoomed: Bool { zoomScale > minimumZoomScale + 0.01 }

    /// Whether this is the page on screen. Leaving it stops the animation and goes back to
    /// the screen-sized bitmap.
    var isCurrent = false {
        didSet {
            guard isCurrent != oldValue else { return }
            if isCurrent {
                startAnimationIfNeeded()
            } else {
                stopAnimation()
                sharpening?.cancel()
                sharpening = nil
                if let fittedImage { imageView.image = fittedImage }
            }
        }
    }

    var overlayAlpha: CGFloat {
        get { playButton?.alpha ?? 0 }
        set { playButton?.alpha = newValue }
    }

    /// Where the image is shown at the current zoom, in this view's coordinates.
    var imageFrame: CGRect { imageView.frame.offsetBy(dx: -contentOffset.x, dy: -contentOffset.y) }

    func fittedSize(in size: CGSize) -> CGSize {
        let aspect = pixelSize.map { $0.width / $0.height }
            ?? imageView.image.map { $0.size.width / max(1, $0.size.height) }
            ?? 1
        guard size.width > 0, size.height > 0 else { return .zero }
        if size.width / size.height > aspect {
            return CGSize(width: (size.height * aspect).rounded(), height: size.height)
        }
        return CGSize(width: size.width, height: (size.width / aspect).rounded())
    }

    /// Shown until the image loads: the timeline tile (a crop of it).
    func setPlaceholder(_ image: CGImage?) {
        guard !isLoaded, let image else { return }
        imageView.image = UIImage(cgImage: image)
    }

    private(set) var standIn: UIImageView?

    /// Shows `image` at `frame` (in this view), cropped and rounded like the tile, instead of
    /// the image.
    func showStandIn(_ image: UIImage, frame: CGRect, cornerRadius: CGFloat, corners: CACornerMask) {
        removeStandIn()
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.frame = frame
        view.layer.cornerRadius = cornerRadius
        view.layer.maskedCorners = corners
        insertSubview(view, aboveSubview: imageView)
        imageView.isHidden = true
        standIn = view
    }

    func removeStandIn() {
        standIn?.removeFromSuperview()
        standIn = nil
        imageView.isHidden = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != laidOutSize {
            laidOutSize = bounds.size
            updateGeometry()
        }
        let size = imageView.frame.size
        imageView.center = CGPoint(x: max(size.width, bounds.width) / 2, y: max(size.height, bounds.height) / 2)
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        if let playButton {
            playButton.bounds.size = CGSize(width: 72, height: 72)
            playButton.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    private func updateGeometry() {
        zoomScale = 1
        let fitted = fittedSize(in: bounds.size)
        imageView.transform = .identity
        imageView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
        setNeedsLayout()
    }

    func resetZoom(animated: Bool) {
        guard isZoomed else { return }
        setZoomScale(1, animated: animated)
    }

    /// Double tap: zooms in around `point` (in this view), or back out.
    func toggleZoom(at point: CGPoint) {
        removeStandIn()
        if isZoomed {
            setZoomScale(1, animated: true)
            return
        }
        let scale: CGFloat = 2.5
        let center = imageView.convert(point, from: self)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height),
             animated: true)
    }

    /// Loads the screen-sized image; `completion` runs once it shows (or failed).
    func load(scale: CGFloat, completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard !isLoaded, !isLoading, let url else {
            completion?()
            return
        }
        isLoading = true
        let generation = loadGeneration
        if imageView.image == nil { spinner.startAnimating() }
        let source = imagePipeline.source
        Task { [weak self] in
            let ready = await source.prepare(url)
            guard let self, generation == self.loadGeneration else { return }
            guard ready else {
                self.isLoading = false
                self.spinner.stopAnimating()
                completion?()
                return
            }
            if case .known(let pixels) = source.mediaSize(for: url), pixels != self.pixelSize {
                self.pixelSize = pixels
                self.updateGeometry()
            }
            let request = ImageRequest(url: url, size: self.fittedSize(in: self.bounds.size), scale: scale)
            if let image = self.imagePipeline.cachedImage(for: request) {
                self.show(image, scale: scale)
                completion?()
                return
            }
            self.loadTask = self.imagePipeline.load(request) { [weak self] image in
                guard let self, generation == self.loadGeneration else { return }
                if let image { self.show(image, scale: scale) }
                self.isLoading = false
                self.spinner.stopAnimating()
                completion?()
            }
        }
    }

    private func show(_ image: CGImage, scale: CGFloat) {
        isLoading = false
        isLoaded = true
        spinner.stopAnimating()
        fittedImage = UIImage(cgImage: image, scale: scale, orientation: .up)
        imageView.image = fittedImage
        startAnimationIfNeeded()
        if zoomScale > 1.2 { loadSharperImageIfNeeded() }
    }

    func unload() {
        guard isLoaded || isLoading else { return }
        loadGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        isLoaded = false
        spinner.stopAnimating()
        fittedImage = nil
        imageView.image = nil
    }

    private func loadSharperImageIfNeeded() {
        guard isCurrent, isLoaded, sharpening == nil, animation == nil, let url, let pixelSize, !file.isVideo
        else { return }
        let scale = traitCollection.displayScale
        let fitted = fittedSize(in: bounds.size)
        let screenPixels = fitted.width * scale
        guard pixelSize.width > screenPixels * 1.2 else { return }
        let factor = min(Self.maximumZoom, pixelSize.width / screenPixels, 4096 / max(1, max(fitted.width, fitted.height) * scale))
        let request = ImageRequest(url: url, size: CGSize(width: fitted.width * factor, height: fitted.height * factor),
                                   scale: scale)
        let source = imagePipeline.source
        sharpening = Task { [weak self] in
            let box = await Task.detached(priority: .userInitiated) { () -> ImageBox? in
                guard let raw = source.imageSource(for: url),
                      let image = ImagePipeline.process(raw, original: pixelSize, request: request)
                else { return nil }
                return ImageBox(image)
            }.value
            guard let self, !Task.isCancelled, let box, self.animation == nil else { return }
            self.imageView.image = UIImage(cgImage: box.image, scale: scale, orientation: .up)
        }
    }

    private func startAnimationIfNeeded() {
        guard isCurrent, isLoaded, animation == nil, let url, !file.isVideo, isAnimated != false else { return }
        if isAnimated == nil {
            isAnimated = imagePipeline.source.imageSource(for: url).map { CGImageSourceGetCount($0) > 1 }
        }
        guard isAnimated == true, let fileURL = imagePipeline.source.localFile(for: url) else { return }
        let token = AnimationToken()
        animation = token
        CGAnimateImageAtURLWithBlock(fileURL as CFURL, nil) { [weak self] _, image, stop in
            MainActor.assumeIsolated {
                guard !token.isStopped, let self else {
                    stop.pointee = true
                    return
                }
                self.imageView.image = UIImage(cgImage: image)
            }
        }
    }

    func stopAnimation() {
        animation?.isStopped = true
        animation = nil
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        file.isVideo ? nil : imageView
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        removeStandIn()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        setNeedsLayout()
        if zoomScale > 1.2 { loadSharperImageIfNeeded() }
    }
}

private final class AnimationToken {
    var isStopped = false
}
