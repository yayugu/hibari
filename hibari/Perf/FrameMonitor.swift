import QuartzCore
import UIKit

@MainActor
final class FrameMonitor {
    struct Report: Codable, Sendable {
        var duration: Double
        var frames: Int
        var maximumFramesPerSecond: Int
        var averageFPS: Double
        var hitches: Int
        var droppedFrames: Int
        var hitchTimeMs: Double
        var hitchTimeRatio: Double
        var maxFrameMs: Double
        var p95FrameMs: Double
        var p99FrameMs: Double
    }

    /// Called on every frame after the sample is recorded (drives auto-scrolling).
    var onFrame: ((CADisplayLink) -> Void)?

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var firstTimestamp: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var hitches = 0
    private var dropped = 0
    private var hitchTime: Double = 0

    func start() {
        stop()
        reset()
        let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    func reset() {
        lastTimestamp = 0
        firstTimestamp = 0
        intervals.removeAll(keepingCapacity: true)
        hitches = 0
        dropped = 0
        hitchTime = 0
    }

    fileprivate func tick(_ link: CADisplayLink) {
        if lastTimestamp > 0 {
            let interval = link.timestamp - lastTimestamp
            let expected = max(1.0 / 240, link.targetTimestamp - link.timestamp)
            intervals.append(interval)
            if interval > expected * 1.5 {
                hitches += 1
                dropped += max(1, Int((interval / expected).rounded()) - 1)
                hitchTime += interval - expected
            }
        } else {
            firstTimestamp = link.timestamp
        }
        lastTimestamp = link.timestamp
        onFrame?(link)
    }

    func report(maximumFramesPerSecond: Int) -> Report {
        let duration = max(0.000_001, lastTimestamp - firstTimestamp)
        let sorted = intervals.sorted()
        func percentile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] * 1000
        }
        return Report(
            duration: duration,
            frames: intervals.count,
            maximumFramesPerSecond: maximumFramesPerSecond,
            averageFPS: Double(intervals.count) / duration,
            hitches: hitches,
            droppedFrames: dropped,
            hitchTimeMs: hitchTime * 1000,
            hitchTimeRatio: hitchTime * 1000 / duration,
            maxFrameMs: (sorted.last ?? 0) * 1000,
            p95FrameMs: percentile(0.95),
            p99FrameMs: percentile(0.99))
    }
}

@MainActor
private final class DisplayLinkTarget: NSObject {
    weak var monitor: FrameMonitor?

    init(_ monitor: FrameMonitor) {
        self.monitor = monitor
    }

    @objc func tick(_ link: CADisplayLink) {
        monitor?.tick(link)
    }
}

final class PerfHUD: UIView {
    private let label = UILabel()
    private let monitor = FrameMonitor()
    private var timer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor.black.withAlphaComponent(0.65)
        layer.cornerRadius = 8
        label.numberOfLines = 0
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 8, dy: 4)
    }

    func start() {
        monitor.start()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        let maxFPS = window?.windowScene?.screen.maximumFramesPerSecond ?? 60
        let report = monitor.report(maximumFramesPerSecond: maxFPS)
        monitor.reset()
        let images = ImagePipeline.shared.stats.withLock { $0 }
        let renders = NoteRenderer.shared.stats.withLock { $0 }
        label.text = String(
            format: "%3.0f / %d fps  max %.1fms\nhitch %.1f ms/s (%d)\nrender %d  img %d/%d",
            report.averageFPS, maxFPS, report.maxFrameMs, report.hitchTimeRatio, report.hitches,
            renders.renders, images.sourceDecodes, images.diskHits)
    }
}
