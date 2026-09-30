import UIKit

final class SideSwipeGestureRecognizer: UIGestureRecognizer {
    /// Movement from the touch-down point before the direction is decided.
    var decisionDistance: CGFloat = 10
    /// Steepest movement (|dy| / |dx|) that is still sideways: about 56°.
    var maxSlope: CGFloat = 1.5
    /// Asked at touch-down, with the touch; false fails the swipe at once, so gestures
    /// that wait for it to fail do not wait.
    var canStart: ((UITouch) -> Bool)?

    private weak var touch: UITouch?
    private var start: CGPoint = .zero
    private var samples: [(location: CGPoint, time: TimeInterval)] = []

    /// Movement since touch-down, in `view`'s coordinates.
    func translation(in view: UIView?) -> CGPoint {
        guard let touch else { return .zero }
        return delta(from: start, to: touch.location(in: nil), in: view)
    }

    /// Points per second over the last tenth of a second, in `view`'s coordinates.
    func velocity(in view: UIView?) -> CGPoint {
        guard let first = samples.first, let last = samples.last, last.time > first.time else { return .zero }
        let d = delta(from: first.location, to: last.location, in: view)
        let dt = CGFloat(last.time - first.time)
        return CGPoint(x: d.x / dt, y: d.y / dt)
    }

    private func delta(from a: CGPoint, to b: CGPoint, in view: UIView?) -> CGPoint {
        guard let view, let window = view.window else { return CGPoint(x: b.x - a.x, y: b.y - a.y) }
        let pa = view.convert(a, from: window)
        let pb = view.convert(b, from: window)
        return CGPoint(x: pb.x - pa.x, y: pb.y - pa.y)
    }

    private func record(_ touch: UITouch) {
        let now = touch.timestamp
        samples.append((touch.location(in: nil), now))
        while samples.count > 2, let first = samples.first, now - first.time > 0.1 {
            samples.removeFirst()
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touch == nil, let first = touches.first, touches.count == 1, canStart?(first) ?? true else {
            if state == .possible { state = .failed }
            return
        }
        touch = first
        start = first.location(in: nil)
        record(first)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        record(touch)
        switch state {
        case .possible:
            let d = CGPoint(x: touch.location(in: nil).x - start.x, y: touch.location(in: nil).y - start.y)
            guard hypot(d.x, d.y) >= decisionDistance else { return }
            state = abs(d.y) < abs(d.x) * maxSlope ? .began : .failed
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        record(touch)
        state = state == .began || state == .changed ? .ended : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        state = state == .began || state == .changed ? .cancelled : .failed
    }

    override func reset() {
        super.reset()
        touch = nil
        samples = []
    }
}
