import UIKit

/// Where the bird is: crouched by a pull, dipping into a tapped refresh, soaring on takeoff,
/// hopping while the refresh goes on, or settling back to rest.
private enum MarkMoment: Equatable {
    /// Pulled by the user (`progress`: 0...1+, `armedElapsed`: seconds since trigger while held).
    case pulled(progress: CGFloat, armedElapsed: TimeInterval?)
    /// Dipping down into an anticipation crouch for a non-pull (tapped) refresh (`t` 0..<1).
    case dipping(CGFloat)
    /// Initial slingshot takeoff out of the pull or dip crouch (`t` 0..<1).
    case launching(CGFloat)
    /// Subsequent buoyant hops while the refresh goes on (`t` 0..<1).
    case hopping(CGFloat)
    /// Non-blocking untint & gentle settle after the final landing (`t` 0..<1).
    case settling(CGFloat)

    static let rest = MarkMoment.pulled(progress: 0, armedElapsed: nil)
}

/// The bird while a refresh goes on: from a pull it launches straight out of its crouch;
/// tapped, it dips into a crouch with the header and then launches. It hops until the
/// refresh finishes, completing at least the takeoff.
private struct RefreshMarkSequence {
    static let dipDuration: TimeInterval = 0.24
    static let hopDuration: TimeInterval = 0.76

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
        case .launch, .hop: Self.hopDuration
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

/// How the bird, its shadow, and takeoff sparks are drawn for a moment.
private struct MarkPose: Equatable {
    var lift: CGFloat = 0
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var rotation: CGFloat = 0
    var accentMix: CGFloat = 0
    var shadowOpacity: CGFloat = 0
    var shadowScale: CGFloat = 1

    static let rest = MarkPose()
    /// Where the bird's feet are, as a fraction of the mark's height (BirdMark.svg).
    static let feet: CGFloat = 234 / 256
    /// Maximum lift as a fraction of the mark's unscaled height (28pt), adapted to `room`.
    static let shelfLaunchLift: CGFloat = 0.56
    static let compactLaunchLift: CGFloat = 0.30
    static let shelfHopLift: CGFloat = 0.44
    static let compactHopLift: CGFloat = 0.25

    init(lift: CGFloat = 0, scaleX: CGFloat = 1, scaleY: CGFloat = 1, rotation: CGFloat = 0,
         accentMix: CGFloat = 0, shadowOpacity: CGFloat = 0, shadowScale: CGFloat = 1) {
        self.lift = lift
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.rotation = rotation
        self.accentMix = accentMix
        self.shadowOpacity = shadowOpacity
        self.shadowScale = shadowScale
    }

    /// `room`: extra header height above the normal bar (0...40+), used to keep jumps clear
    /// of the status bar even if the list scrolls partway down during a refresh.
    init(_ moment: MarkMoment, room: CGFloat) {
        func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * max(0, min(1, t)) }
        func smooth(_ t: CGFloat) -> CGFloat { let u = max(0, min(1, t)); return u * u * (3 - 2 * u) }
        func easeOutCubic(_ t: CGFloat) -> CGFloat { let u = 1 - max(0, min(1, t)); return 1 - u * u * u }
        func deg(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

        let headroom = smooth(room / 28)
        let launchLift = lerp(Self.compactLaunchLift, Self.shelfLaunchLift, headroom)
        let hopLift = lerp(Self.compactHopLift, Self.shelfHopLift, headroom)

        switch moment {
        case .pulled(let progress, let armedElapsed):
            let q = smooth(min(1, progress))
            let over = min(1, max(0, progress - 1))
            var angle = -9 * q
            var accent: CGFloat = 0
            if let elapsed = armedElapsed {
                accent = smooth(CGFloat(elapsed / 0.14))
                angle += 3.5 * CGFloat(sin(elapsed * 45))
            }
            self.init(
                lift: -0.10 * q,
                scaleX: 1 + 0.18 * q - 0.08 * over,
                scaleY: 1 - 0.22 * q + 0.10 * over,
                rotation: deg(angle),
                accentMix: accent,
                shadowOpacity: 0.18 * q,
                shadowScale: 1.15
            )

        case .dipping(let t):
            let u = easeOutCubic(t)
            self.init(
                lift: -0.08 * u,
                scaleX: 1 + 0.22 * u,
                scaleY: 1 - 0.26 * u,
                rotation: deg(-8 * u),
                accentMix: u,
                shadowOpacity: 0.20 * u,
                shadowScale: 1.2
            )

        case .launching(let t):
            if t < 0.42 {
                let u = t / 0.42
                let arc = 1 - (1 - u) * (1 - u)
                let snap = min(1, u * 3)
                self.init(
                    lift: launchLift * arc,
                    scaleX: lerp(1.22, 0.78, snap) + 0.22 * u,
                    scaleY: lerp(0.76, 1.32, snap) - 0.30 * u,
                    rotation: deg(lerp(-12, 9, u)),
                    accentMix: 1,
                    shadowOpacity: 0.22 * (1 - 0.75 * arc),
                    shadowScale: 1.15 - 0.60 * arc
                )
            } else if t < 0.78 {
                let u = (t - 0.42) / 0.36
                let fall = 1 - u * u
                self.init(
                    lift: launchLift * fall,
                    scaleX: lerp(1, 0.90, u),
                    scaleY: lerp(1, 1.15, u),
                    rotation: deg(lerp(9, 13, u)),
                    accentMix: 1,
                    shadowOpacity: 0.22 * (1 - 0.75 * fall),
                    shadowScale: 1.15 - 0.60 * fall
                )
            } else {
                let u = (t - 0.78) / 0.22
                let sq = sin(.pi * u)
                self.init(
                    lift: -0.05 * sq,
                    scaleX: 1 + 0.22 * sq,
                    scaleY: 1 - 0.24 * sq,
                    rotation: deg(lerp(13, 0, smooth(u))),
                    accentMix: 1,
                    shadowOpacity: 0.22,
                    shadowScale: 1 + 0.22 * sq
                )
            }

        case .hopping(let t):
            if t < 0.14 {
                let u = smooth(t / 0.14)
                self.init(
                    lift: -0.07 * u,
                    scaleX: lerp(1, 1.24, u),
                    scaleY: lerp(1, 0.74, u),
                    rotation: deg(-10 * u),
                    accentMix: 1,
                    shadowOpacity: 0.22,
                    shadowScale: 1.2
                )
            } else if t < 0.50 {
                let u = (t - 0.14) / 0.36
                let arc = 1 - (1 - u) * (1 - u)
                let snap = min(1, u * 2.5)
                self.init(
                    lift: hopLift * arc,
                    scaleX: lerp(1.24, 0.80, snap) + 0.20 * u,
                    scaleY: lerp(0.74, 1.30, snap) - 0.28 * u,
                    rotation: deg(lerp(-12, 8, u)),
                    accentMix: 1,
                    shadowOpacity: 0.20 * (1 - 0.72 * arc),
                    shadowScale: 1.1 - 0.55 * arc
                )
            } else if t < 0.80 {
                let u = (t - 0.50) / 0.30
                let fall = 1 - u * u
                self.init(
                    lift: hopLift * fall,
                    scaleX: lerp(1, 0.90, u),
                    scaleY: lerp(1, 1.14, u),
                    rotation: deg(lerp(8, 12, u)),
                    accentMix: 1,
                    shadowOpacity: 0.20 * (1 - 0.72 * fall),
                    shadowScale: 1.1 - 0.55 * fall
                )
            } else {
                let u = (t - 0.80) / 0.20
                let sq = sin(.pi * u)
                self.init(
                    lift: -0.05 * sq,
                    scaleX: 1 + 0.20 * sq,
                    scaleY: 1 - 0.22 * sq,
                    rotation: deg(lerp(12, 0, smooth(u))),
                    accentMix: 1,
                    shadowOpacity: 0.22,
                    shadowScale: 1 + 0.20 * sq
                )
            }

        case .settling(let t):
            let u = easeOutCubic(t)
            let sq = sin(.pi * u) * 0.08
            self.init(
                scaleX: 1 + sq,
                scaleY: 1 - sq,
                accentMix: 1 - u,
                shadowOpacity: 0.16 * (1 - u),
                shadowScale: 1
            )
        }
    }
}

/// The app's mark in the header, which also shows the list's pull to refresh (instead of
/// a spinner): pulled, the bird crouches and tints blue at the trigger; let go (or tapped
/// from the home tab, as the header dips), it launches skyward with wind-gust sparks and
/// hops joyfully above its shadow while the refresh goes on.
final class RefreshMarkView: UIView {
    /// Extra header room above the normal bar (set by `HeaderView` from its `pull`).
    var room: CGFloat = 0

    private let shadow = UIImageView(image: RefreshMarkView.makeShadowImage())
    private let bird = UIImageView(image: UIImage(named: "BirdMark")?.withRenderingMode(.alwaysTemplate))
    private let sparks = CALayer()
    private let sparkArcs: [CAShapeLayer]
    private let sparkDots: [CALayer]

    private var moment = MarkMoment.rest
    private var pull: CGFloat = 0
    /// The finger still holds the pull: a refresh it started waits for it to let go.
    private var isHeld = false
    /// When the pull armed while held, to animate the blue tint and eager shiver.
    private var armedAt: TimeInterval?
    /// The refreshes going on.
    private var loads = 0
    /// A refresh started while the finger held the pull: takeoff starts as it lets go.
    private var owesHop = false
    private var sequence: RefreshMarkSequence?
    /// Non-blocking untint & settle played right as the header glides closed.
    private var settleStart: TimeInterval?
    /// When the takeoff wind-gust sparks fired.
    private var sparkStart: TimeInterval?
    private var whenDone: [() -> Void] = []
    private var link: CADisplayLink?

    private static let settleDuration: TimeInterval = 0.28
    private static let sparkDuration: TimeInterval = 0.46

    override init(frame: CGRect) {
        let leftArc = Self.makeGustArc(from: CGPoint(x: -13, y: 6), control: CGPoint(x: -19, y: 2),
                                       to: CGPoint(x: -21, y: -4))
        let rightArc = Self.makeGustArc(from: CGPoint(x: 13, y: 6), control: CGPoint(x: 19, y: 2),
                                        to: CGPoint(x: 21, y: -4))
        sparkArcs = [leftArc, rightArc]
        sparkDots = [
            Self.makeSparkDot(at: CGPoint(x: -10, y: -14), radius: 1.9),
            Self.makeSparkDot(at: CGPoint(x: 12, y: -12), radius: 1.6),
            Self.makeSparkDot(at: CGPoint(x: 0, y: -17), radius: 1.4),
        ]
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = false

        shadow.tintColor = .hibari(.primaryText)
        shadow.alpha = 0
        addSubview(shadow)

        sparks.opacity = 0
        sparkArcs.forEach { sparks.addSublayer($0) }
        sparkDots.forEach { sparks.addSublayer($0) }
        layer.addSublayer(sparks)

        bird.tintColor = .hibari(.primaryText)
        bird.contentMode = .scaleAspectFit
        bird.layer.anchorPoint = CGPoint(x: 0.5, y: MarkPose.feet)
        addSubview(bird)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.applySparkColors()
            self.render()
        }
        applySparkColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Whoever waits for the hops does not wait for a mark that is gone.
    isolated deinit {
        link?.invalidate()
        whenDone.forEach { $0() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let feetY = bounds.minY + bounds.height * MarkPose.feet
        shadow.transform = .identity
        shadow.bounds = CGRect(x: 0, y: 0, width: bounds.width * 0.72, height: 6)
        shadow.center = CGPoint(x: bounds.midX, y: feetY + 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sparks.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()

        bird.transform = .identity
        bird.bounds = CGRect(origin: .zero, size: bounds.size)
        bird.center = CGPoint(x: bounds.midX, y: feetY)
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

    /// A refresh started: pulled, the bird tints blue and shivers until the finger lets go,
    /// then launches; tapped, it dips into a crouch with the header and then launches.
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
        if fromPull { sparkStart = now }
        updateDisplayLink()
        tick()
    }

    fileprivate func tick() {
        let now = CACurrentMediaTime()
        if var sequence {
            let wasLaunched = sequence.didStartLaunch
            let moment = sequence.moment(at: now)
            if !wasLaunched, sequence.didStartLaunch {
                sparkStart = now
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
            show(.pulled(progress: pull, armedElapsed: max(0, now - armedAt)))
            return
        }

        if let settleStart {
            let t = (now - settleStart) / Self.settleDuration
            if t < 1 {
                show(.settling(CGFloat(max(0, t))))
                return
            }
            self.settleStart = nil
            sparkStart = nil
            show(.pulled(progress: pull, armedElapsed: nil))
            updateDisplayLink()
            return
        }

        updateDisplayLink()
    }

    private var needsDisplayLink: Bool {
        sequence != nil || settleStart != nil || (armedAt != nil && isHeld) || sparkStart != nil
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
        let sparksActive = sparkStart != nil
        guard moment != self.moment || sparksActive else { return }
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
        let accentMix: CGFloat = if reduced {
            switch moment {
            case .pulled(_, let armed): armed != nil ? 1 : 0
            case .dipping(let t): t
            case .launching, .hopping: 1
            case .settling(let t): 1 - t
            }
        } else {
            pose.accentMix
        }
        let fade = reduced ? 0.55 * sin(.pi * (activeCycle ?? 0)) : 0
        let primary = UIColor.hibari(.primaryText).resolvedColor(with: traitCollection)
        let accent = UIColor.hibari(.accent).resolvedColor(with: traitCollection)
        let tint = Self.blend(primary, accent, accentMix)

        UIView.performWithoutAnimation {
            bird.transform = CGAffineTransform(translationX: 0, y: -pose.lift * bounds.height)
                .rotated(by: pose.rotation)
                .scaledBy(x: pose.scaleX, y: pose.scaleY)
            bird.tintColor = tint
            bird.alpha = 1 - fade

            shadow.tintColor = primary
            shadow.alpha = reduced ? 0 : pose.shadowOpacity
            shadow.transform = CGAffineTransform(scaleX: pose.shadowScale, y: 1)
        }

        renderSparks(reduced: reduced)
    }

    private func renderSparks(reduced: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard !reduced, let start = sparkStart else {
            sparks.opacity = 0
            return
        }
        let raw = (CACurrentMediaTime() - start) / Self.sparkDuration
        guard raw >= 0, raw <= 1 else {
            sparkStart = nil
            sparks.opacity = 0
            return
        }
        let t = CGFloat(raw)
        let u = 1 - pow(1 - t, 3)
        let opacity = u < 0.25 ? u / 0.25 : 1 - (u - 0.25) / 0.75
        let spread = 0.75 + 0.55 * u
        let liftY = -6 * u
        sparks.opacity = Float(max(0, min(1, opacity)))
        sparks.transform = CATransform3DConcat(
            CATransform3DMakeScale(spread, spread, 1),
            CATransform3DMakeTranslation(0, liftY, 0)
        )
    }

    private func applySparkColors() {
        let color = UIColor.hibari(.accent).resolvedColor(with: traitCollection).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for arc in sparkArcs { arc.strokeColor = color }
        for dot in sparkDots { dot.backgroundColor = color }
        CATransaction.commit()
    }

    private static func blend(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> UIColor {
        let k = max(0, min(1, t))
        guard k > 0.001 else { return a }
        guard k < 0.999 else { return b }
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * k, green: g1 + (g2 - g1) * k,
                       blue: b1 + (b2 - b1) * k, alpha: a1 + (a2 - a1) * k)
    }

    private static func makeGustArc(from: CGPoint, control: CGPoint, to: CGPoint) -> CAShapeLayer {
        let path = UIBezierPath()
        path.move(to: from)
        path.addQuadCurve(to: to, controlPoint: control)
        let layer = CAShapeLayer()
        layer.path = path.cgPath
        layer.fillColor = nil
        layer.lineWidth = 1.8
        layer.lineCap = .round
        return layer
    }

    private static func makeSparkDot(at center: CGPoint, radius: CGFloat) -> CALayer {
        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        dot.cornerRadius = radius
        dot.position = center
        return dot
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
