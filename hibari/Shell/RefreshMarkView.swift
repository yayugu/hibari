import UIKit

/// Where the bird is: stretched by the pull, flung up by it, or hopping.
private enum MarkMoment: Equatable {
    /// Stretched down by the pull (0 = not at all, 1 = as far as it goes).
    case pulled(CGFloat)
    /// Flung up by a pull that stretched it `from` far, as from a slingshot (`t` 0..<1 through it).
    case launching(from: CGFloat, CGFloat)
    /// Through a hop (0..<1).
    case hopping(CGFloat)

    static let rest = MarkMoment.pulled(0)
}

/// The bird while a refresh goes on: flung up by the pull (a hop, higher), then hopping
/// until the refresh is done. It hops at least once, and ends at rest.
private struct RefreshMarkSequence {
    static let launchDuration: TimeInterval = 1
    static let hopDuration: TimeInterval = 0.8

    private enum Step: Equatable {
        case launch(from: CGFloat)
        case hop, done
    }

    /// Still hopping: off, it stops after the hop it is in.
    var isLoading = true
    private(set) var hops = 0
    private var step: Step
    private var stepStart: TimeInterval

    /// `pulled`: how far the pull stretched the bird as it starts.
    init(pulled: CGFloat, at time: TimeInterval) {
        step = pulled > 0 ? .launch(from: min(1, pulled)) : .hop
        stepStart = time
    }

    var isDone: Bool { step == .done }

    private func duration(of step: Step) -> TimeInterval {
        switch step {
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
            case .launch, .hop:
                hops += 1
                step = isLoading ? .hop : .done
            case .done: break
            }
        }
        let t = CGFloat(max(0, min(1, (time - stepStart) / duration(of: step))))
        switch step {
        case .launch(let from): return .launching(from: from, t)
        case .hop: return .hopping(t)
        case .done: return .rest
        }
    }
}

/// How the bird is moved: lifted (as a fraction of the mark's height) and squashed or
/// stretched about its feet (BirdMark.svg's, at `feet`).
private struct MarkPose: Equatable {
    var lift: CGFloat = 0
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1

    static let rest = MarkPose()
    /// How high a hop goes.
    static let hopHeight: CGFloat = 0.19
    /// How much higher the bird is flung by a pull as far as it goes.
    static let launchBoost: CGFloat = 0.8
    /// Where the bird's feet and the top of its head are, as fractions of the mark's height.
    static let feet: CGFloat = 234 / 256
    static let head: CGFloat = 24 / 256

    init(lift: CGFloat = 0, scaleX: CGFloat = 1, scaleY: CGFloat = 1) {
        self.lift = lift
        self.scaleX = scaleX
        self.scaleY = scaleY
    }

    /// Pulled, it stretches down like rubber, its head where it was; let go, it is flung up
    /// from there (still stretched), falls and lands squashed. A hop crouches, springs up
    /// stretched, falls and lands squashed.
    init(_ moment: MarkMoment) {
        func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * max(0, min(1, t)) }
        func smooth(_ t: CGFloat) -> CGFloat { let u = max(0, min(1, t)); return u * u * (3 - 2 * u) }
        switch moment {
        case .pulled(let p):
            let q = smooth(p)
            let scaleY = 1 + 0.32 * q
            self.init(lift: -(scaleY - 1) * (Self.feet - Self.head), scaleX: 1 - 0.14 * q, scaleY: scaleY)
        case .launching(let from, let t):
            let height = Self.hopHeight * (1 + Self.launchBoost * from)
            if t < 0.12 {
                let pulled = MarkPose(.pulled(from))
                let u = smooth(t / 0.12)
                self.init(lift: lerp(pulled.lift, 0, u) + height * 0.25 * u * u,
                          scaleX: lerp(pulled.scaleX, 0.88, u), scaleY: lerp(pulled.scaleY, 1.18, u))
            } else if t < 0.5 {
                let u = (t - 0.12) / 0.38
                self.init(lift: lerp(height * 0.25, height, 1 - (1 - u) * (1 - u)),
                          scaleX: lerp(0.88, 1, u), scaleY: lerp(1.18, 1, u))
            } else if t < 0.78 {
                let u = (t - 0.5) / 0.28
                self.init(lift: height * (1 - u * u), scaleX: lerp(1, 0.94, u), scaleY: lerp(1, 1.08, u))
            } else if t < 0.92 {
                let v = (t - 0.78) / 0.14
                self.init(scaleX: v < 0.4 ? lerp(0.94, 1.12, v / 0.4) : lerp(1.12, 1, (v - 0.4) / 0.6),
                          scaleY: v < 0.4 ? lerp(1.08, 0.84, v / 0.4) : lerp(0.84, 1, (v - 0.4) / 0.6))
            } else {
                self.init()
            }
        case .hopping(let t) where t < 0.15:
            let q = smooth(t / 0.15)
            self.init(scaleX: 1 + 0.08 * q, scaleY: 1 - 0.12 * q)
        case .hopping(let t) where t < 0.45:
            let u = (t - 0.15) / 0.3
            let stretch = u < 0.25 ? u / 0.25 : 1 - (u - 0.25) / 0.75
            let crouch = u < 0.25 ? 1 - u / 0.25 : 0
            self.init(lift: Self.hopHeight * (1 - (1 - u) * (1 - u)),
                      scaleX: 1 + 0.08 * crouch - 0.08 * stretch, scaleY: 1 - 0.12 * crouch + 0.12 * stretch)
        case .hopping(let t) where t < 0.7:
            let u = (t - 0.45) / 0.25
            self.init(lift: Self.hopHeight * (1 - u * u), scaleX: lerp(1, 0.95, u), scaleY: lerp(1, 1.06, u))
        case .hopping(let t) where t < 0.82:
            let v = (t - 0.7) / 0.12
            self.init(scaleX: v < 0.4 ? lerp(0.95, 1.1, v / 0.4) : lerp(1.1, 1, (v - 0.4) / 0.6),
                      scaleY: v < 0.4 ? lerp(1.06, 0.86, v / 0.4) : lerp(0.86, 1, (v - 0.4) / 0.6))
        case .hopping:
            self.init()
        }
    }
}

/// The app's mark in the header, which also shows the list's pull to refresh (instead of
/// a spinner): pulled, the bird stretches down with the list; let go, it is flung up as
/// from a slingshot, and hops while the refresh goes on.
final class RefreshMarkView: UIView {
    private let bird = UIImageView(image: UIImage(named: "BirdMark")?.withRenderingMode(.alwaysTemplate))

    private var moment = MarkMoment.rest
    private var pull: CGFloat = 0
    /// The finger still holds the pull: a refresh it started waits for it to let go.
    private var isHeld = false
    /// The refreshes going on.
    private var loads = 0
    /// A refresh started while the finger held the pull: its hops start as it lets go.
    private var owesHop = false
    private var sequence: RefreshMarkSequence?
    private var whenDone: [() -> Void] = []
    private var link: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        bird.tintColor = .hibari(.primaryText)
        bird.contentMode = .scaleAspectFit
        bird.layer.anchorPoint = CGPoint(x: 0.5, y: MarkPose.feet)
        addSubview(bird)
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
        bird.transform = .identity
        bird.bounds = CGRect(origin: .zero, size: bounds.size)
        bird.center = CGPoint(x: bounds.midX, y: bounds.minY + bounds.height * MarkPose.feet)
        render()
    }

    /// How far the list is pulled toward a refresh (0...1), and whether the finger still holds it.
    func setPull(_ progress: CGFloat, holding: Bool) {
        pull = max(0, min(1, progress))
        isHeld = holding
        guard sequence == nil else { return }
        if owesHop, !isHeld {
            startHopping()
        } else {
            show(.pulled(pull))
        }
    }

    /// A refresh started: the bird hops until it stops (once the finger lets go of the
    /// pull that started it).
    func startLoading() {
        loads += 1
        sequence?.isLoading = true
        guard sequence == nil else { return }
        owesHop = true
        if !isHeld { startHopping() }
    }

    /// `completion` runs when the hop the bird is in comes to its end (or the one it starts
    /// when the finger lets go).
    func stopLoading(then completion: (() -> Void)? = nil) {
        loads = max(0, loads - 1)
        if loads == 0 { sequence?.isLoading = false }
        guard let completion else { return }
        guard sequence != nil || owesHop else { return completion() }
        whenDone.append(completion)
    }

    private func startHopping() {
        owesHop = false
        let pulled: CGFloat = if case .pulled(let p) = moment { p } else { 0 }
        var sequence = RefreshMarkSequence(pulled: pulled, at: CACurrentMediaTime())
        sequence.isLoading = loads > 0
        self.sequence = sequence
        if link == nil {
            let link = CADisplayLink(target: MarkLinkTarget(self), selector: #selector(MarkLinkTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        tick()
    }

    fileprivate func tick() {
        guard var sequence else { return }
        let moment = sequence.moment(at: CACurrentMediaTime())
        self.sequence = sequence
        guard sequence.isDone else { return show(moment) }
        self.sequence = nil
        link?.invalidate()
        link = nil
        show(.pulled(pull))
        let done = whenDone
        whenDone = []
        done.forEach { $0() }
    }

    private func show(_ moment: MarkMoment) {
        guard moment != self.moment else { return }
        self.moment = moment
        render()
    }

    private func render() {
        // With Reduce Motion, the bird stays put and fades a little through each hop instead.
        let reduced = UIAccessibility.isReduceMotionEnabled
        let pose = reduced ? .rest : MarkPose(moment)
        let hop: CGFloat? = switch moment {
        case .launching(_, let t), .hopping(let t): t
        case .pulled: nil
        }
        let fade = reduced ? 0.6 * sin(.pi * (hop ?? 0)) : 0
        UIView.performWithoutAnimation {
            bird.transform = CGAffineTransform(translationX: 0, y: -pose.lift * bounds.height)
                .scaledBy(x: pose.scaleX, y: pose.scaleY)
            bird.alpha = 1 - fade
        }
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
