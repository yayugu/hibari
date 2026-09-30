import Testing
import UIKit
@testable import hibari

@Suite("Tab strip")
@MainActor
struct TabStripTests {
    private func strip(_ titles: [String], width: CGFloat = 402) -> TabStripView {
        let strip = TabStripView(titles: titles)
        strip.frame = CGRect(x: 0, y: 0, width: width, height: HeaderView.tabsHeight)
        strip.layoutIfNeeded()
        return strip
    }

    private func frame(ofTab index: Int, in strip: TabStripView) throws -> CGRect {
        func find(_ view: UIView) -> UIView? {
            view.accessibilityIdentifier == "tab.\(index)" ? view : view.subviews.lazy.compactMap(find).first
        }
        let tab = try #require(find(strip))
        return tab.convert(tab.bounds, to: strip)
    }

    @Test func tabsThatFitShareTheWidthEqually() throws {
        let strip = strip(["すべて", "メンション"])
        #expect(try frame(ofTab: 0, in: strip) == CGRect(x: 0, y: 0, width: 201, height: HeaderView.tabsHeight))
        #expect(try frame(ofTab: 1, in: strip).minX == 201)
    }

    @Test func timelinesWiderThanTheScreenScrollAlongWithThePager() throws {
        let titles = TimelineKind.allCases.map(\.title)
        let strip = strip(titles)
        let font = UIFont.systemFont(ofSize: 16, weight: .bold)
        for (index, title) in titles.enumerated() {
            let textWidth = (title as NSString).size(withAttributes: [.font: font]).width
            #expect(try frame(ofTab: index, in: strip).width >= textWidth + 44)
        }
        #expect(try frame(ofTab: 0, in: strip).minX == 0)
        #expect(try frame(ofTab: titles.count - 1, in: strip).maxX > 402)

        strip.setProgress(2)
        #expect(strip.selectedIndex == 2)
        #expect(abs(try frame(ofTab: 2, in: strip).midX - 201) < 0.5)
        strip.setProgress(CGFloat(titles.count - 1))
        #expect(abs(try frame(ofTab: titles.count - 1, in: strip).maxX - 402) < 0.5)
        strip.setProgress(0)
        #expect(try frame(ofTab: 0, in: strip).minX == 0)
    }
}
