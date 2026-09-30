import UIKit

@MainActor
final class BarsVisibilityController {
    /// 0 = fully shown, 1 = fully hidden.
    private(set) var progress: CGFloat = 0
    var distance: CGFloat = 88
    var onChange: ((CGFloat) -> Void)?

    private var lastOffset: CGFloat?

    func reset(for scrollView: UIScrollView) {
        lastOffset = scrollView.contentOffset.y
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let offset = scrollView.contentOffset.y
        defer { lastOffset = offset }
        guard let lastOffset else { return }
        let top = -scrollView.adjustedContentInset.top
        let bottom = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        if offset <= top {
            set(0)
            return
        }
        guard offset < bottom, lastOffset < bottom else { return }
        set(min(1, max(0, progress + (offset - lastOffset) / distance)))
    }

    func scrollViewDidEndScrolling(_ scrollView: UIScrollView) {
        let atTop = scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + distance
        let target: CGFloat = atTop ? 0 : (progress > 0.5 ? 1 : 0)
        guard target != progress else { return }
        set(target, animated: true)
    }

    func show(animated: Bool) {
        set(0, animated: animated)
    }

    private func set(_ value: CGFloat, animated: Bool = false) {
        guard value != progress || animated else { return }
        progress = value
        guard animated else {
            onChange?(value)
            return
        }
        UIView.animate(
            withDuration: 0.28, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.onChange?(value)
        }
    }
}
