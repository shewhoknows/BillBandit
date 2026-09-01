import XCTest

final class ServerAuthorityUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The shared settlement control must not be reachable before a user has
    /// entered a server-backed ledger. This keeps the new substrate from
    /// widening the existing UI authority surface.
    func testSignedOutShellDoesNotExposeSharedSettlementControl() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-forceSignedOutOnboarding", "-onboardingPage", "2"]
        app.launch()

        XCTAssertTrue(app.staticTexts["BillBandit"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Settle up"].exists)
    }
}
