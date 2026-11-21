import UIKit

/// Where the bird is: crouched by a pull, dipping into a tapped refresh, launching off the
/// header's spring return, hopping calmly while waiting, or settling back to rest.
private enum MarkMoment: Equatable {
    /// Pulled by the user (`progress`: 0...1+, `armedElapsed`: seconds since trigger while held).
    case pulled(progress: CGFloat, armedElapsed: TimeInterval?)
    /// Dipping down into a quick anticipation crouch for a tapped refresh (`t` 0..<1).
    case dipping(CGFloat)
    /// Initial trampoline takeoff riding the header's return (`t` 0..<1).
    case launching(CGFloat)
    /// Calm monochrome hops in the resting header while waiting for the refresh (`t` 0..<1).
    case hopping(CGFloat)
    /// Non-blocking micro-rebound & shadow fade after the final landing (`t` 0..<1).
    case settling(CGFloat)

    static let rest = MarkMoment.pulled(progress: 0, armedElapsed: nil)
}

/// The bird while a refresh goes on: from a pull it launches straight out of its crouch;
/// tapped, it dips briefly with the header and then launches. It completes at least the
/// takeoff, then hops gently until the refresh finishes.
private struct RefreshMarkSequence {
    static let dipDuration: TimeInterval = 0.19
    static let launchDuration: TimeInterval = 0.68
    static let hopDuration: TimeInterval = 0.70

    private enum Step: Equatable {
        case dip, launch, hop, done
    }

    /// Still hopping: off, it stops after the takeoff or hop it is in.
    var isLoading = true
    private(set) var didStartLaunch = false
    private var step: Step
    private var stepStart: TimeInterval

    /// `fromPull`: the bird is already crouched from the user's drag, so launch immediately.
    init(fromPull: Bool, at time: TimeInterval) {
        step = fromPull ? .launch : .dip
        stepStart = time
        didStartLaunch = fromPull
    }

    var isDone: Bool { step == .done }

    private func duration(of step: Step) -> TimeInterval {
        switch step {
        case .dip: Self.dipDuration
        case .launch: Self.launchDuration
        case .hop: Self.hopDuration
        case .done: .infinity
        }
    }

    /// Where the bird is at `time` (not before the last one asked for).
    mutating func moment(at time: TimeInterval) -> MarkMoment {
        while time - stepStart >= duration(of: step) {
            stepStart += duration(of: step)
            switch step {
            case .dip:
                step = .launch
                didStartLaunch = true
            case .launch, .hop:
                step = isLoading ? .hop : .done
            case .done:
                break
            }
        }
        let t = CGFloat(max(0, min(1, (time - stepStart) / duration(of: step))))
        switch step {
        case .dip: return .dipping(t)
        case .launch: return .launching(t)
        case .hop: return .hopping(t)
        case .done: return .rest
        }
    }
}

/// How the monochrome bird and its soft shadow are drawn for a moment.
private struct MarkPose: Equatable {
    var lift: CGFloat = 0
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var rotation: CGFloat = 0
    var alpha: CGFloat = 1
    var shadowOpacity: CGFloat = 0
    var shadowScale: CGFloat = 1

    static let rest = MarkPose()
    /// Where the bird's feet are, as a fraction of the mark's height (BirdMark.svg).
    static let feet: CGFloat = 234 / 256
    static let detentDuration: TimeInterval = 0.20
    /// Lift as a fraction of the unscaled 28pt mark: fits inside the 44pt bar at rest
    /// without clipping into the status bar, with a bit extra while the header is stretched.
    static let compactLaunchLift: CGFloat = 0.34
    static let stretchedLaunchLift: CGFloat = 0.45
    static let hopLift: CGFloat = 0.24

    init(lift: CGFloat = 0, scaleX: CGFloat = 1, scaleY: CGFloat = 1, rotation: CGFloat = 0,
         alpha: CGFloat = 1, shadowOpacity: CGFloat = 0, shadowScale: CGFloat = 1) {
        self.lift = lift
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.rotation = rotation
        self.alpha = alpha
        self.shadowOpacity = shadowOpacity
        self.shadowScale = shadowScale
    }

    init(_ moment: MarkMoment, room: CGFloat) {
        func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * max(0, min(1, t)) }
        func smooth(_ t: CGFloat) -> CGFloat { let u = max(0, min(1, t)); return u * u * (3 - 2 * u) }
        func easeOutCubic(_ t: CGFloat) -> CGFloat { let u = 1 - max(0, min(1, t)); return 1 - u * u * u }
        func deg(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

        let headroom = smooth(room / 26)
        let launchLift = lerp(Self.compactLaunchLift, Self.stretchedLaunchLift, headroom)

        switch moment {
        case .pulled(let progress, let armedElapsed):
            let q = smooth(min(1, progress))
            let over = min(1, max(0, progress - 1))
            var sx = 1 + 0.15 * q - 0.05 * over
            var sy = 1 - 0.18 * q + 0.06 * over
            var alpha: CGFloat = 1
            if let elapsed = armedElapsed {
                let u = CGFloat(max(0, min(1, elapsed / Self.detentDuration)))
                let pop = sin(.pi * u)
                alpha = 1 - 0.28 * pop
                sx += 0.05 * pop
                sy += 0.05 * pop
            }
            self.init(
                lift: -0.07 * q,
                scaleX: sx,
                scaleY: sy,
                rotation: deg(-7 * q),
                alpha: alpha,
                shadowOpacity: 0.14 * q,
                shadowScale: 1.12
            )

        case .dipping(let t):
            let u = easeOutCubic(t)
            self.init(
                lift: -0.065 * u,
                scaleX: 1 + 0.18 * u,
                scaleY: 1 - 0.21 * u,
                rotation: deg(-7 * u),
                alpha: lerp(1, 0.72, u),
                shadowOpacity: 0.14 * u,
                shadowScale: 1.15
            )

        case .launching(let t):
            if t < 0.42 {
                let u = t / 0.42
                let arc = 1 - (1 - u) * (1 - u)
                let snap = min(1, u * 2.8)
                self.init(
                    lift: launchLift * arc,
                    scaleX: lerp(1.16, 0.84, snap) + 0.16 * u,
                    scaleY: lerp(0.82, 1.22, snap) - 0.22 * u,
                    rotation: deg(lerp(-8, 7, u)),
                    alpha: lerp(0.72, 1, min(1, u * 2)),
                    shadowOpacity: 0.15 * (1 - 0.75 * arc),
                    shadowScale: 1.10 - 0.50 * arc
                )
            } else if t < 0.78 {
                let u = (t - 0.42) / 0.36
                let fall = 1 - u * u
                self.init(
                    lift: launchLift * fall,
                    scaleX: lerp(1, 0.93, u),
                    scaleY: lerp(1, 1.10, u),
                    rotation: deg(lerp(7, 9, u)),
                    alpha: 1,
                    shadowOpacity: 0.15 * (1 - 0.75 * fall),
                    shadowScale: 1.10 - 0.50 * fall
                )
            } else {
                let u = (t - 0.78) / 0.22
                let sq = sin(.pi * u)
                self.init(
                    lift: -0.036 * sq,
                    scaleX: 1 + 0.15 * sq,
                    scaleY: 1 - 0.16 * sq,
                    rotation: deg(lerp(9, 0, smooth(u))),
                    alpha: 1,
                    shadowOpacity: 0.14,
                    shadowScale: 1 + 0.14 * sq
                )
            }

        case .hopping(let t):
            let breathAlpha = 1 - 0.30 * sin(.pi * t)
            if t < 0.16 {
                let u = smooth(t / 0.16)
                self.init(
                    lift: -0.036 * u,
                    scaleX: lerp(1, 1.12, u),
                    scaleY: lerp(1, 0.86, u),
                    rotation: deg(-5 * u),
                    alpha: breathAlpha,
                    shadowOpacity: 0.12,
                    shadowScale: 1.10
                )
            } else if t < 0.50 {
                let u = (t - 0.16) / 0.34
                let arc = 1 - (1 - u) * (1 - u)
                let snap = min(1, u * 2.5)
                self.init(
                    lift: Self.hopLift * arc,
                    scaleX: lerp(1.12, 0.90, snap) + 0.10 * u,
                    scaleY: lerp(0.86, 1.12, snap) - 0.12 * u,
                    rotation: deg(lerp(-5, 5, u)),
                    alpha: breathAlpha,
                    shadowOpacity: 0.12 * (1 - 0.70 * arc),
                    shadowScale: 1.05 - 0.45 * arc
                )
            } else if t < 0.80 {
                let u = (t - 0.50) / 0.30
                let fall = 1 - u * u
                self.init(
                    lift: Self.hopLift * fall,
                    scaleX: lerp(1, 0.95, u),
                    scaleY: lerp(1, 1.07, u),
                    rotation: deg(lerp(5, 6, u)),
                    alpha: breathAlpha,
                    shadowOpacity: 0.12 * (1 - 0.70 * fall),
                    shadowScale: 1.05 - 0.45 * fall
                )
            } else {
                let u = (t - 0.80) / 0.20
                let sq = sin(.pi * u)
                self.init(
                    lift: -0.028 * sq,
                    scaleX: 1 + 0.11 * sq,
                    scaleY: 1 - 0.12 * sq,
                    rotation: deg(lerp(6, 0, smooth(u))),
                    alpha: breathAlpha,
                    shadowOpacity: 0.12,
                    shadowScale: 1 + 0.10 * sq
                )
            }

        case .settling(let t):
            let u = easeOutCubic(t)
            let sq = sin(.pi * u) * 0.05
            self.init(
                scaleX: 1 + sq,
                scaleY: 1 - sq,
                alpha: 1,
                shadowOpacity: 0.10 * (1 - u),
                shadowScale: 1
            )
        }
    }
}

/// The app's mark in the header, which also shows the list's pull to refresh (instead of
/// a spinner): stays monochrome to blend calmly with the chrome. Pulled (or tapped from
/// the home tab during its brief dip), the bird crouches and springs off the header's
/// return with subtle monochrome wind arcs, then hops gently in place until done.
final class RefreshMarkView: UIView {
    /// Extra header room above the normal bar (set by `HeaderView` from its `pull`).
    var room: CGFloat = 0

    private let shadow = UIImageView(image: RefreshMarkView.makeShadowImage())
    private let bird = CALayer()
    private let gust = CALayer()
    private let gustArcs: [CAShapeLayer]

    private struct BirdKey: Equatable {
        let size: CGSize
        let scale: CGFloat
        let style: UIUserInterfaceStyle
    }

    private var renderedBirdKey: BirdKey?
    private var moment = MarkMoment.rest
    private var pull: CGFloat = 0
    /// The finger still holds the pull: a refresh it started waits for it to let go.
    private var isHeld = false
    /// When the pull armed while held, for a brief monochrome detent pulse.
    private var armedAt: TimeInterval?
    /// The refreshes going on.
    private var loads = 0
    /// A refresh started while the finger held the pull: takeoff starts as it lets go.
    private var owesHop = false
    private var sequence: RefreshMarkSequence?
    /// Non-blocking micro-rebound after the final landing.
    private var settleStart: TimeInterval?
    /// When the subtle takeoff wind arcs fired.
    private var gustStart: TimeInterval?
    private var whenDone: [() -> Void] = []
    private var link: CADisplayLink?

    private static let settleDuration: TimeInterval = 0.26
    private static let gustDuration: TimeInterval = 0.38
    private static let gustMaxOpacity: CGFloat = 0.36

    override init(frame: CGRect) {
        let leftArc = Self.makeGustArc(from: CGPoint(x: -13, y: 6), control: CGPoint(x: -19, y: 2),
                                       to: CGPoint(x: -21, y: -4))
        let rightArc = Self.makeGustArc(from: CGPoint(x: 13, y: 6), control: CGPoint(x: 19, y: 2),
                                        to: CGPoint(x: 21, y: -4))
        gustArcs = [leftArc, rightArc]
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = false

        shadow.tintColor = .hibari(.primaryText)
        shadow.alpha = 0
        addSubview(shadow)

        gust.opacity = 0
        gustArcs.forEach { gust.addSublayer($0) }
        layer.addSublayer(gust)

        bird.anchorPoint = CGPoint(x: 0.5, y: MarkPose.feet)
        bird.contentsGravity = .resizeAspect
        bird.minificationFilter = .trilinear
        bird.magnificationFilter = .linear
        bird.allowsEdgeAntialiasing = true
        layer.addSublayer(bird)

        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) { (self: Self, _) in
            self.updateRasterizedLayers()
            self.render()
        }
        updateRasterizedLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Whoever waits for the hops does not wait for a mark that is gone.
    isolated deinit {
        link?.invalidate()
        whenDone.forEach { $0() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateRasterizedLayers()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let feetY = bounds.minY + bounds.height * MarkPose.feet
        shadow.transform = .identity
        shadow.bounds = CGRect(x: 0, y: 0, width: bounds.width * 0.72, height: 6)
        shadow.center = CGPoint(x: bounds.midX, y: feetY + 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gust.position = CGPoint(x: bounds.midX, y: bounds.midY)
        bird.setAffineTransform(.identity)
        bird.bounds = CGRect(origin: .zero, size: bounds.size)
        bird.position = CGPoint(x: bounds.midX, y: feetY)
        CATransaction.commit()

        updateRasterizedLayers()
        render()
    }

    /// How far the list is pulled toward a refresh (0...1+), and whether the finger still holds it.
    func setPull(_ progress: CGFloat, holding: Bool) {
        pull = max(0, progress)
        isHeld = holding
        guard sequence == nil else { return }
        if pull > 0 { settleStart = nil }
        if owesHop, !isHeld {
            startHopping(fromPull: true)
            return
        }
        if !isHeld {
            armedAt = nil
        }
        if settleStart == nil {
            let elapsed = armedAt.map { max(0, CACurrentMediaTime() - $0) }
            show(.pulled(progress: pull, armedElapsed: isHeld ? elapsed : nil))
            updateDisplayLink()
        }
    }

    /// A refresh started: pulled, plays a subtle detent pulse until the finger lets go,
    /// then launches; tapped, dips briefly with the header and then launches.
    func startLoading() {
        loads += 1
        sequence?.isLoading = true
        settleStart = nil
        guard sequence == nil else { return }
        owesHop = true
        if isHeld {
            if armedAt == nil { armedAt = CACurrentMediaTime() }
            show(.pulled(progress: pull, armedElapsed: 0))
            updateDisplayLink()
        } else {
            startHopping(fromPull: false)
        }
    }

    /// `completion` runs when the takeoff or hop the bird is in comes to its end (or the one
    /// it starts when the finger lets go).
    func stopLoading(then completion: (() -> Void)? = nil) {
        loads = max(0, loads - 1)
        if loads == 0 { sequence?.isLoading = false }
        guard let completion else { return }
        guard sequence != nil || owesHop else { return completion() }
        whenDone.append(completion)
    }

    private func startHopping(fromPull: Bool) {
        let now = CACurrentMediaTime()
        owesHop = false
        armedAt = nil
        settleStart = nil
        var sequence = RefreshMarkSequence(fromPull: fromPull, at: now)
        sequence.isLoading = loads > 0
        self.sequence = sequence
        if fromPull { gustStart = now }
        updateDisplayLink()
        tick()
    }

    fileprivate func tick() {
        let now = CACurrentMediaTime()
        if var sequence {
            let wasLaunched = sequence.didStartLaunch
            let moment = sequence.moment(at: now)
            if !wasLaunched, sequence.didStartLaunch {
                gustStart = now
            }
            self.sequence = sequence
            if !sequence.isDone {
                show(moment)
                return
            }
            self.sequence = nil
            if !isHeld { pull = 0 }
            settleStart = now
            show(.settling(0))
            updateDisplayLink()
            let done = whenDone
            whenDone = []
            done.forEach { $0() }
            return
        }

        if let armedAt, isHeld {
            let elapsed = max(0, now - armedAt)
            show(.pulled(progress: pull, armedElapsed: elapsed))
            if elapsed >= MarkPose.detentDuration {
                self.armedAt = nil
                updateDisplayLink()
            }
            return
        }

        if let settleStart {
            let t = (now - settleStart) / Self.settleDuration
            if t < 1 {
                show(.settling(CGFloat(max(0, t))))
                return
            }
            self.settleStart = nil
            gustStart = nil
            show(.pulled(progress: pull, armedElapsed: nil))
            updateDisplayLink()
            return
        }

        updateDisplayLink()
    }

    private var needsDisplayLink: Bool {
        sequence != nil || settleStart != nil || (armedAt != nil && isHeld) || gustStart != nil
    }

    private func updateDisplayLink() {
        if needsDisplayLink {
            guard link == nil else { return }
            let link = CADisplayLink(target: MarkLinkTarget(self), selector: #selector(MarkLinkTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            link?.invalidate()
            link = nil
        }
    }

    private func show(_ moment: MarkMoment) {
        let gustActive = gustStart != nil
        guard moment != self.moment || gustActive else { return }
        self.moment = moment
        render()
    }

    private func render() {
        let reduced = UIAccessibility.isReduceMotionEnabled
        let pose = reduced ? .rest : MarkPose(moment, room: room)
        let activeCycle: CGFloat? = switch moment {
        case .dipping(let t), .launching(let t), .hopping(let t): t
        case .pulled, .settling: nil
        }
        let alpha = reduced ? (1 - 0.50 * sin(.pi * (activeCycle ?? 0))) : pose.alpha
        let primary = UIColor.hibari(.primaryText).resolvedColor(with: traitCollection)

        UIView.performWithoutAnimation {
            shadow.tintColor = primary
            shadow.alpha = reduced ? 0 : pose.shadowOpacity
            shadow.transform = CGAffineTransform(scaleX: pose.shadowScale, y: 1)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bird.setAffineTransform(
            CGAffineTransform(translationX: 0, y: -pose.lift * bounds.height)
                .rotated(by: pose.rotation)
                .scaledBy(x: pose.scaleX, y: pose.scaleY)
        )
        bird.opacity = Float(alpha)
        CATransaction.commit()

        renderGust(reduced: reduced)
    }

    private func renderGust(reduced: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard !reduced, let start = gustStart else {
            gust.opacity = 0
            return
        }
        let raw = (CACurrentMediaTime() - start) / Self.gustDuration
        guard raw >= 0, raw <= 1 else {
            gustStart = nil
            gust.opacity = 0
            return
        }
        let t = CGFloat(raw)
        let u = 1 - pow(1 - t, 3)
        let envelope = u < 0.25 ? u / 0.25 : 1 - (u - 0.25) / 0.75
        let spread = 0.78 + 0.48 * u
        let liftY = -6 * u
        gust.opacity = Float(max(0, min(1, envelope * Self.gustMaxOpacity)))
        gust.transform = CATransform3DConcat(
            CATransform3DMakeScale(spread, spread, 1),
            CATransform3DMakeTranslation(0, liftY, 0)
        )
    }

    /// Rasterizes the bird and gust arcs at 2× screen scale so scaling up and rotating during
    /// a pull or takeoff stays sharp instead of upscaling a 1×-sized bitmap.
    private var rasterScale: CGFloat {
        let screen = window?.screen.scale ?? traitCollection.displayScale
        return max(1, screen) * 2
    }

    private func updateRasterizedLayers() {
        let scale = rasterScale
        let primary = UIColor.hibari(.primaryText).resolvedColor(with: traitCollection)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for arc in gustArcs {
            arc.strokeColor = primary.cgColor
            arc.contentsScale = scale
            arc.allowsEdgeAntialiasing = true
        }
        if bounds.width > 0, bounds.height > 0 {
            let key = BirdKey(size: bounds.size, scale: scale, style: traitCollection.userInterfaceStyle)
            if key != renderedBirdKey {
                renderedBirdKey = key
                bird.contents = Self.makeBirdImage(size: bounds.size, color: primary, scale: scale)
                bird.contentsScale = scale
            }
        }
        CATransaction.commit()
    }

    private static func makeBirdImage(size: CGSize, color: UIColor, scale: CGFloat) -> CGImage? {
        guard let source = UIImage(named: "BirdMark")?
            .withTintColor(color, renderingMode: .alwaysOriginal)
        else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            ctx.cgContext.interpolationQuality = .high
            source.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }

    private static func makeGustArc(from: CGPoint, control: CGPoint, to: CGPoint) -> CAShapeLayer {
        let path = UIBezierPath()
        path.move(to: from)
        path.addQuadCurve(to: to, controlPoint: control)
        let layer = CAShapeLayer()
        layer.path = path.cgPath
        layer.fillColor = nil
        layer.lineWidth = 1.7
        layer.lineCap = .round
        return layer
    }

    /// A soft oval rendered once as a template image so the bird's ground shadow needs no
    /// per-frame blur.
    private static func makeShadowImage() -> UIImage {
        let size = CGSize(width: 40, height: 12)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let colors = [UIColor.black.cgColor, UIColor.black.withAlphaComponent(0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { return }
            cg.saveGState()
            cg.translateBy(x: size.width / 2, y: size.height / 2)
            cg.scaleBy(x: 1, y: size.height / size.width)
            cg.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0,
                                  endCenter: .zero, endRadius: size.width / 2, options: [])
            cg.restoreGState()
        }.withRenderingMode(.alwaysTemplate)
    }
}

extension RefreshMarkView: PullToRefreshIndicator {
    var isShowingIndicator: Bool { window != nil && !isHidden && alpha > 0 }
}

@MainActor
private final class MarkLinkTarget: NSObject {
    weak var mark: RefreshMarkView?

    init(_ mark: RefreshMarkView) {
        self.mark = mark
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let mark else { return link.invalidate() }
        mark.tick()
    }
}
