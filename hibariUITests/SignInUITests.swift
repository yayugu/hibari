import XCTest

final class SignInUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func launchSignedOut(server: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HibariTestAccounts", "YES", "-HibariSignOut", "YES"]
        if let server { app.launchArguments += ["-HibariSignInServer", server] }
        app.launch()
        return app
    }

    @MainActor
    func testSignInScreenAppearsWithoutAnAccount() {
        let app = launchSignedOut(server: "example.com")
        XCTAssertTrue(app.textFields["signIn.server"].waitForExistence(timeout: 10))
        // Not before agreeing to the terms.
        XCTAssertFalse(app.buttons["signIn.button"].isEnabled)
        app.buttons["signIn.terms"].tap()
        XCTAssertTrue(app.buttons["signIn.button"].isEnabled)
    }
}
