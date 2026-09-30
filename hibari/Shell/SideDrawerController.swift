import UIKit

/// Content of a `SideDrawerController` that decides when a rightward swipe opens the
/// drawer: where it has no rightward swipe of its own (the first timeline, not the others
/// or pushed screens).
@MainActor
protocol SideDrawerContent: AnyObject {
    var allowsOpeningSideDrawer: Bool { get }
    /// How far the drawer is open (0...1), whenever it moves; called inside its
    /// animations, so changes made here animate along.
    func sideDrawerDidMove(_ progress: CGFloat)
}

extension SideDrawerContent {
    func sideDrawerDidMove(_ progress: CGFloat) {}
}

final class SideDrawerController: UIViewController {
    let drawer: UIViewController
    private(set) var content: UIViewController

    /// Where the drawer is heading: open (or opening) or closed.
    private(set) var isOpen = false

    private let contentContainer = UIView()
    private let contentShade = UIView()
    private let drawerShade = UIView()
    private let swipe = SideSwipeGestureRecognizer()
    private var scrollPansToCancel: [UIGestureRecognizer] = []
    private var progress: CGFloat = 0
    private var progressAtPanStart: CGFloat = 0
    private var animator: UIViewPropertyAnimator?
    private let feedback = UIImpactFeedbackGenerator(style: .light)

    private static let cornerRadius: CGFloat = 48
    private static let shadeOpacity: CGFloat = 1
    private static let drawerShadeOpacity: CGFloat = 0.7

    var drawerWidth: CGFloat { (view.bounds.width * 0.8).rounded() }

    init(content: UIViewController, drawer: UIViewController) {
        self.content = content
        self.drawer = drawer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var childForStatusBarStyle: UIViewController? { content }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .hibari(.background)

        addChild(drawer)
        view.addSubview(drawer.view)
        drawer.didMove(toParent: self)
        drawer.view.accessibilityElementsHidden = true
        drawerShade.backgroundColor = .black
        drawerShade.isUserInteractionEnabled = false
        view.addSubview(drawerShade)

        contentContainer.backgroundColor = .hibari(.background)
        contentContainer.layer.cornerCurve = .continuous
        contentContainer.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        view.addSubview(contentContainer)
        embed(content)

        contentShade.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.91, green: 0.91, blue: 1, alpha: 0.088)
                : UIColor(red: 0.06, green: 0.08, blue: 0.1, alpha: 0.2)
        }
        contentShade.isAccessibilityElement = true
        contentShade.accessibilityLabel = "メニューを閉じる"
        contentShade.accessibilityTraits = .button
        contentShade.accessibilityIdentifier = "drawer.close"
        contentShade.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(shadeTapped)))
        contentContainer.addSubview(contentShade)

        swipe.addTarget(self, action: #selector(swiped(_:)))
        swipe.delegate = self
        swipe.canStart = { [weak self] touch in
            guard let self, self.presentedViewController == nil else { return false }
            return self.isOpen || (self.content as? SideDrawerContent)?.allowsOpeningSideDrawer == true
                && !Self.canScrollBack(under: touch)
        }
        view.addGestureRecognizer(swipe)
        apply()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        drawer.view.frame = CGRect(x: 0, y: 0, width: drawerWidth, height: bounds.height)
        drawerShade.frame = drawer.view.frame
        let transform = contentContainer.transform
        contentContainer.transform = .identity
        contentContainer.frame = bounds
        contentContainer.transform = transform
        content.view.frame = contentContainer.bounds
        contentShade.frame = contentContainer.bounds
        if animator == nil { apply() }
    }

    /// Puts `controller` in place of the content, keeping the drawer where it is.
    func setContent(_ controller: UIViewController, animated: Bool) {
        guard controller !== content else { return }
        let old = content
        content = controller
        old.willMove(toParent: nil)
        embed(controller)
        setNeedsStatusBarAppearanceUpdate()
        let finish = {
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        guard animated, viewIfLoaded?.window != nil else {
            finish()
            return
        }
        controller.view.alpha = 0
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            controller.view.alpha = 1
        } completion: { _ in
            finish()
        }
    }

    private func embed(_ controller: UIViewController) {
        addChild(controller)
        controller.view.frame = contentContainer.bounds
        contentContainer.insertSubview(controller.view, belowSubview: contentShade)
        controller.didMove(toParent: self)
        controller.view.accessibilityElementsHidden = isOpen
        (controller as? SideDrawerContent)?.sideDrawerDidMove(progress)
    }

    /// `byUser`: the user tapped (the header's avatar, the dimmed content), so it gets the haptic.
    func open(animated: Bool, byUser: Bool = false) {
        if byUser && !isOpen { feedback.impactOccurred() }
        setOpen(true, animated: animated, velocity: 0)
    }

    func close(animated: Bool, byUser: Bool = false) {
        if byUser && isOpen { feedback.impactOccurred() }
        setOpen(false, animated: animated, velocity: 0)
    }

    private func setOpen(_ open: Bool, animated: Bool, velocity: CGFloat) {
        let changed = open != isOpen
        let target: CGFloat = open ? 1 : 0
        guard changed || animator != nil || progress != target else { return }
        isOpen = open
        stopAnimation()
        guard animated, viewIfLoaded?.window != nil else {
            progress = target
            apply()
            if changed { didChangeState() }
            return
        }
        let distance = (target - progress) * drawerWidth
        let relativeVelocity = abs(distance) > 1 ? max(0, velocity / distance) : 0
        let timing = UISpringTimingParameters(dampingRatio: 1, initialVelocity: CGVector(dx: relativeVelocity, dy: 0))
        let animator = UIViewPropertyAnimator(duration: 0.34, timingParameters: timing)
        progress = target
        prepareForMotion()
        animator.addAnimations { [self] in apply() }
        animator.addCompletion { [weak self] position in
            guard let self, position == .end else { return }
            self.animator = nil
            self.apply()
        }
        self.animator = animator
        animator.startAnimation()
        if changed { didChangeState() }
    }

    private func stopAnimation() {
        guard let animator else { return }
        let tx = contentContainer.layer.presentation()?.affineTransform().tx ?? contentContainer.transform.tx
        animator.stopAnimation(true)
        self.animator = nil
        progress = max(0, min(1, tx / max(1, drawerWidth)))
        apply()
    }

    private func prepareForMotion() {
        drawer.view.isHidden = false
        drawerShade.isHidden = false
        contentContainer.layer.cornerRadius = Self.cornerRadius
        contentContainer.clipsToBounds = true
    }

    private func apply() {
        let moving = progress > 0 || animator != nil || swipe.state == .changed
        contentContainer.transform = CGAffineTransform(translationX: drawerWidth * progress, y: 0)
        contentShade.alpha = Self.shadeOpacity * progress
        drawerShade.alpha = Self.drawerShadeOpacity * (1 - progress)
        (content as? SideDrawerContent)?.sideDrawerDidMove(progress)
        guard animator == nil else { return }
        drawer.view.isHidden = !moving
        drawerShade.isHidden = !moving
        contentContainer.layer.cornerRadius = moving ? Self.cornerRadius : 0
        contentContainer.clipsToBounds = moving
        contentShade.isUserInteractionEnabled = isOpen
    }

    private func didChangeState() {
        contentShade.isUserInteractionEnabled = isOpen
        content.view.accessibilityElementsHidden = isOpen
        drawer.view.accessibilityElementsHidden = !isOpen
        UIAccessibility.post(notification: .screenChanged, argument: isOpen ? drawer.view : nil)
    }

    @objc private func shadeTapped() {
        close(animated: true, byUser: true)
    }

    override func accessibilityPerformEscape() -> Bool {
        guard isOpen else { return false }
        close(animated: true)
        return true
    }

    @objc private func swiped(_ swipe: SideSwipeGestureRecognizer) {
        switch swipe.state {
        case .began:
            for scrollPan in scrollPansToCancel where scrollPan.state == .began || scrollPan.state == .changed {
                scrollPan.isEnabled = false
                scrollPan.isEnabled = true
            }
            scrollPansToCancel = []
            feedback.prepare()
            stopAnimation()
            progressAtPanStart = progress
            prepareForMotion()
            fallthrough
        case .changed:
            let dx = swipe.translation(in: view).x
            progress = max(0, min(1, progressAtPanStart + dx / max(1, drawerWidth)))
            apply()
        case .ended, .cancelled, .failed:
            let velocity = swipe.velocity(in: view).x
            let open: Bool
            if swipe.state != .ended {
                open = isOpen
            } else if abs(velocity) > 300 {
                open = velocity > 0
            } else {
                open = progress > 0.5
            }
            if swipe.state == .ended && open != isOpen { feedback.impactOccurred() }
            setOpen(open, animated: true, velocity: velocity)
        default:
            break
        }
    }
}

extension SideDrawerController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === swipe else { return true }
        let dx = swipe.translation(in: view).x
        return isOpen ? dx < 0 : dx > 0
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === swipe, let scrollView = other.view as? UIScrollView,
              other === scrollView.panGestureRecognizer, other.state == .began || other.state == .changed
        else { return false }
        if !scrollPansToCancel.contains(other) { scrollPansToCancel.append(other) }
        return true
    }

    private static func canScrollBack(under touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if let scrollView = current as? UIScrollView,
               scrollView.contentSize.width > scrollView.bounds.width + 0.5,
               scrollView.contentOffset.x > -scrollView.adjustedContentInset.left + 0.5 {
                return true
            }
            view = current.superview
        }
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === swipe, let scrollView = other.view as? UIScrollView,
              other === scrollView.panGestureRecognizer
        else { return false }
        return scrollView.contentSize.width > scrollView.bounds.width + 0.5
    }
}
