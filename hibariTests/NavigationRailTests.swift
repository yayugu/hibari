import Testing
import UIKit
@testable import hibari

@Suite("Navigation rail")
@MainActor
struct NavigationRailTests {
    private func rail(height: CGFloat) -> NavigationRailView {
        let rail = NavigationRailView()
        rail.frame = CGRect(x: 0, y: 0, width: NavigationRailView.minimumWidth, height: height)
        rail.layoutIfNeeded()
        return rail
    }

    private func view(_ identifier: String, in rail: NavigationRailView) throws -> UIView {
        try #require(rail.subviews.first { $0.accessibilityIdentifier == identifier })
    }

    private func shown(in rail: NavigationRailView) -> [String] {
        rail.subviews.filter { !$0.isHidden && $0 is UIControl }.compactMap(\.accessibilityIdentifier)
    }

    private func menuTitles(in rail: NavigationRailView) throws -> [String] {
        let more = try #require(try view("rail.more", in: rail) as? UIButton)
        let sections = try #require(more.menu).children.compactMap { $0 as? UIMenu }
        return sections.flatMap(\.children).compactMap { ($0 as? UIAction)?.title }
    }

    @Test func aTallColumnShowsTheMarkAndEveryItemAboveTheComposeButton() throws {
        let rail = rail(height: 1000)
        #expect(shown(in: rail) == ["rail.home", "rail.search", "rail.notifications", "rail.bookmarks",
                                    "rail.profile", "rail.more", "rail.compose"])
        #expect(try view("rail.more", in: rail).frame.maxY < view("rail.compose", in: rail).frame.minY)
        #expect(rail.subviews.contains { $0.accessibilityLabel == "Hibari" && !$0.isHidden })
        #expect(try menuTitles(in: rail) == ["設定"])
    }

    @Test func aShortColumnMovesItemsIntoTheMenuFromTheLeastUsed() throws {
        let rail = rail(height: 300)
        #expect(shown(in: rail) == ["rail.home", "rail.search", "rail.notifications", "rail.more", "rail.compose"])
        #expect(!rail.subviews.contains { $0.accessibilityLabel == "Hibari" && !$0.isHidden })
        #expect(try view("rail.more", in: rail).frame.maxY < view("rail.compose", in: rail).frame.minY)
        #expect(try menuTitles(in: rail) == ["ブックマーク", "プロフィール", "設定"])

        rail.frame.size.height = 1000
        rail.layoutIfNeeded()
        #expect(try menuTitles(in: rail) == ["設定"])
    }
}
