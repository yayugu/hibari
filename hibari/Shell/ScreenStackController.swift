import UIKit

final class ScreenStackController: UINavigationController, UIGestureRecognizerDelegate {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .hibari(.background)
        isNavigationBarHidden = true
        interactivePopGestureRecognizer?.delegate = self
        interactiveContentPopGestureRecognizer?.delegate = self
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard viewControllers.count > 1, transitionCoordinator == nil else { return false }
        guard gesture === interactiveContentPopGestureRecognizer, let screen = topViewController as? BackSwipeGating
        else { return true }
        return screen.allowsContentBackSwipe
    }
}

/// A screen with pages side by side (`BackSwipePager`): a swipe on them goes back from the
/// first page only (on the others it pages). The content swipe asks as the touch lands, so
/// there is no direction to go by yet; it only follows rightward drags itself. The swipe
/// from the edge always goes back.
@MainActor
protocol BackSwipeGating {
    var allowsContentBackSwipe: Bool { get }
}

final class BackSwipePager: UIScrollView {
    private static let edgeWidth: CGFloat = 24

    var isAtFirstPage: Bool { contentOffset.x <= 0.5 }

    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        if gesture === panGestureRecognizer {
            let pan = panGestureRecognizer
            let start = pan.location(in: window).x - pan.translation(in: window).x
            let rightward = pan.velocity(in: self).x > 0
            if rightward && (start < Self.edgeWidth || isAtFirstPage) { return false }
        }
        return super.gestureRecognizerShouldBegin(gesture)
    }
}
