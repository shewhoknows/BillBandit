import XCTest
import SwiftData
@testable import BillBandit

final class BalanceEngineTests: XCTestCase {
    func testCollaborationRetryBackoffIsFastThenBounded() {
        XCTAssertEqual(CollaborationRetryPolicy.delay(after: 0), 0)
        XCTAssertEqual(CollaborationRetryPolicy.delay(after: 1), 1)
        XCTAssertEqual(CollaborationRetryPolicy.delay(after: 2), 2)
        XCTAssertEqual(CollaborationRetryPolicy.delay(after: 5), 16)
        XCTAssertEqual(CollaborationRetryPolicy.delay(after: 20), 30)
    }

    func testAutomaticGroupSharingRoutesBothFriendDirections() {
        let esha = "cloud-user-esha"
        let friend = "cloud-user-friend"

        XCTAssertEqual(
            AutomaticGroupShareRouting.recipients(
                from: [esha, friend], currentUser: esha
            ),
            [friend]
        )
        XCTAssertEqual(
            AutomaticGroupShareRouting.recipients(
                from: [esha, friend], currentUser: friend
            ),
            [esha]
        )
    }


    private let you = UUID(), maya = UUID(), arjun = UUID()

    func testConnectedFriendIdentityPrefersCloudLinkedLegacyDuplicate() {
        let legacy = Person(name: "Arjun Rao")
        let connected = Person(name: "árjun rao")
        connected.cloudUserRecordName = "cloud-arjun"

        XCTAssertEqual(
            ConnectedFriendIdentity.preferredPerson(for: legacy,
                                                     among: [legacy, connected]).id,
            connected.id
        )
        XCTAssertEqual(
            ConnectedFriendIdentity.canonicalPeople(from: [legacy, connected]).map(\.id),
            [connected.id]
        )
    }

    func testConnectedFriendIdentityDoesNotGuessBetweenSameNamedAccounts() {
        let legacy = Person(name: "Sam")
        let first = Person(name: "Sam")
        first.cloudUserRecordName = "cloud-sam-one"
        let second = Person(name: "Sam")
        second.cloudUserRecordName = "cloud-sam-two"

        XCTAssertEqual(
            ConnectedFriendIdentity.preferredPerson(for: legacy,
                                                     among: [legacy, first, second]).id,
            legacy.id
        )
    }

    @MainActor
    func testConnectedFriendMigrationRetargetsCompleteLedger() throws {
        let configuration = ModelConfiguration(
            "FriendIdentityTests", schema: AppStore.schema, isStoredInMemoryOnly: true,
            groupContainer: .none, cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: AppStore.schema,
                                           configurations: configuration)
        let context = container.mainContext
        let current = Person(name: "Esha", isCurrentUser: true)
        let legacy = Person(name: "Arjun")
        let connected = Person(name: "Arjun")
        connected.cloudUserRecordName = "cloud-arjun"
        let group = Group(name: "Parity Trip", members: [current, legacy])
        let expense = Expense(title: "Dinner", amount: 100, group: group,
                              paidBy: legacy)
        let split = Split(value: 50, computedAmount: 50, person: legacy,
                          expense: expense)
        let settlement = Settlement(amount: 25, from: current, to: legacy, group: group)
        let activity = ActivityItem(kind: .expenseAdded, summary: "Arjun added dinner",
                                    actorID: legacy.id, groupID: group.id,
                                    groupName: group.name)

        [current, legacy, connected].forEach(context.insert)
        context.insert(group)
        context.insert(expense)
        context.insert(split)
        context.insert(settlement)
        context.insert(activity)
        group.expenses.append(expense)
        group.settlements.append(settlement)
        expense.splits.append(split)
        try context.save()

        let affected = ConnectedFriendIdentity.mergeLegacyFriend(
            legacy, into: connected, context: context
        )
        try context.save()

        XCTAssertEqual(affected.map(\.id), [group.id])
        XCTAssertTrue(group.members.contains(where: { $0.id == connected.id }))
        XCTAssertFalse(group.members.contains(where: { $0.id == legacy.id }))
        XCTAssertEqual(expense.paidBy?.id, connected.id)
        XCTAssertEqual(expense.splits.first?.person?.id, connected.id)
        XCTAssertEqual(settlement.to?.id, connected.id)
        XCTAssertEqual(activity.actorID, connected.id)
        XCTAssertFalse(try context.fetch(FetchDescriptor<Person>())
            .contains(where: { $0.id == legacy.id }))
    }

    func testAutomaticGroupShareRecipientsAreConnectedUniqueAndNotTheOwner() {
        XCTAssertEqual(
            AutomaticGroupShareRouting.recipients(
                from: ["friend-b", nil, "owner", "friend-a", "friend-b", ""],
                currentUser: "owner"
            ),
            ["friend-a", "friend-b"]
        )
    }

    func testAutomaticGroupInvitationRecordNamesAreStableAndRecipientSpecific() {
        let groupID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let first = AutomaticGroupShareRouting.recordName(
            groupID: groupID, recipientCloudUser: "friend-a"
        )
        let repeated = AutomaticGroupShareRouting.recordName(
            groupID: groupID, recipientCloudUser: "friend-a"
        )
        let other = AutomaticGroupShareRouting.recordName(
            groupID: groupID, recipientCloudUser: "friend-b"
        )

        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first, other)
        XCTAssertTrue(first.hasPrefix(AutomaticGroupShareRouting.recordPrefix))
    }

    func testAutomaticInvitationSubscriptionsAreStablePerUser() {
        XCTAssertEqual(
            AutomaticGroupShareRouting.subscriptionID(for: "friend-a"),
            AutomaticGroupShareRouting.subscriptionID(for: "friend-a")
        )
        XCTAssertNotEqual(
            AutomaticGroupShareRouting.subscriptionID(for: "friend-a"),
            AutomaticGroupShareRouting.subscriptionID(for: "friend-b")
        )
    }

    func testSingleExpenseNets() {
        // You pay 90 split 3 ways → you're owed 60, the others owe 30 each.
        let nets = BalanceEngine.nets(expenses: [
            ExpenseSnapshot(paidBy: you, total: 90, shares: [you: 30, maya: 30, arjun: 30]),
        ], settlements: [])
        XCTAssertEqual(nets[you], 60)
        XCTAssertEqual(nets[maya], -30)
        XCTAssertEqual(nets[arjun], -30)
    }

    func testSettlementMovesNet() {
        // Expense: you +60, maya −30, arjun −30. Maya pays you 30:
        // maya → 0, you → 60 − 30 = 30, arjun untouched.
        let expenses = [ExpenseSnapshot(paidBy: you, total: 90, shares: [you: 30, maya: 30, arjun: 30])]
        let nets = BalanceEngine.nets(expenses: expenses, settlements: [
            SettlementSnapshot(from: maya, to: you, amount: 30),
        ])
        XCTAssertEqual(nets[you], 30)
        XCTAssertEqual(nets[maya], 0)
        XCTAssertEqual(nets[arjun], -30)
    }

    func testNetsSumToZero() {
        let nets = BalanceEngine.nets(expenses: [
            ExpenseSnapshot(paidBy: you, total: 100, shares: [you: 50, maya: 50]),
            ExpenseSnapshot(paidBy: maya, total: 40, shares: [you: 20, maya: 20]),
        ], settlements: [SettlementSnapshot(from: you, to: maya, amount: 10)])
        XCTAssertEqual(nets.values.reduce(0, +), 0)
    }

    func testSimplifyPairsExtremesFirst() {
        // you +80, maya −50, arjun −30 → maya→you 50, arjun→you 30
        let plan = BalanceEngine.simplify([you: 80, maya: -50, arjun: -30])
        XCTAssertEqual(plan.count, 2)
        XCTAssertTrue(plan.contains(DebtTransfer(from: maya, to: you, amount: 50)))
        XCTAssertTrue(plan.contains(DebtTransfer(from: arjun, to: you, amount: 30)))
    }

    func testSimplifyChainsThroughMiddle() {
        // a: +50, b: +10, c: −60 → c→a 50, c→b 10
        let a = UUID(), b = UUID(), c = UUID()
        let plan = BalanceEngine.simplify([a: 50, b: 10, c: -60])
        XCTAssertEqual(plan.count, 2)
        XCTAssertTrue(plan.contains(DebtTransfer(from: c, to: a, amount: 50)))
        XCTAssertTrue(plan.contains(DebtTransfer(from: c, to: b, amount: 10)))
    }

    func testSimplifyIgnoresDust() {
        let plan = BalanceEngine.simplify([you: Decimal(string: "0.004")!, maya: Decimal(string: "-0.004")!])
        XCTAssertEqual(plan.count, 0)
    }

    func testSuggestedPaymentMatchesSelectedDirection() {
        let plan = [
            DebtTransfer(from: you, to: maya, amount: 18),
            DebtTransfer(from: arjun, to: maya, amount: 8),
        ]

        XCTAssertEqual(BalanceEngine.suggestedPayment(from: you, to: maya, in: plan), 18)
        XCTAssertEqual(BalanceEngine.suggestedPayment(from: arjun, to: maya, in: plan), 8)
        XCTAssertNil(BalanceEngine.suggestedPayment(from: maya, to: you, in: plan))
        XCTAssertNil(BalanceEngine.suggestedPayment(from: you, to: arjun, in: plan))
    }

    func testOverpaymentDetection() {
        let expenses = [
            ExpenseSnapshot(paidBy: you, total: 100, shares: [you: 50, maya: 50]),
        ]
        XCTAssertFalse(BalanceEngine.hasOverpayment(
            expenses: expenses,
            settlements: [SettlementSnapshot(from: maya, to: you, amount: 40)]
        ))
        XCTAssertTrue(BalanceEngine.hasOverpayment(
            expenses: expenses,
            settlements: [SettlementSnapshot(from: maya, to: you, amount: 60)]
        ))
        XCTAssertTrue(BalanceEngine.hasOverpayment(
            expenses: [],
            settlements: [SettlementSnapshot(from: maya, to: you, amount: 10)]
        ))
    }

    func testMoneyRoundsHalfUp() {
        XCTAssertEqual(Money.cents(Decimal(string: "1.005")!), Decimal(string: "1.01")!)
        XCTAssertEqual(Money.cents(Decimal(string: "1.004")!), Decimal(string: "1.00")!)
        XCTAssertEqual(Money.whole(Decimal(string: "86.5")!), 87)
        XCTAssertEqual(Money.string(Decimal(string: "1234.5")!), "1,235")
    }

    func testRupeeIsDefaultCurrency() {
        XCTAssertEqual(Money.currency(Decimal(string: "142.5")!, currency: .inr), "₹143")
    }

    func testSelectableCurrencyFormattingAndParsing() {
        XCTAssertEqual(Money.currency(Decimal(string: "142.5")!, currency: .usd), "$143")
        XCTAssertEqual(Money.currency(Decimal(string: "142.5")!, currency: .aed), "د.إ 143")
        XCTAssertEqual(Money.parseInput("S$3,496"), 3496)
        XCTAssertEqual(Money.parseInput("AED 86,5"), Decimal(string: "86.5"))
    }

    func testMoneyInputDistinguishesGroupingAndDecimalCommas() {
        XCTAssertEqual(Money.parseInput("3,496"), 3496)
        XCTAssertEqual(Money.parseInput("₹1,00,000"), 100000)
        XCTAssertEqual(Money.parseInput("86,5"), Decimal(string: "86.5"))
        XCTAssertEqual(Money.parseInput("3,496.50"), Decimal(string: "3496.50"))
    }

    func testCapitalizesOnlyFirstLetter() {
        XCTAssertEqual("dinner at luigi's".capitalizingFirstLetter, "Dinner at luigi's")
        XCTAssertEqual("Maya Chen".capitalizingFirstLetter, "Maya Chen")
        XCTAssertEqual("".capitalizingFirstLetter, "")
    }

    func testFriendInviteCodesNormalizeAndValidate() {
        XCTAssertEqual(FriendInviteCode.normalize("b4ndt-cre-w2"), "B4NDTCREW2")
        XCTAssertEqual(FriendInviteCode.formatted("b4ndtcre-w2"), "B4NDT-CREW2")
        XCTAssertTrue(FriendInviteCode.isValid("B4NDT-CREW2"))
        XCTAssertFalse(FriendInviteCode.isValid("SHORT"))
    }

    func testGeneratedFriendInviteCodesAreStrongAndUnambiguous() {
        let codes = (0..<100).map { _ in FriendInviteCode.generate() }
        XCTAssertTrue(codes.allSatisfy(FriendInviteCode.isValid))
        XCTAssertTrue(codes.allSatisfy { !$0.contains("0") && !$0.contains("1") &&
            !$0.contains("I") && !$0.contains("O") })
        XCTAssertGreaterThan(Set(codes).count, 95)
    }

    @MainActor
    func testRewardEventAwardsExactlyOnce() throws {
        let container = try rewardContainer()
        let context = container.mainContext
        let personID = UUID()
        let eventID = UUID()

        let first = try RewardEngine.award(action: .expenseAdded, eventID: eventID,
                                           personID: personID, context: context)
        try context.save()
        let duplicate = try RewardEngine.award(action: .expenseAdded, eventID: eventID,
                                               personID: personID, context: context)

        XCTAssertEqual(first?.xpAwarded, 5)
        XCTAssertEqual(first?.totalXP, 5)
        XCTAssertEqual(first?.unlockedAchievements, [.initiativeTaker])
        XCTAssertNil(duplicate)
        XCTAssertEqual(try context.fetch(FetchDescriptor<UserProgress>()).first?.lifetimeXP, 5)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ProcessedRewardEvent>()).count, 1)
    }

    @MainActor
    func testRewardActionsUnlockOnlyTheirStarterPins() throws {
        let container = try rewardContainer()
        let context = container.mainContext
        let personID = UUID()

        _ = try RewardEngine.award(action: .expenseAdded, eventID: UUID(),
                                   personID: personID, context: context)
        _ = try RewardEngine.award(action: .groupCreated, eventID: UUID(),
                                   personID: personID, context: context)
        let payment = try RewardEngine.award(action: .settlementRecorded, eventID: UUID(),
                                             personID: personID, context: context)
        try context.save()

        XCTAssertEqual(payment?.totalXP, 23)
        let unlocks = try context.fetch(FetchDescriptor<AchievementUnlock>())
        XCTAssertEqual(Set(unlocks.map(\.achievementRaw)), Set([
            StarterAchievement.initiativeTaker.rawValue,
            StarterAchievement.crewFounder.rawValue,
            StarterAchievement.settlerScion.rawValue
        ]))
    }

    func testAchievementShelfContainsEightDistinctPins() {
        XCTAssertEqual(StarterAchievement.allCases.count, 8)
        XCTAssertEqual(Set(StarterAchievement.allCases.map(\.assetName)).count, 8)
    }

    @MainActor
    func testMilestoneAchievementUnlockIsIdempotent() throws {
        let container = try rewardContainer()
        let context = container.mainContext
        let personID = UUID()

        XCTAssertTrue(try AchievementEngine.unlock(.highOnDetails,
                                                    personID: personID, context: context))
        XCTAssertFalse(try AchievementEngine.unlock(.highOnDetails,
                                                     personID: personID, context: context))
        try context.save()

        let unlocks = try context.fetch(FetchDescriptor<AchievementUnlock>())
        XCTAssertEqual(unlocks.count, 1)
        XCTAssertEqual(unlocks.first?.achievement, .highOnDetails)
    }

    @MainActor
    func testDisabledProgressProcessesWithoutAwarding() throws {
        let container = try rewardContainer()
        let context = container.mainContext
        let personID = UUID()
        let eventID = UUID()
        context.insert(UserProgress(personID: personID, isEnabled: false))

        let disabledResult = try RewardEngine.award(action: .groupCreated, eventID: eventID,
                                                    personID: personID, context: context)
        try context.save()
        let progress = try XCTUnwrap(context.fetch(FetchDescriptor<UserProgress>()).first)
        progress.isEnabled = true
        let replay = try RewardEngine.award(action: .groupCreated, eventID: eventID,
                                            personID: personID, context: context)

        XCTAssertNil(disabledResult)
        XCTAssertNil(replay)
        XCTAssertEqual(progress.lifetimeXP, 0)
        XCTAssertTrue(try context.fetch(FetchDescriptor<AchievementUnlock>()).isEmpty)
    }

    func testEarlyProgressLevelBoundaries() {
        XCTAssertEqual(ProgressLevel.level(for: 0), .lookout)
        XCTAssertEqual(ProgressLevel.level(for: 49), .lookout)
        XCTAssertEqual(ProgressLevel.level(for: 50), .crewScout)
        XCTAssertEqual(ProgressLevel.level(for: 149), .crewScout)
        XCTAssertEqual(ProgressLevel.level(for: 150), .ledgerKeeper)
    }

    func testActivitySummaryIncludesItsGroup() {
        let item = ActivityItem(kind: .expenseAdded,
                                summary: "Esha added “Groceries Zepto”",
                                groupName: "NYC Date")
        XCTAssertEqual(item.displaySummary,
                       "Esha added “Groceries Zepto” in NYC Date")

        let groupItem = ActivityItem(kind: .groupCreated,
                                     summary: "Esha created “NYC Date”",
                                     groupName: "NYC Date")
        XCTAssertEqual(groupItem.displaySummary, "Esha created “NYC Date”")
    }

    func testUnreadActivityCountsOnlyNewActionsFromOtherPeople() {
        let currentUserID = UUID()
        let friendID = UUID()
        let lastRead = Date(timeIntervalSince1970: 1_000)
        let items = [
            ActivityItem(kind: .expenseAdded, summary: "Mine",
                         timestamp: Date(timeIntervalSince1970: 1_100), actorID: currentUserID),
            ActivityItem(kind: .expenseAdded, summary: "Old",
                         timestamp: Date(timeIntervalSince1970: 900), actorID: friendID),
            ActivityItem(kind: .expenseAdded, summary: "Remote",
                         timestamp: Date(timeIntervalSince1970: 1_200), actorID: friendID),
            ActivityItem(kind: .expenseAdded, summary: "Legacy",
                         timestamp: Date(timeIntervalSince1970: 1_300)),
        ]

        XCTAssertEqual(ActivityData.unreadCount(in: items, currentUserID: currentUserID,
                                                lastRead: lastRead), 1)
    }

    func testLegacyReminderCleanupRemovesRetiredPreferences() {
        let defaults = UserDefaults.standard
        let keys = ["reminder.pay", "reminder.settle", "reminder.dues"]
        keys.forEach { defaults.set(true, forKey: $0) }

        LegacyReminderCleanup.retire()

        keys.forEach { XCTAssertNil(defaults.object(forKey: $0)) }
    }

    @MainActor
    func testEmptyGroupSettlementCleanupRestoresAllSquare() throws {
        let configuration = ModelConfiguration(
            "LedgerIntegrityTests", schema: AppStore.schema, isStoredInMemoryOnly: true,
            groupContainer: .none, cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: AppStore.schema, configurations: configuration)
        let context = container.mainContext
        let currentUser = Person(name: "You", isCurrentUser: true)
        let maya = Person(name: "Maya")
        let group = Group(name: "Empty", members: [currentUser, maya])
        let settlement = Settlement(amount: 1_500, from: currentUser, to: maya, group: group)
        context.insert(currentUser)
        context.insert(maya)
        context.insert(group)
        context.insert(settlement)
        group.settlements.append(settlement)
        context.insert(ActivityItem(kind: .settlementRecorded, summary: "Invalid payment",
                                    refID: settlement.id, groupID: group.id,
                                    groupName: group.name))
        try context.save()

        LedgerIntegrity.repairEmptyGroups(context: context)

        XCTAssertTrue(group.settlements.isEmpty)
        XCTAssertEqual(BalanceMath.nets(in: group)[currentUser.id] ?? 0, 0)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Settlement>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ActivityItem>()).isEmpty)
    }

    @MainActor
    private func rewardContainer() throws -> ModelContainer {
        let schema = Schema([
            UserProgress.self, ProcessedRewardEvent.self, AchievementUnlock.self,
        ])
        let configuration = ModelConfiguration(
            "RewardTests", schema: schema, isStoredInMemoryOnly: true,
            groupContainer: .none, cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }
}
