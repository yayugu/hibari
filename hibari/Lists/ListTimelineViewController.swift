import UIKit

final class ListTimelineViewController: UIViewController {
    let services: NoteServices
    private let timelineTab: TimelineTab

    private lazy var header = NavigationHeaderView(title: timelineTab.title, identifier: "listTimeline")
    private let statusBarBackdrop = UIView()
    private var timeline: TimelineViewController?
    private let bars = BarsVisibilityController()

    init(tab: TimelineTab, services: NoteServices) {
        self.timelineTab = tab
        self.services = services
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .hibari(.background)
        view.accessibilityIdentifier = "listTimeline"

        if let client = services.client {
            let page = timelineTab.timeline(client: client)
            let timeline = TimelineViewController(timelineID: page.id, source: page.source, services: services)
            timeline.emptyMessage = page.emptyMessage
            timeline.scrollObserver = self
            timeline.onAuthenticationFailure = { [weak self] in self?.services.onAuthenticationFailure?() }
            addChild(timeline)
            view.addSubview(timeline.view)
            timeline.didMove(toParent: self)
            self.timeline = timeline
        }

        statusBarBackdrop.backgroundColor = .hibari(.background)
        view.addSubview(header)
        view.addSubview(statusBarBackdrop)
        bars.onChange = { [weak self] progress in self?.applyBars(progress) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let safe = view.safeAreaInsets

        timeline?.view.frame = bounds
        timeline?.contentInsets = UIEdgeInsets(top: safe.top + header.height, left: 0, bottom: safe.bottom, right: 0)

        statusBarBackdrop.frame = CGRect(x: 0, y: 0, width: bounds.width, height: safe.top)
        header.transform = .identity
        header.frame = CGRect(x: 0, y: safe.top, width: bounds.width, height: header.height)
        bars.distance = NavigationHeaderView.rowHeight
        applyBars(bars.progress)
    }

    private func applyBars(_ progress: CGFloat) {
        header.transform = CGAffineTransform(translationX: 0, y: -NavigationHeaderView.rowHeight * progress)
        header.rowView.alpha = 1 - progress
    }
}

extension ListTimelineViewController: TimelineScrollObserver {
    func timelineDidScroll(_ scrollView: UIScrollView) {
        bars.scrollViewDidScroll(scrollView)
    }

    func timelineDidEndScrolling(_ scrollView: UIScrollView) {
        bars.scrollViewDidEndScrolling(scrollView)
    }

    func timelineDidMoveContent(_ scrollView: UIScrollView) {
        bars.reset(for: scrollView)
    }
}
