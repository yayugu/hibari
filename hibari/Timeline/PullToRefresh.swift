import UIKit

@MainActor
final class PullToRefresh {
    static let triggerDistance: CGFloat = 30
    static let minimumDuration: TimeInterval = 0.8
    private static let room: CGFloat = 40

    var onRefresh: (() -> Void)?
    /// `inset` changed: the owner puts it into the content inset (inside an animation
    /// when it goes back to 0).
    var onInsetChange: (() -> Void)?
    /// Extra room at the top of the content while refreshing.
    private(set) var inset: CGFloat = 0
    private(set) var isRefreshing = false

    private weak var scrollView: UIScrollView?
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let feedback = UIImpactFeedbackGenerator(style: .medium)
    private var armed = true
    private var startedAt = Date.distantPast
    private var pendingEnd: Task<Void, Never>?

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

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let distance = pulled(scrollView)
        spinner.center = CGPoint(x: scrollView.bounds.midX, y: -max(distance, Self.room) / 2)
        if !isRefreshing {
            spinner.alpha = min(1, max(0, (distance - 8) / (Self.triggerDistance - 8)))
            if distance <= 1 { armed = true }
        }
        guard armed, !isRefreshing, scrollView.isDragging, distance >= Self.triggerDistance else { return }
        armed = false
        isRefreshing = true
        startedAt = Date()
        spinner.alpha = 1
        spinner.startAnimating()
        feedback.impactOccurred()
        onRefresh?()
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView) {
        guard isRefreshing, inset == 0, pulled(scrollView) > 0 else { return }
        inset = Self.room
        onInsetChange?()
    }

    /// `foundNew`: the refresh brought something new, which shows right away; otherwise
    /// the spinner stays for `minimumDuration`.
    func endRefreshing(foundNew: Bool = true) {
        guard isRefreshing, pendingEnd == nil else { return }
        let remaining = foundNew ? 0 : Self.minimumDuration - Date().timeIntervalSince(startedAt)
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
