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
        let app = launchSignedOut()
        let server = app.textFields["signIn.server"]
        XCTAssertTrue(server.waitForExistence(timeout: 10))
        XCTAssertEqual(server.value as? String, "misskey.io")
        XCTAssertTrue(app.buttons["signIn.button"].isEnabled)
    }
}
