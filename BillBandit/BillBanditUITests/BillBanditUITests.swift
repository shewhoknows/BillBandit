import XCTest

final class BillBanditUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCoreMoneyFlowSmoke() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-resetDemoData", "-tab", "0", "-skipOnboarding"]
        app.launch()

        XCTAssertTrue(app.staticTexts["BillBandit"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["₹142"].waitForExistence(timeout: 4))

        app.buttons["Open profile"].tap()
        let profileAvatarButton = app.buttons["profileAvatarButton"]
        XCTAssertTrue(profileAvatarButton.waitForExistence(timeout: 10))
        profileAvatarButton.tap()
        let progressToggle = app.buttons["Turn progress rewards off"]
        XCTAssertTrue(progressToggle.waitForExistence(timeout: 4))
        let addFriend = app.descendants(matching: .any)["profileAddFriendButton"]
        XCTAssertTrue(addFriend.waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["DEFAULT CURRENCY"].exists)
        XCTAssertFalse(app.staticTexts["REMINDERS"].exists)
        XCTAssertFalse(app.staticTexts["MASCOT MOTION"].exists)
        let progressWindow = app.descendants(matching: .any)["achievementPinShelf"]
        XCTAssertTrue(progressWindow.exists)
        progressToggle.tap()
        XCTAssertTrue(progressWindow.waitForNonExistence(timeout: 4))
        app.buttons["Turn progress rewards on"].tap()
        XCTAssertTrue(progressWindow.waitForExistence(timeout: 4))
        app.buttons["profileNameButton"].tap()
        let profileNameField = app.textFields["profileNameField"]
        XCTAssertTrue(profileNameField.waitForExistence(timeout: 4))
        profileNameField.typeText("\n")
        XCTAssertTrue(app.buttons["profileNameButton"].waitForExistence(timeout: 4))
        app.buttons["Home"].tap()

        app.buttons["See all groups"].tap()
        for _ in 0..<8 where !app.staticTexts["Goa Trip"].firstMatch.exists { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Goa Trip"].firstMatch.waitForExistence(timeout: 4))
        app.staticTexts["Goa Trip"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["BILLBANDIT & CO."].waitForExistence(timeout: 4))
        let balanceStamp = app.buttons["invoiceBalanceStamp"]
        XCTAssertTrue(balanceStamp.waitForExistence(timeout: 4))
        XCTAssertTrue(balanceStamp.label.contains("YOU OWE ₹18"))
        balanceStamp.tap()
        let balanceBreakdown = app.descendants(matching: .any)["invoiceBalanceBreakdown"]
        XCTAssertTrue(balanceBreakdown.waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["You owe Maya Chen"].waitForExistence(timeout: 4))
        attachScreenshot(named: "invoice-balance-breakdown")
        balanceStamp.tap()
        XCTAssertTrue(balanceBreakdown.waitForNonExistence(timeout: 4))

        let settleUp = app.buttons["Settle up"]
        XCTAssertTrue(settleUp.waitForExistence(timeout: 4))
        settleUp.tap()
        let settlementAmount = app.textFields["settlementAmountField"]
        XCTAssertTrue(settlementAmount.waitForExistence(timeout: 4))
        XCTAssertEqual(settlementAmount.value as? String, "18")
        app.buttons["settlementFrom-Arjun Rao"].tap()
        XCTAssertEqual(settlementAmount.value as? String, "8")
        app.buttons["Close Settle up"].tap()

        app.buttons["groupAddExpenseButton"].tap()
        XCTAssertTrue(app.staticTexts["Add expense"].waitForExistence(timeout: 4))
        let amount = app.textFields["expenseAmountField"]
        XCTAssertTrue(amount.waitForExistence(timeout: 4))
        amount.tap()
        amount.typeText("99")

        let title = app.textFields["expenseTitleField"]
        title.tap()
        title.typeText("Ui dinner")
        app.keyboards.buttons["Done"].tap()
        app.buttons["saveExpenseButton"].tap()

        XCTAssertTrue(app.staticTexts["Ui dinner"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.descendants(matching: .any)["rewardToast"].waitForExistence(timeout: 4))
        attachScreenshot(named: "reward-toast-achievement-badge")
        app.staticTexts["Ui dinner"].tap()
        XCTAssertTrue(app.buttons["Edit expense"].waitForExistence(timeout: 4))
        app.buttons["Edit expense"].tap()
        XCTAssertTrue(app.staticTexts["Edit expense"].waitForExistence(timeout: 4))
        XCTAssertEqual(app.textFields["expenseAmountField"].value as? String, "99")
        let editedTitle = app.textFields["expenseTitleField"]
        editedTitle.tap()
        editedTitle.typeText(" updated")
        app.keyboards.buttons["Done"].tap()
        app.buttons["saveExpenseButton"].tap()
        XCTAssertTrue(app.staticTexts["Ui dinner updated"].waitForExistence(timeout: 4))
        app.buttons["Delete expense"].tap()
        let eraseHeading = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "erase this receipt?")
        ).firstMatch
        XCTAssertTrue(eraseHeading.waitForExistence(timeout: 4))
        attachScreenshot(named: "delete-expense-confirmation")
    }

    func testMandatoryAppleSignInAppearsBeforeAppAccess() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-forceSignedOutOnboarding", "-onboardingPage", "2"]
        app.launch()

        XCTAssertTrue(app.buttons["onboardingSignInWithAppleButton"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["BillBandit"].exists)
        XCTAssertTrue(app.staticTexts["Sign in before entering your ledger"].exists)
        XCTAssertFalse(app.buttons["Enter BillBandit"].exists)
        XCTAssertFalse(app.buttons["tab-home"].exists)
        XCTAssertFalse(app.buttons["Home"].exists)
    }

    func testOnboardingSlidesKeepTheirContentAligned() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-forceSignedOutOnboarding", "-onboardingPage", "0"]
        app.launch()

        let firstMascot = app.descendants(matching: .any)["onboardingMascot-0"]
        let firstTitle = app.staticTexts["onboardingTitle-0"]
        XCTAssertTrue(firstMascot.waitForExistence(timeout: 8))
        XCTAssertTrue(firstTitle.exists)
        let mascotMidY = firstMascot.frame.midY
        let titleMidY = firstTitle.frame.midY

        app.buttons["Next"].tap()
        let secondMascot = app.descendants(matching: .any)["onboardingMascot-1"]
        let secondTitle = app.staticTexts["onboardingTitle-1"]
        XCTAssertTrue(secondMascot.waitForExistence(timeout: 4))
        XCTAssertLessThan(abs(secondMascot.frame.midY - mascotMidY), 3)
        XCTAssertLessThan(abs(secondTitle.frame.midY - titleMidY), 3)

        app.buttons["Next"].tap()
        let thirdMascot = app.descendants(matching: .any)["onboardingMascot-2"]
        let thirdTitle = app.staticTexts["onboardingTitle-2"]
        XCTAssertTrue(thirdMascot.waitForExistence(timeout: 4))
        XCTAssertLessThan(abs(thirdMascot.frame.midY - mascotMidY), 3)
        XCTAssertLessThan(abs(thirdTitle.frame.midY - titleMidY), 3)
        XCTAssertTrue(app.buttons["onboardingSignInWithAppleButton"].exists)
    }

    func testInviteFriendShowsShareableCodeAndJoinPath() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-resetDemoData", "-showAddFriend", "-skipOnboarding",
                               "-friendInvitePreview"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Invite friend"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["friendInviteQRCode"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["B4NDT-CREW2"].exists)
        XCTAssertTrue(app.buttons["shareFriendInvitationButton"].exists)
        app.buttons["enter code"].tap()
        XCTAssertTrue(app.textFields["friendInviteCodeField"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["acceptFriendInvitationButton"].isEnabled)
    }

    func testActivityBellShowsUnreadCountAndOpensGroupAwareLedger() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-resetDemoData", "-tab", "0", "-skipOnboarding"]
        app.launch()

        let activityBell = app.buttons["homeActivityBell"]
        XCTAssertTrue(activityBell.waitForExistence(timeout: 8))
        XCTAssertTrue(activityBell.label.contains("unread"))
        activityBell.tap()
        XCTAssertTrue(app.staticTexts["Activity"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["this month"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Maya Chen added “Taxi from airport” in Goa Trip"]
            .waitForExistence(timeout: 4))
    }

    func testSettlementPaymentIsBoundedByOutstandingDebt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-resetDemoData", "-tab", "1", "-skipOnboarding",
                               "-openGroup", "Goa Trip"]
        app.launch()

        XCTAssertTrue(app.staticTexts["BILLBANDIT & CO."].waitForExistence(timeout: 10))
        let settleUp = app.buttons["Settle up"]
        XCTAssertTrue(settleUp.waitForExistence(timeout: 5))
        settleUp.tap()
        let amount = app.textFields["settlementAmountField"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        XCTAssertEqual(amount.value as? String, "18")

        app.buttons["settlementFrom-Arjun Rao"].tap()
        XCTAssertEqual(amount.value as? String, "8")
        amount.tap()
        amount.typeText(XCUIKeyboardKey.delete.rawValue)
        amount.typeText("9")
        XCTAssertTrue(app.staticTexts["Maximum outstanding payment: ₹8."].exists)
        XCTAssertFalse(app.buttons["Record payment"].isEnabled)
    }

    func testNewGroupAppearsOnHomeImmediately() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-resetDemoData", "-tab", "0", "-skipOnboarding"]
        app.launch()

        XCTAssertTrue(app.buttons["New group"].waitForExistence(timeout: 8))
        app.buttons["New group"].tap()
        let name = app.textFields["groupNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.tap()
        name.typeText("Instant Crew")
        app.keyboards.buttons["Done"].tap()
        app.buttons["createGroupButton"].tap()

        XCTAssertTrue(app.staticTexts["Instant Crew"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.descendants(matching: .any)["rewardToast"].waitForExistence(timeout: 4))
        app.staticTexts["Instant Crew"].firstMatch.tap()
        let sleepingMascot = app.descendants(matching: .any)["emptyGroupSleepingMascot"]
        XCTAssertTrue(sleepingMascot.waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["no expenses on this invoice"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["BillBandit raccoon — neutral"].exists)
        XCTAssertTrue(app.staticTexts["ALL SQUARE"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["groupInviteButton"].exists)
        let allSquare = app.buttons["All square"]
        XCTAssertTrue(allSquare.exists)
        XCTAssertFalse(allSquare.isEnabled)
    }

    func testAvatarChoiceAppearsOnDashboard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-resetDemoData", "-tab", "0", "-skipOnboarding"]
        app.launch()

        let dashboardAvatar = app.buttons["Open profile"]
        XCTAssertTrue(dashboardAvatar.waitForExistence(timeout: 8))
        dashboardAvatar.tap()
        let headphones = app.descendants(matching: .any)["profileAvatar-headphones"]
        XCTAssertTrue(headphones.waitForExistence(timeout: 4))
        headphones.tap()
        XCTAssertTrue(app.descendants(matching: .any)["profileAvatar-flower"].exists)
        XCTAssertFalse(app.buttons["profileTabAvatar-headphones"].exists)
        app.buttons["profileAvatarButton"].tap()
        XCTAssertTrue(app.buttons["profileTabAvatar-headphones"].waitForExistence(timeout: 4))

        app.buttons["tab-home"].tap()
        XCTAssertTrue(app.buttons["dashboardProfileAvatar-headphones"].waitForExistence(timeout: 4))
    }

    func testAchievementShelfScrollsThroughEightPins() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-resetDemoData", "-showProfile", "-skipOnboarding"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Profile"].waitForExistence(timeout: 8))
        let shelf = app.descendants(matching: .any)["achievementPinShelf"]
        for _ in 0..<4 where !shelf.exists { app.swipeUp() }
        XCTAssertTrue(shelf.waitForExistence(timeout: 8))
        for _ in 0..<4 where !shelf.isHittable { app.swipeUp() }
        XCTAssertTrue(shelf.isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["achievement-initiativeTaker"].exists)
        attachScreenshot(named: "achievement-plain-row-start")

        shelf.swipeLeft()
        shelf.swipeLeft()
        let finalPin = app.descendants(matching: .any)["achievement-partnerInCrime"]
        XCTAssertTrue(finalPin.waitForExistence(timeout: 4))
        XCTAssertTrue(finalPin.isHittable)
        attachScreenshot(named: "achievement-plain-row-end")
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
