import UIKit

final class MediaViewerTransition: NSObject, UIViewControllerTransitioningDelegate {
    func presentationController(forPresented presented: UIViewController, presenting: UIViewController?,
                                source: UIViewController) -> UIPresentationController? {
        MediaViewerPresentationController(presentedViewController: presented, presenting: presenting)
    }

    func animationController(forPresented presented: UIViewController, presenting: UIViewController,
                             source: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        MediaZoomAnimator(isPresenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        MediaZoomAnimator(isPresenting: false)
    }
}

private final class MediaViewerPresentationController: UIPresentationController {
    override var shouldRemovePresentersView: Bool { false }
}

private final class MediaZoomAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    let isPresenting: Bool

    init(isPresenting: Bool) {
        self.isPresenting = isPresenting
    }

    func transitionDuration(using context: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        isPresenting ? 0.42 : 0.36
    }

    func animateTransition(using context: any UIViewControllerContextTransitioning) {
        if isPresenting {
            present(context)
        } else {
            dismiss(context)
        }
    }

    /// Puts the viewer on screen and ends the transition straight away: UIKit drops every
    /// touch that starts before the transition ends, and the viewer should take them while the
    /// image is still zooming in. The viewer runs the zoom itself (`prepareEntrance`).
    private func present(_ context: any UIViewControllerContextTransitioning) {
        guard let viewer = context.viewController(forKey: .to) as? MediaViewerController else {
            context.completeTransition(false)
            return
        }
        viewer.view.frame = context.finalFrame(for: viewer)
        context.containerView.addSubview(viewer.view)
        viewer.view.layoutIfNeeded()
        viewer.prepareEntrance(duration: transitionDuration(using: context))
        context.completeTransition(true)
    }

    private func dismiss(_ context: any UIViewControllerContextTransitioning) {
        guard let viewer = context.viewController(forKey: .from) as? MediaViewerController else {
            context.completeTransition(false)
            return
        }
        let container = context.containerView
        let index = viewer.currentIndex
        let startFrame = viewer.currentImageFrame(in: container)
        let target = viewer.source.target(index)
        let velocity = viewer.releaseVelocity
        let duration = transitionDuration(using: context)

        guard let image = viewer.currentImage else {
            let animator = UIViewPropertyAnimator(duration: duration, dampingRatio: 1)
            animator.addAnimations { viewer.view.alpha = 0 }
            animator.addCompletion { _ in
                viewer.source.setHidden(nil)
                context.completeTransition(!context.transitionWasCancelled)
            }
            animator.startAnimation()
            return
        }

        let copy = Self.imageCopy(image, frame: startFrame)
        copy.layer.cornerRadius = viewer.currentImageCornerRadius
        container.addSubview(copy)
        viewer.setPagesHidden(true)

        let endFrame: CGRect
        var endAlpha: CGFloat = 1
        if let target {
            endFrame = container.convert(target.frame, from: nil)
            copy.layer.maskedCorners = target.corners
        } else {
            let direction: CGFloat = velocity.y < 0 ? -1 : 1
            endFrame = startFrame.offsetBy(dx: 0, dy: direction * container.bounds.height * 0.6)
            endAlpha = 0
        }
        let distance = max(1, abs(endFrame.midY - startFrame.midY))
        let spring = UISpringTimingParameters(dampingRatio: 0.9,
                                              initialVelocity: CGVector(dx: 0, dy: min(8, abs(velocity.y) / distance)))
        let animator = UIViewPropertyAnimator(duration: duration, timingParameters: spring)
        animator.addAnimations {
            copy.frame = endFrame
            copy.alpha = endAlpha
            copy.layer.cornerRadius = target?.cornerRadius ?? 0
            viewer.backdrop.alpha = 0
            viewer.setChromeAlpha(0)
        }
        animator.addCompletion { _ in
            viewer.source.setHidden(nil)
            copy.removeFromSuperview()
            context.completeTransition(!context.transitionWasCancelled)
        }
        animator.startAnimation()
    }

    private static func imageCopy(_ image: UIImage, frame: CGRect) -> UIImageView {
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.frame = frame
        return view
    }
}
