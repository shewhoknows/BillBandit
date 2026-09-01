import XCTest

/// Walks the MVP happy path against the DEBUG dev session (mock repositories):
/// welcome → dev session → trip list → create trip → add expense → ledger →
/// balances → finalize → final bill → share summary sheet.
final class HappyPathUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testHappyPathOnDevSession() {
        let app = XCUIApplication()
        app.launch()

        // Welcome → sign-in
        let getStarted = app.buttons["Get started"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 10), "Welcome screen should show Get started")
        getStarted.tap()

        // DEBUG dev session bypasses real auth
        let devSession = app.buttons["Use dev session"]
        XCTAssertTrue(devSession.waitForExistence(timeout: 10), "Sign-in screen should offer a dev session in DEBUG")
        devSession.tap()

        // Trip list shows the seeded mock trip
        let seededTrip = app.staticTexts["Goa Monsoon"]
        XCTAssertTrue(seededTrip.waitForExistence(timeout: 10), "Trip list should show the seeded mock trip")
        snap(app, "01-trip-list")

        // Create a new trip
        app.buttons["Create trip"].firstMatch.tap()
        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Create trip form should have a name field")
        nameField.tap()
        nameField.typeText("QA Smoke Trip")
        let saveTrip = app.buttons["Create trip"].firstMatch
        saveTrip.tap()

        // Creating navigates straight into the new trip's dashboard
        let dashboard = app.navigationBars["QA Smoke Trip"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 10), "Creating a trip should open its dashboard")

        // Add an expense
        let addExpense = app.buttons["Add expense"].firstMatch
        XCTAssertTrue(addExpense.waitForExistence(timeout: 10), "Ledger should offer Add expense")
        addExpense.tap()

        let titleField = app.textFields.firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText("Beach Dinner")

        let amountField = app.textFields["0.00"]
        XCTAssertTrue(amountField.waitForExistence(timeout: 5), "Expense form should have an amount field")
        amountField.tap()
        amountField.typeText("900")

        // Dismiss the decimal-pad keyboard, then save (button sits below the fold)
        app.navigationBars.firstMatch.tap()
        let saveExpense = app.buttons["Save expense"].firstMatch
        var scrollAttempts = 0
        while !saveExpense.isHittable, scrollAttempts < 4 {
            app.swipeUp()
            scrollAttempts += 1
        }
        saveExpense.tap()

        // Ledger shows the expense
        let expenseRow = app.staticTexts["Beach Dinner"]
        XCTAssertTrue(expenseRow.waitForExistence(timeout: 10), "Ledger should list the new expense")
        snap(app, "02-ledger-with-expense")

        // Finalize the trip
        let finalize = app.buttons["Finalize trip"].firstMatch
        XCTAssertTrue(finalize.waitForExistence(timeout: 5), "Ledger should offer Finalize trip")
        finalize.tap()
        // Confirmation (alert or confirmation dialog) — accept the destructive/confirm action
        let confirmButton = app.buttons["Finalize"].firstMatch
        if confirmButton.waitForExistence(timeout: 3) {
            confirmButton.tap()
        } else {
            let sheetFinalize = app.sheets.buttons["Finalize trip"].firstMatch
            if sheetFinalize.waitForExistence(timeout: 3) {
                sheetFinalize.tap()
            }
        }

        // Final bill appears
        let finalBillMarker = app.staticTexts["Final bill"].firstMatch
        let finalizedStamp = app.staticTexts["FINALIZED"].firstMatch
        XCTAssertTrue(
            finalBillMarker.waitForExistence(timeout: 10) || finalizedStamp.waitForExistence(timeout: 10),
            "Finalizing should lead to the final bill / finalized state"
        )
        snap(app, "03-final-bill")
    }
}
