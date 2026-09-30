import AVKit
import ImageIO
import LinkPresentation
import UIKit

struct MediaTransitionTarget {
    /// In window coordinates.
    let frame: CGRect
    let cornerRadius: CGFloat
    let corners: CACornerMask
    let image: CGImage?
}

struct MediaViewerSource {
    /// The tile of media `index`, if it is on screen.
    let target: @MainActor (Int) -> MediaTransitionTarget?
    /// Hides the tile of media `index` while the viewer shows it in its place (nil shows
    /// them all again).
    let setHidden: @MainActor (Int?) -> Void
}

final class MediaViewerController: UIViewController {
    let files: [DriveFile]
    let source: MediaViewerSource
    private(set) var currentIndex: Int
    private let imagePipeline: ImagePipeline
    private let transition = MediaViewerTransition()

    let backdrop = UIView()
    private let pager = UIScrollView()
    private var pages: [MediaPageView] = []
    private let backButton = ChromeButton.overlay("arrow.left", pointSize: 17, label: "戻る",
                                                  identifier: "mediaViewer.back")
    private let pageControl = UIPageControl()
    private(set) var chromeViews: [UIView] = []
    private var chromeHidden = false
    private let pageGap: CGFloat = 20

    private let dismissPan = UIPanGestureRecognizer()
    private var dragOrigin: CGPoint = .zero
    private var dragBackdropAlpha: CGFloat = 1
    private(set) var releaseVelocity: CGPoint = .zero

    private var entrance: UIViewPropertyAnimator?
    private var entranceFade: UIViewPropertyAnimator?
    private var pendingEntrance: (() -> Void)?
    private var entranceAllowed = false

    static func present(files: [DriveFile], startIndex: Int, source: MediaViewerSource,
                        imagePipeline: ImagePipeline, from presenter: UIViewController) {
        guard let window = presenter.view.window, files.indices.contains(startIndex) else { return }
        let viewer = MediaViewerController(files: files, startIndex: startIndex, source: source,
                                           imagePipeline: imagePipeline)
        viewer.view.frame = window.bounds
        viewer.view.layoutIfNeeded()
        viewer.currentPage.setPlaceholder(source.target(startIndex)?.image)
        viewer.currentPage.load(scale: window.traitCollection.displayScale) { [weak viewer] in
            viewer?.startEntrance()
        }
        Task { [weak viewer] in
            try? await Task.sleep(for: .milliseconds(250))
            viewer?.startEntrance()
        }
        presenter.present(viewer, animated: true)
    }

    init(files: [DriveFile], startIndex: Int, source: MediaViewerSource, imagePipeline: ImagePipeline) {
        self.files = files
        self.source = source
        currentIndex = startIndex
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .custom
        transitioningDelegate = transition
        modalPresentationCapturesStatusBarAppearance = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var currentPage: MediaPageView { pages[currentIndex] }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersHomeIndicatorAutoHidden: Bool { chromeHidden }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "mediaViewer"
        view.accessibilityViewIsModal = true
        backdrop.backgroundColor = .black
        view.addSubview(backdrop)

        pager.isPagingEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.contentInsetAdjustmentBehavior = .never
        pager.clipsToBounds = false
        pager.delegate = self
        view.addSubview(pager)
        for file in files {
            let page = MediaPageView(file: file, imagePipeline: imagePipeline)
            page.onPlay = { [weak self, weak page] in
                guard let page else { return }
                self?.play(page.file)
            }
            pager.addSubview(page)
            pages.append(page)
        }
        pages[currentIndex].isCurrent = true

        backButton.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
        view.addSubview(backButton)

        pageControl.numberOfPages = files.count
        pageControl.currentPage = currentIndex
        pageControl.hidesForSinglePage = true
        pageControl.isUserInteractionEnabled = false
        view.addSubview(pageControl)
        chromeViews = [backButton, pageControl]

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(singleTapped(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        dismissPan.addTarget(self, action: #selector(panned(_:)))
        dismissPan.delegate = self
        for gesture in [singleTap, doubleTap, longPress, dismissPan] {
            view.addGestureRecognizer(gesture)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let safe = view.safeAreaInsets
        backdrop.frame = bounds
        let pageWidth = bounds.width + pageGap
        pager.frame = CGRect(x: 0, y: 0, width: pageWidth, height: bounds.height)
        pager.contentSize = CGSize(width: pageWidth * CGFloat(pages.count), height: bounds.height)
        for (index, page) in pages.enumerated() where page.transform == .identity {
            page.frame = CGRect(x: pageWidth * CGFloat(index), y: 0, width: bounds.width, height: bounds.height)
        }
        if !pager.isDragging && !pager.isDecelerating {
            pager.contentOffset.x = pageWidth * CGFloat(currentIndex)
        }
        backButton.frame = CGRect(x: 16, y: safe.top + 6, width: 44, height: 44)
        let dots = pageControl.sizeThatFits(bounds.size)
        pageControl.frame = CGRect(x: (bounds.width - dots.width) / 2, y: bounds.height - safe.bottom - dots.height - 8,
                                   width: dots.width, height: dots.height)
    }

    /// The image as it is shown now, in `view`'s coordinates.
    func currentImageFrame(in view: UIView) -> CGRect {
        let image = currentPage.standIn ?? currentPage.imageView
        return image.convert(image.bounds, to: view)
    }

    var currentImage: UIImage? { (currentPage.standIn ?? currentPage.imageView).image }

    var currentImageCornerRadius: CGFloat {
        guard let standIn = currentPage.standIn, standIn.bounds.width > 0 else { return 0 }
        return standIn.layer.cornerRadius * currentImageFrame(in: view).width / standIn.bounds.width
    }

    /// Sets the viewer up to look like the tile it opens from (called by the transition once
    /// the viewer is on screen); `startEntrance` then zooms it out.
    func prepareEntrance(duration: TimeInterval) {
        let page = currentPage
        guard let target = source.target(currentIndex),
              let image = currentImage ?? target.image.map({ UIImage(cgImage: $0) }) else {
            view.alpha = 0
            view.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
            pendingEntrance = { [weak self] in
                guard let self else { return }
                let animator = UIViewPropertyAnimator(duration: duration, dampingRatio: 0.86) {
                    self.view.alpha = 1
                    self.view.transform = .identity
                }
                animator.addCompletion { [weak self] _ in self?.entrance = nil }
                entrance = animator
                animator.startAnimation()
            }
            if entranceAllowed { startEntrance() }
            return
        }
        page.showStandIn(image, frame: page.convert(target.frame, from: nil),
                         cornerRadius: target.cornerRadius, corners: target.corners)
        source.setHidden(currentIndex)
        backdrop.alpha = 0
        setChromeAlpha(0)
        pendingEntrance = { [weak self, weak page] in
            guard let self, let page, let standIn = page.standIn else { return }
            if let image = page.imageView.image { standIn.image = image }
            let zoom = UIViewPropertyAnimator(duration: duration, dampingRatio: 0.86) {
                standIn.frame = page.imageView.frame
                standIn.layer.cornerRadius = 0
            }
            zoom.addCompletion { [weak self, weak page] _ in
                page?.removeStandIn()
                self?.entrance = nil
            }
            let fade = UIViewPropertyAnimator(duration: duration, dampingRatio: 0.86) {
                self.backdrop.alpha = 1
                self.setChromeAlpha(1)
            }
            fade.addCompletion { [weak self] _ in self?.entranceFade = nil }
            entrance = zoom
            entranceFade = fade
            zoom.startAnimation()
            fade.startAnimation()
        }
        if entranceAllowed { startEntrance() }
    }

    func startEntrance() {
        entranceAllowed = true
        guard let start = pendingEntrance else { return }
        pendingEntrance = nil
        start()
        loadAround(currentIndex)
    }

    private func stopEntrance() {
        pendingEntrance = nil
        entrance?.stopAnimation(true)
        entrance = nil
        entranceFade?.stopAnimation(true)
        entranceFade = nil
    }

    func setPagesHidden(_ hidden: Bool) {
        pager.isHidden = hidden
    }

    func setChromeAlpha(_ alpha: CGFloat) {
        for view in chromeViews { view.alpha = chromeHidden ? 0 : alpha }
        currentPage.overlayAlpha = alpha
    }

    private func loadAround(_ index: Int) {
        let scale = view.traitCollection.displayScale
        let near = [index, index + 1, index - 1]
        for neighbor in near where pages.indices.contains(neighbor) {
            pages[neighbor].load(scale: scale)
        }
        for (other, page) in pages.enumerated() where !near.contains(other) {
            page.unload()
        }
    }

    private func pageDidChange(to index: Int) {
        guard index != currentIndex, pages.indices.contains(index) else { return }
        pages[currentIndex].resetZoom(animated: false)
        pages[currentIndex].isCurrent = false
        pages[index].isCurrent = true
        currentIndex = index
        pageControl.currentPage = index
        source.setHidden(index)
        loadAround(index)
    }

    @objc private func singleTapped(_ gesture: UITapGestureRecognizer) {
        if let entranceFade {
            entranceFade.stopAnimation(false)
            entranceFade.finishAnimation(at: .end)
        }
        chromeHidden.toggle()
        UIView.animate(withDuration: 0.2) {
            for view in self.chromeViews { view.alpha = self.chromeHidden ? 0 : 1 }
        }
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        guard !currentPage.file.isVideo else { return }
        currentPage.toggleZoom(at: gesture.location(in: currentPage))
    }

    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        share(currentPage)
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        let page = currentPage
        let translation = gesture.translation(in: view)
        switch gesture.state {
        case .began:
            dragOrigin = gesture.location(in: pager)
            entranceFade?.stopAnimation(true)
            entranceFade = nil
            dragBackdropAlpha = backdrop.alpha
            UIView.animate(withDuration: 0.15) { self.setChromeAlpha(0) }
        case .changed:
            let progress = min(1, abs(translation.y) / (view.bounds.height * 0.45))
            let scale = 1 - (1 - dragTargetScale()) * progress
            let center = page.center
            let offset = CGPoint(x: translation.x + (1 - scale) * (dragOrigin.x - center.x),
                                 y: translation.y + (1 - scale) * (dragOrigin.y - center.y))
            page.transform = CGAffineTransform(translationX: offset.x, y: offset.y).scaledBy(x: scale, y: scale)
            backdrop.alpha = dragBackdropAlpha * (1 - progress)
        case .ended, .cancelled, .failed:
            let velocity = gesture.velocity(in: view)
            let flicked = abs(velocity.y) > 800 && (velocity.y > 0) == (translation.y > 0)
            if gesture.state == .ended && (abs(translation.y) > 90 || flicked) {
                releaseVelocity = velocity
                close()
            } else {
                UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0,
                               options: [.allowUserInteraction, .beginFromCurrentState]) {
                    page.transform = .identity
                    self.backdrop.alpha = 1
                    self.setChromeAlpha(1)
                }
            }
        default:
            break
        }
    }

    private func dragTargetScale() -> CGFloat {
        let image = currentPage.imageView.bounds.size
        guard let tile = source.target(currentIndex)?.frame, image.width > 0, image.height > 0 else { return 0.5 }
        return min(1, max(0.2, ((tile.width * tile.height) / (image.width * image.height)).squareRoot()))
    }

    func close() {
        stopEntrance()
        currentPage.stopAnimation()
        dismiss(animated: true)
    }

    private func play(_ file: DriveFile) {
        guard let string = file.url, let url = URL(string: string) else { return }
        // The default category (soloAmbient) is silenced by the ringer switch; a video
        // the user started plays with its sound, as in other apps.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let player = AVPlayerViewController()
        player.player = AVPlayer(url: url)
        present(player, animated: true) {
            player.player?.play()
        }
    }

    private func share(_ page: MediaPageView) {
        let item: Any
        if page.file.isVideo {
            guard let url = page.file.url.flatMap(URL.init(string:)) else { return }
            item = url
        } else if let url = page.url, let file = imagePipeline.source.localFile(for: url),
                  let image = UIImage(contentsOfFile: file.path(percentEncoded: false)) {
            item = ImageShareItem(image: image, title: page.file.name)
        } else if let image = page.imageView.image {
            item = ImageShareItem(image: image, title: page.file.name)
        } else {
            return
        }
        present(UIActivityViewController(activityItems: [item], applicationActivities: nil), animated: true)
    }
}

private final class ImageShareItem: NSObject, UIActivityItemSource {
    private let image: UIImage
    private let title: String

    init(image: UIImage, title: String) {
        self.image = image
        self.title = title
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any {
        image
    }

    func activityViewController(_ controller: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        image
    }

    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title.isEmpty ? "画像" : title
        let provider = NSItemProvider(object: image)
        metadata.imageProvider = provider
        metadata.iconProvider = provider
        return metadata
    }
}

extension MediaViewerController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === pager, pager.isDragging || pager.isDecelerating else { return }
        let width = max(1, pager.bounds.width)
        pageDidChange(to: Int((pager.contentOffset.x / width).rounded()))
    }
}

extension MediaViewerController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dismissPan else { return true }
        let velocity = dismissPan.velocity(in: view)
        return !currentPage.isZoomed && !pager.isDecelerating && abs(velocity.y) > abs(velocity.x)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        startEntrance()
        return true
    }
}
