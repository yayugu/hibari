import XCTest

final class TimelineUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testPostAndMediaNavigation() throws {
        try MockServer.requireRunning()
        let noteID = MockServer.postPlainNote()
        let app = XCUIApplication()
        app.launchArguments = MockServer.launchArguments
        app.launch()

        let timeline = app.collectionViews["timeline.home"]
        let note = MockServer.cell(noteID, in: timeline)
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        note.coordinate(withNormalizedOffset: MockServer.openingPoint).tap()
        XCTAssertTrue(app.collectionViews["noteDetail"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews["noteDetail.text"].exists)
        app.buttons["noteDetail.back"].tap()
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))

        note.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.55)).tap()
        let close = app.buttons["mediaViewer.back"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        app.otherElements["mediaViewer"].swipeDown(velocity: .fast)
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
    }
}
