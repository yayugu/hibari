import Foundation
import Testing
import UIKit
@testable import hibari

@Suite("Pull to refresh indicator")
@MainActor
struct PullToRefreshIndicatorTests {
    /// Nothing to wait for: the update waiting for it lands at once.
    @Test func stoppingWhatNeverStartedEndsAtOnce() {
        let mark = RefreshMarkView(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
        var done = false
        mark.stopLoading { done = true }
        #expect(done)
    }

    private final class Indicator: PullToRefreshIndicator {
        var isShowingIndicator = true
        var pulls: [(CGFloat, Bool)] = []
        var starts = 0
        var stops = 0
        var completions: [() -> Void] = []

        func setPull(_ progress: CGFloat, holding: Bool) { pulls.append((progress, holding)) }
        func startLoading() { starts += 1 }
        func stopLoading(then completion: (() -> Void)?) {
            stops += 1
            if let completion { completions.append(completion) }
        }
    }

    private final class DraggedScrollView: UIScrollView {
        var isHeld = false
        override var isDragging: Bool { isHeld }
    }

    @Test func aPullShowsOnTheIndicatorWhichHoldsTheUpdateUntilItsHopsEnd() async {
        let scrollView = DraggedScrollView(frame: CGRect(x: 0, y: 0, width: 402, height: 240))
        let pull = PullToRefresh(scrollView: scrollView)
        let indicator = Indicator()
        pull.indicator = indicator
        var refreshes = 0
        pull.onRefresh = { refreshes += 1 }
        scrollView.isHeld = true
        pull.scrollViewWillBeginDragging(scrollView)
        scrollView.contentOffset.y = -15
        pull.scrollViewDidScroll(scrollView)
        #expect(indicator.pulls.last.map { $0.0 == 0.5 && $0.1 } == true)
        #expect(indicator.starts == 0)
        scrollView.contentOffset.y = -40
        pull.scrollViewDidScroll(scrollView)
        #expect(refreshes == 1)
        #expect(indicator.starts == 1)
        scrollView.isHeld = false
        pull.scrollViewWillEndDragging(scrollView)
        #expect(indicator.pulls.last?.1 == false)
        #expect(pull.inset > 0)

        var landed = false
        let wait = Task {
            await pull.waitForAnimation()
            landed = true
        }
        while indicator.completions.isEmpty { await Task.yield() }
        #expect(!landed)
        indicator.completions.forEach { $0() }
        await wait.value
        #expect(landed)
        pull.endRefreshing()
        #expect(indicator.stops == 1)
        #expect(!pull.isRefreshing)
        #expect(pull.inset == 0)
    }

    @Test func aTappedRefreshOpensTheHeaderRoomAndClosesItWhenDone() async {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 402, height: 240))
        let pull = PullToRefresh(scrollView: scrollView)
        let indicator = Indicator()
        pull.indicator = indicator
        var refreshes = 0
        pull.onRefresh = { refreshes += 1 }
        pull.onInsetChange = {
            scrollView.contentInset.top = pull.inset
        }

        pull.beginRefreshing()
        #expect(refreshes == 1)
        #expect(indicator.starts == 1)
        #expect(pull.inset > 0)
        #expect(scrollView.contentOffset.y == -pull.inset)

        let wait = Task { await pull.waitForAnimation() }
        while indicator.completions.isEmpty { await Task.yield() }
        indicator.completions.forEach { $0() }
        await wait.value
        pull.endRefreshing()
        #expect(indicator.stops == 1)
        #expect(!pull.isRefreshing)
        #expect(pull.inset == 0)
        #expect(scrollView.contentOffset.y == 0)
    }

    @Test func aFailedRefreshStopsTheIndicatorOnceAndClosesTheRoom() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 402, height: 240))
        let pull = PullToRefresh(scrollView: scrollView)
        let indicator = Indicator()
        pull.indicator = indicator
        pull.beginRefreshing()
        #expect(indicator.starts == 1)
        #expect(pull.inset > 0)
        pull.endRefreshing()
        pull.endRefreshing()
        #expect(indicator.stops == 1)
        #expect(pull.inset == 0)
    }

    @Test func withoutTheIndicatorOnScreenThePullShowsTheSpinner() {
        let scrollView = DraggedScrollView(frame: CGRect(x: 0, y: 0, width: 402, height: 240))
        let pull = PullToRefresh(scrollView: scrollView)
        let indicator = Indicator()
        indicator.isShowingIndicator = false
        pull.indicator = indicator
        scrollView.isHeld = true
        pull.scrollViewWillBeginDragging(scrollView)
        scrollView.contentOffset.y = -40
        pull.scrollViewDidScroll(scrollView)
        pull.scrollViewWillEndDragging(scrollView)
        #expect(indicator.pulls.isEmpty)
        #expect(indicator.starts == 0)
        #expect(pull.inset > 0)
    }
}
