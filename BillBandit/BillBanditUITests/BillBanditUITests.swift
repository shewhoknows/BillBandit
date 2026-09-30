import XCTest

final class BillBanditUITests: XCTestCase {
    private func syntheticLocalApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = ["BILLBANDIT_QA_STORE_ID": "vietnam-test-local-ui",
                                 "BILLBANDIT_QA_BASE_URL": "http://127.0.0.1:31300",
                                 "BILLBANDIT_QA_TOKEN": ""]
        return app
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCoreMoneyFlowSmoke() throws {
        let app = syntheticLocalApp()
        app.launchArguments = ["-resetDemoData", "-tab", "0", "-skipOnboarding"]
        app.launch()

        XCTAssertTrue(app.staticTexts["BillBandit"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Your groups"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["₹142"].exists)

        app.buttons["Open profile"].tap()
        let profileAvatarButton = app.buttons["profileAvatarButton"]
        XCTAssertTrue(profileAvatarButton.waitForExistence(timeout: 10))
        profileAvatarButton.tap()
        let progressToggle = app.buttons["Turn progress rewards off"]
        XCTAssertTrue(progressToggle.waitForExistence(timeout: 4))
        let addFriend = app.descendants(matching: .any)["profileAddFriendButton"]
        XCTAssertTrue(addFriend.waitForExistence(timeout: 4))
        let deleteAccountButton = app.buttons["deleteAccountButton"]
        XCTAssertTrue(deleteAccountButton.waitForExistence(timeout: 4))
        XCTAssertEqual(deleteAccountButton.label, "Delete account")
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
        XCTAssertFalse(app.buttons["None"].exists)
        XCTAssertTrue(app.buttons["Goa Trip"].exists)
        let amount = app.textFields["expenseAmountField"]
        XCTAssertTrue(amount.waitForExistence(timeout: 4))
        amount.tap()
        amount.typeText("99")

        let title = app.textFields["expenseTitleField"]
        title.tap()
        title.typeText("Ui dinner")
        let saveWithKeyboard = app.buttons["saveExpenseButton"]
        XCTAssertTrue(saveWithKeyboard.isHittable)
        XCTAssertLessThan(saveWithKeyboard.frame.maxY, app.keyboards.firstMatch.frame.minY)
        title.typeText("\n")
        let saveWithoutKeyboard = app.buttons["saveExpenseButton"]
        XCTAssertLessThan(app.windows.firstMatch.frame.maxY - saveWithoutKeyboard.frame.maxY, 110)
        attachScreenshot(named: "expense-save-footer")
        saveWithoutKeyboard.tap()

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
        editedTitle.typeText("\n")
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
        let app = syntheticLocalApp()
        app.launchArguments = ["-forceSignedOutOnboarding", "-onboardingPage", "2"]
        app.launch()

        XCTAssertTrue(app.buttons["onboardingSignInWithAppleButton"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["BillBandit"].exists)
        XCTAssertTrue(app.staticTexts["Sign in before entering your ledger"].exists)
        XCTAssertFalse(app.buttons["Enter BillBandit"].exists)
        XCTAssertFalse(app.buttons["tab-home"].exists)
        XCTAssertFalse(app.buttons["Home"].exists)
    }

    func testAppleSignInButtonStaysInFormAndFailureIsVisible() throws {
        let app = syntheticLocalApp()
        let baseArguments = ["-forceSignedOutOnboarding", "-onboardingPage", "2"]
        app.launchArguments = baseArguments
        app.launch()
        let button = app.buttons["onboardingSignInWithAppleButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 8))
        let initialY = button.frame.midY

        app.terminate()
        app.launchArguments = baseArguments + ["-onboardingAuthBusyPreview"]
        app.launch()
        XCTAssertTrue(button.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["onboardingAppleSignInMessage"].exists)
        XCTAssertLessThan(abs(button.frame.midY - initialY), 48)

        app.terminate()
        app.launchArguments = baseArguments + ["-onboardingAuthErrorPreview"]
        app.launch()
        XCTAssertTrue(button.waitForExistence(timeout: 8))
        let message = app.staticTexts["onboardingAppleSignInMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 4))
        XCTAssertTrue(message.isHittable)
        XCTAssertTrue(message.label.contains("Try again"))
        XCTAssertTrue(button.isHittable)
        XCTAssertLessThan(abs(button.frame.midY - initialY), 48)
    }

    func testConnectedAppleAccountRequiresUsernameBeforeCompletingOnboarding() throws {
        let app = syntheticLocalApp()
        app.launchArguments = [
            "-onboardingConnectedIncomplete",
            "-onboardingPage", "2",
        ]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["onboardingAppleConnected"].waitForExistence(timeout: 8))
        let enter = app.buttons["onboardingEnterBillBanditButton"]
        XCTAssertTrue(enter.waitForExistence(timeout: 4))
        enter.tap()

        let error = app.staticTexts["onboardingUsernameError"]
        XCTAssertTrue(error.waitForExistence(timeout: 4))
        XCTAssertEqual(error.label, "Username is required to complete onboarding.")
        attachScreenshot(named: "onboarding-username-required")

        let field = app.textFields["onboardingUsernameField"]
        field.tap()
        field.typeText("Bubby")
        XCTAssertFalse(error.exists)
        field.typeText("\n")
        let enterHittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == YES"), object: enter
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enterHittable], timeout: 4), .completed)
        enter.tap()
        XCTAssertTrue(app.buttons["tab-home"].waitForExistence(timeout: 6))
    }

    func testOnboardingSlidesKeepTheirContentAligned() throws {
        let app = syntheticLocalApp()
        app.launchArguments = ["-forceSignedOutOnboarding", "-onboardingPage", "0"]
        app.launch()

        let firstMascot = app.descendants(matching: .any)["onboardingMascot-0"]
        let firstTitle = app.staticTexts["onboardingTitle-0"]
        let swipeHint = app.descendants(matching: .any)["onboardingSwipeHint"]
        let pageIndicator = app.descendants(matching: .any)["onboardingPageIndicator"]
        XCTAssertTrue(firstMascot.waitForExistence(timeout: 8))
        XCTAssertTrue(firstTitle.exists)
        XCTAssertTrue(swipeHint.waitForExistence(timeout: 4))
        XCTAssertTrue(pageIndicator.waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["Next"].exists)
        let indicatorBottomGap = app.windows.firstMatch.frame.maxY - pageIndicator.frame.maxY
        XCTAssertGreaterThan(indicatorBottomGap, 0)
        XCTAssertLessThan(indicatorBottomGap, 80)
        let mascotMidY = firstMascot.frame.midY
        let titleMidY = firstTitle.frame.midY

        app.swipeLeft()
        let secondMascot = app.descendants(matching: .any)["onboardingMascot-1"]
        let secondTitle = app.staticTexts["onboardingTitle-1"]
        XCTAssertTrue(secondMascot.waitForExistence(timeout: 4))
        XCTAssertFalse(swipeHint.exists)
        XCTAssertFalse(app.buttons["Next"].exists)
        XCTAssertLessThan(abs(secondMascot.frame.midY - mascotMidY), 3)
        XCTAssertLessThan(abs(secondTitle.frame.midY - titleMidY), 3)

        app.swipeLeft()
        let thirdMascot = app.descendants(matching: .any)["onboardingMascot-2"]
        let thirdTitle = app.staticTexts["onboardingTitle-2"]
        XCTAssertTrue(thirdMascot.waitForExistence(timeout: 4))
        XCTAssertLessThan(abs(thirdMascot.frame.midY - mascotMidY), 3)
        XCTAssertLessThan(abs(thirdTitle.frame.midY - titleMidY), 3)
        XCTAssertTrue(app.buttons["onboardingSignInWithAppleButton"].exists)
    }

    func testInviteFriendShowsShareableCodeAndJoinPath() throws {
        let app = syntheticLocalApp()
        app.launchArguments = ["-resetDemoData", "-showAddFriend", "-skipOnboarding",
                               "-friendInvitePreview"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Invite friend"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["friendInviteQRCode"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["B4NDT"].exists)
        XCTAssertTrue(app.buttons["shareFriendInvitationButton"].exists)
        app.buttons["enter code"].tap()
        XCTAssertTrue(app.textFields["friendInviteCodeField"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["acceptFriendInvitationButton"].isEnabled)
    }

    func testActivityBellShowsUnreadCountAndOpensGroupAwareLedger() throws {
        let app = syntheticLocalApp()
        app.launchArguments = ["-resetDemoData", "-tab", "0", "-skipOnboarding"]
        app.launch()

        let activityBell = app.buttons["homeActivityBell"]
        XCTAssertTrue(activityBell.waitForExistence(timeout: 8))
        XCTAssertTrue(activityBell.label.contains("unread"))
        activityBell.tap()
        XCTAssertTrue(app.staticTexts["Activity"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Maya Chen added “Taxi from airport” in Goa Trip"]
            .waitForExistence(timeout: 4))
    }

    func testSettlementPaymentIsBoundedByOutstandingDebt() throws {
        let app = syntheticLocalApp()
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

    func testLocalGroupDeleteRequiresConfirmationAndCancelPreservesGroup() throws {
        let app = syntheticLocalApp()
        app.launchArguments = ["-resetDemoData", "-tab", "1", "-skipOnboarding"]
        app.launch()

        let group = app.staticTexts["Goa Trip"].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 8))
        group.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 4))
        delete.tap()

        XCTAssertTrue(app.staticTexts["Delete this group?"].waitForExistence(timeout: 4))
        attachScreenshot(named: "populated-local-group-delete-confirmation")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(group.waitForExistence(timeout: 4))

        group.swipeLeft()
        XCTAssertTrue(delete.waitForExistence(timeout: 4))
        delete.tap()
        app.buttons["Delete Group"].tap()
        XCTAssertTrue(group.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Friday Pizza"].waitForExistence(timeout: 4))
        attachScreenshot(named: "populated-local-group-deleted-after-confirmation")
    }

    func testNewGroupAppearsOnHomeImmediately() throws {
        let app = syntheticLocalApp()
        app.launchArguments = ["-resetDemoData", "-tab", "0", "-skipOnboarding"]
        app.launch()

        XCTAssertTrue(app.buttons["New group"].waitForExistence(timeout: 8))
        app.buttons["New group"].tap()
        let name = app.textFields["groupNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["You · you"].exists)
        XCTAssertTrue(app.staticTexts["No friends yet. Invite a friend to share a group."].exists)
        XCTAssertTrue(app.buttons["groupInviteFriendButton"].exists)
        name.tap()
        name.typeText("Instant Crew")
        let createWithKeyboard = app.buttons["createGroupButton"]
        XCTAssertTrue(createWithKeyboard.isHittable)
        XCTAssertLessThan(createWithKeyboard.frame.maxY, app.keyboards.firstMatch.frame.minY)
        name.typeText("\n")
        XCTAssertLessThan(app.windows.firstMatch.frame.maxY - createWithKeyboard.frame.maxY, 110)
        attachScreenshot(named: "group-create-footer")
        createWithKeyboard.tap()

        XCTAssertTrue(app.staticTexts["Instant Crew"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.descendants(matching: .any)["rewardToast"].waitForExistence(timeout: 4))
        app.staticTexts["Instant Crew"].firstMatch.tap()
        let sleepingMascot = app.descendants(matching: .any)["emptyGroupSleepingMascot"]
        XCTAssertTrue(sleepingMascot.waitForExistence(timeout: 4))
        let emptyCopy = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "no expenses on this invoice")
        ).firstMatch
        XCTAssertTrue(emptyCopy.waitForExistence(timeout: 4))
        XCTAssertFalse(app.descendants(matching: .any)["BillBandit raccoon — neutral"].exists)
        XCTAssertTrue(app.staticTexts["ALL SQUARE"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["groupInviteButton"].exists)
        let addMembers = app.buttons["groupAddMembersButton"]
        XCTAssertTrue(addMembers.exists)
        addMembers.tap()
        XCTAssertTrue(app.staticTexts["No more friends to add. Invite a friend first."].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["confirmAddMemberButton"].isEnabled)
        XCTAssertTrue(app.buttons["addMemberInviteFriendButton"].exists)
        app.buttons["Close Add members"].tap()
        let allSquare = app.buttons["All square"]
        XCTAssertTrue(allSquare.exists)
        XCTAssertFalse(allSquare.isEnabled)
        app.terminate()
        app.launchArguments = ["-skipOnboarding", "-tab", "0"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Instant Crew"].firstMatch.waitForExistence(timeout: 8))
    }

    func testServerLinkedGroupKeepsAddExpenseEnabled() throws {
        let app = syntheticLocalApp()
        app.launchArguments = [
            "-resetDemoData",
            "-sharedSettleUpGroupId=ui-shared-group",
            "-tab", "1",
            "-skipOnboarding",
            "-openGroup", "Goa Trip",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["BILLBANDIT & CO."].waitForExistence(timeout: 10))
        let addExpense = app.buttons["groupAddExpenseButton"]
        XCTAssertTrue(addExpense.waitForExistence(timeout: 5))
        XCTAssertTrue(addExpense.isEnabled)
        addExpense.tap()
        XCTAssertTrue(app.textFields["expenseAmountField"].waitForExistence(timeout: 5))
    }

    func testAvatarChoiceAppearsOnDashboard() throws {
        let app = syntheticLocalApp()
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
        let app = syntheticLocalApp()
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

    func testProfileNameHasAFullUnclippedLineBox() throws {
        let app = syntheticLocalApp()
        app.launchArguments = ["-resetDemoData", "-showProfile", "-skipOnboarding"]
        app.launch()

        let name = app.buttons["profileNameButton"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        XCTAssertGreaterThanOrEqual(name.frame.height, 44)
        XCTAssertGreaterThanOrEqual(name.frame.minX, 20)
        XCTAssertLessThanOrEqual(name.frame.maxX, app.frame.maxX - 20)

        name.tap()
        let field = app.textFields["profileNameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20))
        field.typeText("Bubby")
        XCTAssertEqual(field.value as? String, "Bubby")
        attachScreenshot(named: "profile-name-editing-caret-gap")
    }

    func testContextualDockAndExpenseActivityNavigation() throws {
        let app = syntheticLocalApp()
        app.launchArguments = ["-resetDemoData", "-tab", "1", "-skipOnboarding"]
        app.launch()

        let dock = app.buttons["contextualAddButton"]
        XCTAssertTrue(dock.waitForExistence(timeout: 8))
        XCTAssertEqual(dock.label, "New group")
        attachScreenshot(named: "groups-header-contextual-dock")
        dock.tap()
        XCTAssertTrue(app.textFields["groupNameField"].waitForExistence(timeout: 4))
        app.buttons["Close New group"].tap()

        let group = app.staticTexts["Goa Trip"].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 8))
        group.tap()
        XCTAssertTrue(app.staticTexts["BILLBANDIT & CO."].waitForExistence(timeout: 5))
        XCTAssertEqual(dock.label, "Add expense")
        dock.tap()
        XCTAssertTrue(app.textFields["expenseAmountField"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Goa Trip"].exists)
        attachScreenshot(named: "group-dock-expense-context")

        app.buttons["Close Add expense"].tap()
        app.buttons["tab-home"].tap()
        attachScreenshot(named: "home-before-activity-selection")
        let recent = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Groceries")).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 8), app.debugDescription)
        recent.tap()
        XCTAssertTrue(app.buttons["Edit expense"].waitForExistence(timeout: 5))
        attachScreenshot(named: "home-activity-expense-detail")

        app.buttons["tab-activity"].tap()
        let activity = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Groceries")).firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 8))
        activity.tap()
        XCTAssertTrue(app.buttons["Edit expense"].waitForExistence(timeout: 5))
        attachScreenshot(named: "activity-tab-expense-detail")
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testVNDGroupCurrencyPersistsAfterRelaunch() throws {
        let app = syntheticLocalApp()
        app.launchArguments = ["-resetDemoData", "-skipOnboarding", "-tab", "0"]
        app.launch()
        XCTAssertTrue(app.buttons["New group"].waitForExistence(timeout: 10))
        app.buttons["New group"].tap()
        let name = app.textFields["groupNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.tap(); name.typeText("Vietnam Currency QA\n")
        app.buttons["₫ VND"].tap()
        app.buttons["createGroupButton"].tap()
        XCTAssertTrue(app.staticTexts["Vietnam Currency QA"].firstMatch.waitForExistence(timeout: 8))
        app.terminate()
        app.launchArguments = ["-skipOnboarding", "-tab", "0"]
        app.launch()
        let group = app.staticTexts["Vietnam Currency QA"].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 10))
        group.tap()
        app.buttons["groupAddExpenseButton"].tap()
        XCTAssertTrue(app.staticTexts["expenseCurrencyLabel"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["expenseCurrencyLabel"].label.contains("VND"))
        attachScreenshot(named: "vnd-group-currency-after-relaunch")
    }
}


// Real localhost API + PostgreSQL proof. No financial response is mocked.
// Prepare .scratch/vietnam-trip/qa-session.json with vietnam-trip-qa.ts.
extension BillBanditUITests {
    @MainActor
    func testVietnamSharedExpenseOfflineRelaunchAndReconnect() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let configURL = root.appendingPathComponent(".scratch/vietnam-trip/qa-session.json")
        let data = try Data(contentsOf: configURL)
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let base = try XCTUnwrap(config["baseURL"] as? String)
        let token = try XCTUnwrap(config["aliceToken"] as? String)
        let runID = UUID().uuidString.lowercased()
        let name = "Vietnam Offline " + String(runID.prefix(8))
        let storeID = "vietnam-test-" + runID
        try await vietnamNetwork(base: base, offline: false)
        var createGroup = URLRequest(url: try XCTUnwrap(URL(string: base + "/api/mobile/groups")))
        createGroup.httpMethod = "POST"
        createGroup.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        createGroup.setValue("application/json", forHTTPHeaderField: "Content-Type")
        createGroup.setValue(runID, forHTTPHeaderField: "Idempotency-Key")
        createGroup.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name, "currency": "VND", "category": "TRIP",
            "memberAccountIds": [try XCTUnwrap(config["bobID"] as? String)]
        ])
        let (groupData, groupResponse) = try await URLSession.shared.data(for: createGroup)
        XCTAssertEqual((groupResponse as? HTTPURLResponse)?.statusCode, 201)
        let created = try XCTUnwrap(JSONSerialization.jsonObject(with: groupData) as? [String: Any])
        let createdGroup = try XCTUnwrap(created["group"] as? [String: Any])
        let groupID = try XCTUnwrap(createdGroup["id"] as? String)
        let app = XCUIApplication()
        app.launchArguments = ["-skipOnboarding", "-tab", "1"]
        app.launchEnvironment = ["BILLBANDIT_QA_STORE_ID": storeID,
                                 "BILLBANDIT_QA_BASE_URL": base,
                                 "BILLBANDIT_QA_TOKEN": token]
        try await vietnamNetwork(base: base, offline: false)
        app.launch()
        let groupTitle = app.staticTexts[name].firstMatch
        XCTAssertTrue(groupTitle.waitForExistence(timeout: 40))
        groupTitle.tap()
        XCTAssertTrue(app.buttons["groupAddExpenseButton"].waitForExistence(timeout: 30))
        // Cache the real group's ledger before losing the connection.
        XCTAssertTrue(app.staticTexts["ALL SQUARE"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["baseCurrencyEstimatedAmount"].firstMatch.waitForExistence(timeout: 40))
        try await vietnamNetwork(base: base, offline: true)
        app.buttons["groupAddExpenseButton"].tap()
        let amount = app.textFields["expenseAmountField"]
        XCTAssertTrue(amount.waitForExistence(timeout: 8))
        amount.tap(); amount.typeText("100001.5")
        let title = app.textFields["expenseTitleField"]
        title.tap(); title.typeText("Vietnam Offline Dinner\n")
        XCTAssertFalse(app.buttons["saveExpenseButton"].isEnabled, "Fractional VND must not enter the queue")
        amount.tap()
        amount.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12) + "100001")
        title.tap(); title.typeText("\n")
        app.buttons["saveExpenseButton"].tap()
        let pending = app.descendants(matching: .any)["groupPendingExpenseCount"]
        XCTAssertTrue(pending.waitForExistence(timeout: 20))
        let queuedRows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "groupPendingOperation-"))
        let originalOperation = try XCTUnwrap(queuedRows.firstMatch.exists ? queuedRows.firstMatch.identifier : nil)
        attachScreenshot(named: "vietnam-offline-queued")
        app.buttons["groupAddExpenseButton"].tap()
        XCTAssertTrue(amount.waitForExistence(timeout: 8))
        amount.tap(); amount.typeText("200001")
        title.tap(); title.typeText("Vietnam Offline Taxi\n")
        app.buttons["saveExpenseButton"].tap()
        XCTAssertTrue(pending.waitForExistence(timeout: 20))
        let twoPending = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "2"), object: pending)
        await fulfillment(of: [twoPending], timeout: 20)
        app.terminate()
        app.launchEnvironment["BILLBANDIT_QA_TOKEN"] = ""
        app.launch()
        XCTAssertTrue(groupTitle.waitForExistence(timeout: 20))
        groupTitle.tap()
        XCTAssertTrue(pending.waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)[originalOperation].exists)
        XCTAssertTrue(pending.label.contains("2"))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "saved rate")).firstMatch.exists)
        attachScreenshot(named: "vietnam-offline-relaunch-same-operation")
        try await vietnamNetwork(base: base, offline: false)
        app.terminate(); app.launch()
        XCTAssertTrue(groupTitle.waitForExistence(timeout: 40))
        groupTitle.tap()
        XCTAssertTrue(app.staticTexts["Vietnam Offline Dinner"].firstMatch.waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts["Vietnam Offline Taxi"].firstMatch.waitForExistence(timeout: 60))
        XCTAssertTrue(pending.waitForNonExistence(timeout: 30))
        attachScreenshot(named: "vietnam-reconnected-canonical-expense")
        let alice = try await vietnamLedger(base: base, token: token, groupID: groupID)
        let bobToken = try XCTUnwrap(config["bobToken"] as? String)
        let bob = try await vietnamLedger(base: base, token: bobToken, groupID: groupID)
        let aliceData = try XCTUnwrap(alice["data"] as? [String: Any])
        let bobData = try XCTUnwrap(bob["data"] as? [String: Any])
        let aliceGroup = try XCTUnwrap(aliceData["group"] as? [String: Any])
        let bobGroup = try XCTUnwrap(bobData["group"] as? [String: Any])
        let expenses = try XCTUnwrap(aliceGroup["expenses"] as? [[String: Any]])
        XCTAssertEqual(expenses.filter { $0["description"] as? String == "Vietnam Offline Dinner" }.count, 1)
        XCTAssertEqual(expenses.filter { $0["description"] as? String == "Vietnam Offline Taxi" }.count, 1)
        XCTAssertEqual((bobGroup["expenses"] as? [[String: Any]])?.count, expenses.count)
        XCTAssertEqual(alice["revision"] as? Int, bob["revision"] as? Int)
        let expense = try XCTUnwrap(expenses.first { $0["description"] as? String == "Vietnam Offline Dinner" })
        let money = try XCTUnwrap(expense["amount"] as? [String: Any])
        XCTAssertEqual(money["currencyCode"] as? String, "VND")
        XCTAssertEqual(money["currencyExponent"] as? Int, 0)
        XCTAssertEqual(money["minorUnits"] as? String, "100001")
        let splits = try XCTUnwrap(expense["splits"] as? [[String: Any]])
        let splitUnits = splits.compactMap { ($0["amount"] as? [String: Any])?["minorUnits"] as? String }
        XCTAssertEqual(Set(splitUnits), Set(["50001", "50000"]))

        // Exercise shared editing and unequal percentage splits in the real app.
        app.staticTexts["Vietnam Offline Dinner"].firstMatch.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        title.tap(); title.typeText(" Updated\n")
        let editedDescription = try XCTUnwrap(title.value as? String)
        app.buttons["%"].tap()
        let percentFields = app.textFields.matching(identifier: "%")
        XCTAssertEqual(percentFields.count, 2)
        for (index, value) in ["30", "70"].enumerated() {
            let field = percentFields.element(boundBy: index)
            field.tap()
            let oldValue = field.value as? String ?? ""
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldValue.count) + value)
        }
        title.tap(); title.typeText("\n")
        app.buttons["saveExpenseButton"].tap()
        let updatedTitle = app.staticTexts[editedDescription].firstMatch
        XCTAssertTrue(updatedTitle.waitForExistence(timeout: 30))
        app.terminate(); app.launch()
        XCTAssertTrue(groupTitle.waitForExistence(timeout: 40))
        groupTitle.tap()
        XCTAssertTrue(updatedTitle.waitForExistence(timeout: 30))
        attachScreenshot(named: "vietnam-shared-edited-unequal-split")

        // A partial payment must reduce the next suggestion; full payment clears it.
        app.buttons["groupSettleUpButton"].tap()
        let recordPayment = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "settleTransferButton-")).firstMatch
        XCTAssertTrue(recordPayment.waitForExistence(timeout: 30))
        recordPayment.tap()
        let paymentAmount = app.textFields["settlementAmountField"]
        XCTAssertTrue(paymentAmount.waitForExistence(timeout: 10))
        let fullAmount = try XCTUnwrap(Int(paymentAmount.value as? String ?? ""))
        XCTAssertGreaterThan(fullAmount, 10000)
        paymentAmount.tap()
        paymentAmount.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                                      count: String(fullAmount).count) + "10000")
        app.buttons["confirmSettlementButton"].tap()
        XCTAssertTrue(paymentAmount.waitForNonExistence(timeout: 30))
        XCTAssertTrue(recordPayment.waitForExistence(timeout: 30))
        recordPayment.tap()
        XCTAssertTrue(paymentAmount.waitForExistence(timeout: 10))
        XCTAssertEqual(paymentAmount.value as? String, String(fullAmount - 10000))
        attachScreenshot(named: "vietnam-partial-settlement-remainder")
        app.buttons["confirmSettlementButton"].tap()
        XCTAssertTrue(paymentAmount.waitForNonExistence(timeout: 30))
        XCTAssertTrue(recordPayment.waitForNonExistence(timeout: 30))
        attachScreenshot(named: "vietnam-full-settlement")
    }

    private func vietnamNetwork(base: String, offline: Bool) async throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: base + "/__qa/network")))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["offline": offline])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private func vietnamLedger(base: String, token: String, groupID: String) async throws -> [String: Any] {
        var request = URLRequest(url: try XCTUnwrap(URL(string: base + "/api/mobile/ledger/groups/" + groupID)))
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
