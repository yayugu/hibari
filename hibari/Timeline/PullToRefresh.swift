import UIKit

/// Shows a pull to refresh instead of the spinner (the header's mark).
@MainActor
protocol PullToRefreshIndicator: AnyObject {
    /// It is on screen: a pull shows on it rather than with the spinner.
    var isShowingIndicator: Bool { get }
    /// How far the list is pulled toward a refresh (0...1), and whether the finger holds it.
    func setPull(_ progress: CGFloat, holding: Bool)
    func startLoading()
    /// `completion` runs when what it shows of the refresh comes to its end.
    func stopLoading(then completion: (() -> Void)?)
}

@MainActor
final class PullToRefresh {
    static let triggerDistance: CGFloat = 30
    static let minimumDuration: TimeInterval = 0.6
    private static let room: CGFloat = 40

    var onRefresh: (() -> Void)?
    /// `inset` changed: the owner puts it into the content inset (inside an animation
    /// when it goes back to 0).
    var onInsetChange: (() -> Void)?
    /// Shows the pull when on screen; the spinner does otherwise.
    weak var indicator: PullToRefreshIndicator?
    /// Extra room at the top of the content while refreshing.
    private(set) var inset: CGFloat = 0
    private(set) var isRefreshing = false
    /// A refresh started by `beginRefreshing()` keeps the spinner up until then, even when
    /// it is done sooner, so the whole animation plays (`waitForAnimation()` waits for it).
    private var holdsUntil = Date.distantPast

    private weak var scrollView: UIScrollView?
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let feedback = UIImpactFeedbackGenerator(style: .medium)
    /// This drag can still start a refresh: a drag starts at most one. Set when the drag
    /// begins, not from where the content is, which the list can move under the finger.
    private var armed = false
    private var startedAt = Date.distantPast
    private var pendingEnd: Task<Void, Never>?
    /// The refresh going on shows on this, not with the spinner.
    private var shownOn: PullToRefreshIndicator?
    /// `shownOn` was told the refresh stopped.
    private var stoppedShowing = false

    init(scrollView: UIScrollView, color: UIColor = .hibari(.secondaryText)) {
        self.scrollView = scrollView
        spinner.color = color
        spinner.hidesWhenStopped = false
        spinner.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        spinner.alpha = 0
        spinner.isAccessibilityElement = false
        scrollView.addSubview(spinner)
    }

    private func pulled(_ scrollView: UIScrollView) -> CGFloat {
        -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top - inset)
    }

    /// What shows the pull now: the indicator on screen, or the one the refresh going on
    /// shows on; nil for the spinner.
    private var shownIndicator: PullToRefreshIndicator? {
        if isRefreshing { return shownOn }
        return indicator?.isShowingIndicator == true ? indicator : nil
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        armed = !isRefreshing
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let distance = pulled(scrollView)
        let shown = shownIndicator
        if let shown {
            shown.setPull(max(0, distance) / Self.triggerDistance, holding: scrollView.isDragging)
        } else {
            spinner.center = CGPoint(x: scrollView.bounds.midX, y: -max(distance, Self.room) / 2)
            if armed {
                spinner.alpha = min(1, max(0, (distance - 8) / (Self.triggerDistance - 8)))
            }
        }
        guard armed, scrollView.isDragging, distance >= Self.triggerDistance else { return }
        armed = false
        isRefreshing = true
        startedAt = Date()
        feedback.impactOccurred()
        if let shown {
            show(on: shown)
        } else {
            spinner.alpha = 1
            spinner.startAnimating()
        }
        onRefresh?()
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView) {
        if let shown = shownIndicator {
            // It shows the refresh from here, without room in the list: the list goes back up.
            shown.setPull(max(0, pulled(scrollView)) / Self.triggerDistance, holding: false)
            return
        }
        guard isRefreshing, inset == 0, pulled(scrollView) > 0 else { return }
        inset = Self.room
        onInsetChange?()
    }

    private func show(on indicator: PullToRefreshIndicator) {
        shownOn = indicator
        stoppedShowing = false
        indicator.startLoading()
    }

    /// Starts refreshing as if pulled, without a drag: the content moves down to show the
    /// spinner, or the indicator shows it.
    func beginRefreshing() {
        guard !isRefreshing, let scrollView else { return }
        isRefreshing = true
        armed = false
        startedAt = Date()
        if let indicator, indicator.isShowingIndicator {
            show(on: indicator)
            onRefresh?()
            return
        }
        holdsUntil = startedAt.addingTimeInterval(Self.minimumDuration)
        spinner.startAnimating()
        UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.spinner.alpha = 1
            self.inset = Self.room
            self.onInsetChange?()
            scrollView.contentOffset.y = -scrollView.adjustedContentInset.top
        }
        onRefresh?()
    }

    /// Waits for what shows the refresh to come to its end, so the update lands as it does:
    /// the indicator's (the bird hops at least once), or the spinner of a tapped
    /// refresh, held until `holdsUntil`.
    func waitForAnimation() async {
        if isRefreshing, let shownOn, !stoppedShowing {
            stoppedShowing = true
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                shownOn.stopLoading { continuation.resume() }
            }
            return
        }
        let wait = holdsUntil.timeIntervalSinceNow
        guard wait > 0 else { return }
        try? await Task.sleep(for: .seconds(wait))
    }

    /// `foundNew`: the refresh brought something new, which shows right away; otherwise
    /// the spinner stays for `minimumDuration`. Either way it stays until `holdsUntil`.
    /// The indicator ends what it shows on its own.
    func endRefreshing(foundNew: Bool = true) {
        if isRefreshing, let shownOn {
            if !stoppedShowing { shownOn.stopLoading(then: nil) }
            self.shownOn = nil
            isRefreshing = false
            return
        }
        guard isRefreshing, pendingEnd == nil else { return }
        let remaining = max(foundNew ? 0 : Self.minimumDuration - Date().timeIntervalSince(startedAt),
                            holdsUntil.timeIntervalSinceNow)
        guard remaining > 0 else {
            finish()
            return
        }
        pendingEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            self?.pendingEnd = nil
            self?.finish()
        }
    }

    private func finish() {
        isRefreshing = false
        guard let scrollView else { return }
        let restingTop = scrollView.adjustedContentInset.top - inset
        UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.spinner.alpha = 0
            guard self.inset > 0 else { return }
            self.inset = 0
            self.onInsetChange?()
            if !scrollView.isDragging, scrollView.contentOffset.y < -restingTop {
                scrollView.contentOffset.y = -restingTop
            }
        } completion: { _ in
            if !self.isRefreshing { self.spinner.stopAnimating() }
        }
    }
}
