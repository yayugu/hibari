import UIKit
import os

final class PlainLayer: CALayer {
    override func action(forKey event: String) -> (any CAAction)? { nil }
}

final class NoteCell: UICollectionViewCell {
    static let reuseIdentifier = "NoteCell"

    /// `NoteLayout.serial` of the applied layout.
    private(set) var layoutSerial: UInt64?
    private(set) var layout: NoteLayout?
    /// Where the last touch began, in cell coordinates.
    private(set) var touchPoint: CGPoint?
    private var hiddenMedia: (noteID: String, media: MediaRef)?
    private(set) var isAwaitingRender = false

    private let imageContainer = PlainLayer()
    private let decorationContainer = PlainLayer()
    private let overlayContainer = PlainLayer()
    private let blockContainer = PlainLayer()
    private let timeContainer = PlainLayer()
    private var blockLayers: [PlainLayer] = []
    private var timeLayers: [PlainLayer] = []
    private var timeTexts: [String?] = []
    private var imageLayers: [PlainLayer] = []
    private var overlayLayers: [PlainLayer] = []
    private var hidesMedia = false
    private var decorationLayers: [PlainLayer] = []
    private var connectorLayers: [PlainLayer] = []
    private let separator = PlainLayer()
    private let menuButton = NoteMenuButton()
    private var imageTasks: [ImageTask] = []
    private var pendingImages = Set<Int>()
    /// A button's answer to a tap, playing over the drawn icon (see `playActionAnimation`).
    private var actionAnimation: CALayer?

    var hasPendingImages: Bool { !pendingImages.isEmpty }

    override init(frame: CGRect) {
        super.init(frame: frame)
        for layer in [imageContainer, decorationContainer, overlayContainer, blockContainer, timeContainer, separator] {
            contentView.layer.addSublayer(layer)
        }
        isAccessibilityElement = true

        menuButton.showsMenuAsPrimaryAction = true
        menuButton.preferredMenuElementOrder = .fixed
        menuButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { return completion([]) }
            completion(self.menuProvider?(self) ?? [])
        }])
        contentView.addSubview(menuButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelImageTasks()
        layoutSerial = nil
        layout = nil
        touchPoint = nil
        hiddenMedia = nil
        if let actionAnimation { endActionAnimation(actionAnimation) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchPoint = touches.first?.location(in: self)
        super.touchesBegan(touches, with: event)
    }

    /// What a tap at the last touch does; nil for the note itself (and without a touch,
    /// e.g. VoiceOver).
    var tappedAction: NoteTapAction? {
        guard let touchPoint, let layout else { return nil }
        return layout.action(at: touchPoint)
    }

    /// VoiceOver actions, made when VoiceOver asks rather than on every `apply`.
    var customActionsProvider: ((NoteCell) -> [UIAccessibilityCustomAction])?

    /// The "…" menu, made when it opens.
    var menuProvider: ((NoteCell) -> [UIMenuElement])?

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get { customActionsProvider?(self) ?? super.accessibilityCustomActions }
        set { super.accessibilityCustomActions = newValue }
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue, let palette = layout?.key.context.palette else { return }
            let pressed = isHighlighted && tappedAction == nil
            let color = UIColor(cgColor: palette[pressed ? .chipBackground : .background])
            if pressed {
                backgroundColor = color
            } else {
                UIView.animate(withDuration: 0.25, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                    self.backgroundColor = color
                }
            }
        }
    }
    private func cancelImageTasks() {
        imageTasks.forEach { $0.cancel() }
        imageTasks.removeAll(keepingCapacity: true)
        pendingImages.removeAll(keepingCapacity: true)
    }

    /// `now`: the time relative labels show.
    func apply(_ layout: NoteLayout, rendered: RenderedNote?, imagePipeline: ImagePipeline, now: Date) {
        let signpost = Signposts.cell.beginInterval("apply")
        defer { Signposts.cell.endInterval("apply", signpost) }
        cancelImageTasks()
        let sameNote = self.layout?.key.noteID == layout.key.noteID
        if !sameNote, let actionAnimation { endActionAnimation(actionAnimation) }
        let serial = layout.serial
        layoutSerial = serial
        self.layout = layout
        let context = layout.key.context
        let scale = context.displayScale
        let palette = context.palette

        backgroundColor = UIColor(cgColor: palette[.background])

        grow(&imageLayers, to: layout.images.count, scale: scale, in: imageContainer)
        for (index, slot) in layout.images.enumerated() {
            let layer = imageLayers[index]
            layer.isHidden = false
            layer.frame = slot.frame
            layer.cornerRadius = slot.cornerRadius
            layer.maskedCorners = CACornerMask(slot.corners)
            layer.masksToBounds = true
            layer.backgroundColor = palette[.mediaPlaceholder]
            layer.contentsGravity = .resizeAspectFill
            if let request = slot.request, let image = imagePipeline.cachedImage(for: request) {
                layer.contents = image
                continue
            }
            layer.contents = slot.blurhash.flatMap { Blurhash.cachedImage(for: $0) }
            if layer.contents == nil, let blurhash = slot.blurhash {
                Blurhash.load(blurhash) { [weak self] placeholder in
                    guard let self, self.layoutSerial == serial, self.imageLayers[index].contents == nil else { return }
                    self.imageLayers[index].contents = placeholder
                }
            }
            if let request = slot.request {
                pendingImages.insert(index)
                imageTasks.append(imagePipeline.load(request) { [weak self] image in
                    guard let self, self.layoutSerial == serial else { return }
                    self.pendingImages.remove(index)
                    if let image { self.imageLayers[index].contents = image }
                })
            }
        }
        hideExtra(imageLayers, from: layout.images.count)

        let overlays = layout.images.compactMap { slot in slot.overlay.map { (slot, $0) } }
        grow(&overlayLayers, to: overlays.count, scale: scale, in: overlayContainer)
        for (index, (slot, overlay)) in overlays.enumerated() {
            configureOverlay(overlayLayers[index], overlay: overlay, slot: slot, scale: scale)
        }
        hideExtra(overlayLayers, from: overlays.count)

        grow(&decorationLayers, to: layout.decorations.count, scale: scale, in: decorationContainer)
        for (index, decoration) in layout.decorations.enumerated() {
            let layer = decorationLayers[index]
            layer.isHidden = false
            layer.frame = decoration.frame
            layer.cornerRadius = decoration.cornerRadius
            layer.borderWidth = 1 / scale
            layer.borderColor = palette[decoration.border]
        }
        hideExtra(decorationLayers, from: layout.decorations.count)

        grow(&connectorLayers, to: layout.connectors.count, scale: scale, in: decorationContainer)
        for (index, frame) in layout.connectors.enumerated() {
            let layer = connectorLayers[index]
            layer.isHidden = false
            layer.frame = frame
            layer.cornerRadius = frame.width / 2
            layer.backgroundColor = palette[.border]
        }
        hideExtra(connectorLayers, from: layout.connectors.count)

        grow(&blockLayers, to: layout.blocks.count, scale: scale, in: blockContainer)
        for (index, block) in layout.blocks.enumerated() {
            let layer = blockLayers[index]
            layer.isHidden = false
            layer.frame = block.frame
            layer.contents = rendered?.blockImages[index]
        }
        hideExtra(blockLayers, from: layout.blocks.count)
        isAwaitingRender = rendered == nil

        grow(&timeLayers, to: layout.timeSlots.count, scale: scale, in: timeContainer)
        for (index, slot) in layout.timeSlots.enumerated() {
            let layer = timeLayers[index]
            layer.isHidden = false
            layer.frame.origin = slot.origin
            if !sameNote { layer.contents = nil }
        }
        hideExtra(timeLayers, from: layout.timeSlots.count)
        timeTexts = Array(repeating: nil, count: layout.timeSlots.count)
        updateTimes(at: now)

        let bounds = CGRect(x: 0, y: 0, width: context.canvasWidth, height: layout.height)
        for container in [imageContainer, decorationContainer, overlayContainer, blockContainer, timeContainer] {
            container.frame = bounds
        }
        separator.frame = CGRect(x: 0, y: layout.height - 1 / scale, width: bounds.width, height: 1 / scale)
        separator.backgroundColor = palette[.separator]
        separator.isHidden = !layout.showsSeparator
        let more = layout.targets.last { $0.action == .more }
        menuButton.isHidden = more == nil
        if let more { menuButton.frame = more.frame }
        applyHiddenMedia()
    }

    /// Plays `kind` over its button's icon. Returns the layer playing it, which stays (as
    /// the new icon, once done) until `endActionAnimation(_:)`; nil if it does not play.
    func playActionAnimation(_ kind: ActionIconAnimation.Kind) -> CALayer? {
        guard let layout, let frame = layout.iconFrame(of: kind.action) else { return nil }
        let context = layout.key.context
        guard let animation = ActionIconAnimation.play(kind, frame: frame, cover: context.palette[.background],
                                                       palette: context.palette, scale: context.displayScale,
                                                       in: contentView.layer)
        else { return nil }
        if let actionAnimation { endActionAnimation(actionAnimation) }
        actionAnimation = animation
        // Over the next rows, for the sparks to fly out of this one.
        if kind.reachesOutside { layer.zPosition = 1 }
        return animation
    }

    func endActionAnimation(_ animation: CALayer) {
        animation.removeFromSuperlayer()
        guard animation === actionAnimation else { return }
        actionAnimation = nil
        layer.zPosition = 0
    }

    /// Where `media` is shown, in cell coordinates, with its current bitmap.
    func mediaSlot(_ media: MediaRef) -> (slot: ImageSlot, image: CGImage?)? {
        guard let layout, let index = layout.slotIndex(of: media), index < imageLayers.count else { return nil }
        let contents = imageLayers[index].contents
        let image = contents.map { $0 as! CGImage }
        return (layout.images[index], image)
    }

    /// Hides `media` of the note `noteID` (nil shows everything again).
    func setHiddenMedia(_ media: MediaRef?, of noteID: String) {
        hiddenMedia = media.map { (noteID, $0) }
        applyHiddenMedia()
    }

    private func applyHiddenMedia() {
        guard let layout else { return }
        let hidden = hiddenMedia.flatMap { $0.noteID == layout.key.noteID ? layout.slotIndex(of: $0.media) : nil }
        guard hidden != nil || hidesMedia else { return }
        hidesMedia = hidden != nil
        var overlay = 0
        for (index, slot) in layout.images.enumerated() where index < imageLayers.count {
            imageLayers[index].opacity = index == hidden ? 0 : 1
            guard slot.overlay != nil else { continue }
            if overlay < overlayLayers.count { overlayLayers[overlay].opacity = index == hidden ? 0 : 1 }
            overlay += 1
        }
    }

    func updateTimes(at now: Date) {
        guard let layout else { return }
        accessibilityLabel = layout.accessibility.label(at: now)
        let serial = layout.serial
        let scale = layout.key.context.displayScale
        for (index, slot) in layout.timeSlots.enumerated() {
            let request = slot.labelRequest(at: now, context: layout.key.context)
            guard timeTexts[index] != request.text else { continue }
            timeTexts[index] = request.text
            if let image = TimeLabelRenderer.cachedImage(for: request) {
                show(image, inTimeLayer: index, scale: scale)
                continue
            }
            TimeLabelRenderer.load(request) { [weak self] image in
                guard let self, self.layoutSerial == serial, self.timeTexts[index] == request.text, let image else { return }
                self.show(image, inTimeLayer: index, scale: scale)
            }
        }
    }

    private func show(_ image: CGImage, inTimeLayer index: Int, scale: CGFloat) {
        let layer = timeLayers[index]
        layer.contents = image
        layer.frame.size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }

    func applyRendered(_ rendered: RenderedNote) {
        guard rendered.serial == layoutSerial else { return }
        for (index, image) in rendered.blockImages.enumerated() where index < blockLayers.count {
            blockLayers[index].contents = image
        }
        isAwaitingRender = false
    }

    private func grow(_ pool: inout [PlainLayer], to count: Int, scale: CGFloat, in container: CALayer) {
        while pool.count < count {
            let layer = PlainLayer()
            layer.contentsScale = scale
            layer.contentsGravity = .resize
            container.addSublayer(layer)
            pool.append(layer)
        }
        for layer in pool where layer.contentsScale != scale {
            layer.contentsScale = scale
        }
    }

    private func hideExtra(_ pool: [PlainLayer], from index: Int) {
        guard index < pool.count else { return }
        for layer in pool[index...] where !layer.isHidden {
            layer.isHidden = true
            layer.contents = nil
        }
    }

    private func configureOverlay(_ layer: PlainLayer, overlay: MediaOverlay, slot: ImageSlot, scale: CGFloat) {
        layer.isHidden = false
        layer.masksToBounds = true
        let badge = OverlayImages.image(for: overlay, scale: scale)
        switch overlay {
        case .play:
            let size: CGFloat = 48
            layer.frame = CGRect(x: slot.frame.midX - size / 2, y: slot.frame.midY - size / 2, width: size, height: size)
            layer.cornerRadius = 0
            layer.backgroundColor = nil
            layer.contentsGravity = .resize
        case .gif:
            let size = badge.map { CGSize(width: CGFloat($0.width) / scale, height: CGFloat($0.height) / scale) } ?? .zero
            layer.frame = CGRect(x: slot.frame.minX + 8, y: slot.frame.maxY - 8 - size.height, width: size.width, height: size.height)
            layer.cornerRadius = 0
            layer.backgroundColor = nil
            layer.contentsGravity = .resize
        case .sensitive, .more:
            layer.frame = slot.frame
            layer.cornerRadius = slot.cornerRadius
            layer.maskedCorners = CACornerMask(slot.corners)
            layer.backgroundColor = UIColor.black.withAlphaComponent(overlay == .sensitive ? 0.3 : 0.5).cgColor
            layer.contentsGravity = .center
        }
        layer.contents = badge
    }
}

extension CACornerMask {
    init(_ corners: CornerMask) {
        var mask: CACornerMask = []
        if corners.contains(.topLeft) { mask.insert(.layerMinXMinYCorner) }
        if corners.contains(.topRight) { mask.insert(.layerMaxXMinYCorner) }
        if corners.contains(.bottomLeft) { mask.insert(.layerMinXMaxYCorner) }
        if corners.contains(.bottomRight) { mask.insert(.layerMaxXMaxYCorner) }
        self = mask
    }
}

@MainActor
enum OverlayImages {
    private static var cache: [String: CGImage] = [:]

    static func image(for overlay: MediaOverlay, scale: CGFloat) -> CGImage? {
        let key: String
        switch overlay {
        case .play: key = "play"
        case .gif: key = "gif"
        case .sensitive: key = "sensitive"
        case .more(let count): key = "more\(count)"
        }
        let cacheKey = "\(key)@\(scale)"
        if let hit = cache[cacheKey] { return hit }
        let image = render(overlay, scale: scale)
        cache[cacheKey] = image
        return image
    }

    private static func render(_ overlay: MediaOverlay, scale: CGFloat) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        switch overlay {
        case .play:
            let size = CGSize(width: 48, height: 48)
            return UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.black.withAlphaComponent(0.55).setFill()
                context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
                let triangle = UIBezierPath()
                triangle.move(to: CGPoint(x: 19, y: 14))
                triangle.addLine(to: CGPoint(x: 35, y: 24))
                triangle.addLine(to: CGPoint(x: 19, y: 34))
                triangle.close()
                UIColor.white.setFill()
                triangle.fill()
            }.cgImage
        case .gif:
            return badge(text: "GIF", font: .systemFont(ofSize: 12, weight: .heavy), format: format)
        case .sensitive:
            return badge(text: "センシティブな内容", symbol: "eye.slash", font: .systemFont(ofSize: 13, weight: .bold),
                         format: format)
        case .more(let count):
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 24, weight: .bold),
                .foregroundColor: UIColor.white,
            ]
            let text = NSAttributedString(string: "+\(count)", attributes: attributes)
            let size = text.size()
            return UIGraphicsImageRenderer(size: size, format: format).image { _ in
                text.draw(at: .zero)
            }.cgImage
        }
    }

    private static func badge(text: String, symbol: String? = nil, font: UIFont, format: UIGraphicsImageRendererFormat) -> CGImage? {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let icon = symbol.flatMap {
            UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(font: font))?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
        }
        let iconWidth = icon.map { $0.size.width + 6 } ?? 0
        let size = CGSize(width: (textSize.width + iconWidth + 16).rounded(.up), height: (textSize.height + 8).rounded(.up))
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.black.withAlphaComponent(0.6).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6).fill()
            if let icon {
                icon.draw(at: CGPoint(x: 8, y: (size.height - icon.size.height) / 2))
            }
            string.draw(at: CGPoint(x: 8 + iconWidth, y: 4))
        }.cgImage
    }
}

private final class NoteMenuButton: UIButton {
    private static let restingColor = UIColor.hibari(.secondaryText)
    private static let activeColor = UIColor.hibari(.accent)

    init() {
        super.init(frame: .zero)
        let image = UIImage(named: "NoteMore")?.withRenderingMode(.alwaysTemplate)
        setImage(image, for: .normal)
        setImage(image, for: .highlighted)
        tintAdjustmentMode = .normal
        tintColor = Self.restingColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// While the list moves, a touch is there to stop it: it goes to the cell, which the
    /// list keeps it from, instead of opening the menu at once.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let listMoving = sequence(first: self as UIView, next: \.superview).contains {
            guard let scrollView = $0 as? UIScrollView else { return false }
            return scrollView.isDragging || scrollView.isDecelerating
        }
        return listMoving ? nil : super.hitTest(point, with: event)
    }

    private func edgePreview() -> UITargetedPreview {
        let opensUp = window.map { convert(bounds, to: $0).midY > $0.bounds.midY } ?? false
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        let target = UIPreviewTarget(container: self,
                                     center: CGPoint(x: bounds.midX, y: opensUp ? bounds.minY : bounds.maxY))
        return UITargetedPreview(view: UIView(frame: CGRect(x: 0, y: 0, width: bounds.width, height: 1)),
                                 parameters: parameters, target: target)
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                         previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration)
        -> UITargetedPreview? {
        edgePreview()
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                         previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration)
        -> UITargetedPreview? {
        edgePreview()
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                         willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                         animator: (any UIContextMenuInteractionAnimating)?) {
        super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        tintColor = Self.activeColor
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                         willEndFor configuration: UIContextMenuConfiguration,
                                         animator: (any UIContextMenuInteractionAnimating)?) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        tintColor = Self.restingColor
    }
}
