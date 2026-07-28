import XCTest
import Testing
import SwiftData
import CloudKit
@testable import BillBandit

final class BalanceEngineTests: XCTestCase {
    func testUsernameHandlesNormalizeAndRejectInvalidValues() throws {
        XCTAssertEqual(try UsernameHandle("  @Bubby  ").value, "bubby")
        XCTAssertEqual(try UsernameHandle("bubby_2").value, "bubby_2")
        XCTAssertThrowsError(try UsernameHandle("ab"))
        XCTAssertThrowsError(try UsernameHandle("2bandit"))
        XCTAssertThrowsError(try UsernameHandle("bubby!"))
        XCTAssertThrowsError(try UsernameHandle("bubby_"))
        XCTAssertThrowsError(try UsernameHandle("support"))
    }

    @MainActor
    func testDemoSeedGroupIDsAreStableAcrossFreshInstalls() throws {
        func seededGroupIDs(storeName: String) throws -> [String: UUID] {
            let configuration = ModelConfiguration(
                storeName, schema: AppStore.schema, isStoredInMemoryOnly: true,
                groupContainer: .none, cloudKitDatabase: .none
            )
            let container = try ModelContainer(
                for: AppStore.schema, configurations: configuration
            )
            SeedData.seedIfEmpty(context: container.mainContext)
            return Dictionary(uniqueKeysWithValues: try container.mainContext
                .fetch(FetchDescriptor<Group>())
                .map { ($0.name, $0.id) })
        }

        XCTAssertEqual(
            try seededGroupIDs(storeName: "StableSeedIDs-A"),
            try seededGroupIDs(storeName: "StableSeedIDs-B")
        )
    }

    @MainActor
    func testCloudSyncMessageNeverExposesCloudKitImplementationDetails() {
        let internalError = NSError(
            domain: "CloudKitInternal",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Error <CKDPResponseOperationResult: 0x7fa104f80> { internal payload }",
            ]
        )

        let message = CloudCollaborationService.readable(internalError)

        XCTAssertEqual(
            message,
            "Cloud sync hit a temporary problem. It will retry automatically."
        )
        XCTAssertFalse(message.contains("CKDP"))
        XCTAssertFalse(message.contains("0x"))
    }

    func testStaleAutomaticInvitationDoesNotKeepLedgerSyncBannerVisible() {
        let missingShare = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.unknownItem.rawValue
        )
        let networkFailure = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.networkFailure.rawValue
        )

        XCTAssertTrue(AutomaticInvitationFailurePolicy.isTerminal(missingShare))
        XCTAssertFalse(AutomaticInvitationFailurePolicy.isTerminal(networkFailure))
        XCTAssertNil(CloudSyncIssuePolicy.visibleError(from: [
            CloudSyncIssue(source: .automaticInvitation, error: missingShare),
        ]))

        let visible = CloudSyncIssuePolicy.visibleError(from: [
            CloudSyncIssue(source: .privateLedger, error: networkFailure),
        ]) as NSError?
        XCTAssertEqual(visible?.domain, CKError.errorDomain)
        XCTAssertEqual(visible?.code, CKError.Code.networkFailure.rawValue)
    }

    @MainActor
    func testDemoRepairRemovesOnlyExactDuplicateLedgers() throws {
        let configuration = ModelConfiguration(
            "DemoRepair", schema: AppStore.schema, isStoredInMemoryOnly: true,
            groupContainer: .none, cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: AppStore.schema, configurations: configuration
        )
        let context = container.mainContext
        SeedData.seedIfEmpty(context: context)

        let seededPizza = try context.fetch(FetchDescriptor<Group>())
            .first { $0.id == DemoDataIntegrity.Kind.pizza.stableID }!
        let legacyDuplicate = Group(
            name: "Friday Pizza", icon: .pizza,
            createdAt: seededPizza.createdAt.addingTimeInterval(1),
            members: seededPizza.members
        )
        let duplicateExpense = Expense(
            title: "Pizza night", amount: 153, group: legacyDuplicate,
            paidBy: seededPizza.members.first
        )
        let duplicateActivity = ActivityItem(
            kind: .expenseAdded, summary: "Duplicate demo activity",
            groupID: legacyDuplicate.id, groupName: legacyDuplicate.name
        )
        let realGroup = Group(name: "Friday Pizza", icon: .pizza,
                              members: seededPizza.members)
        let realExpense = Expense(title: "Birthday pizza", amount: 89,
                                  group: realGroup,
                                  paidBy: seededPizza.members.first)
        for value in [legacyDuplicate, realGroup] { context.insert(value) }
        for value in [duplicateExpense, realExpense] { context.insert(value) }
        context.insert(duplicateActivity)
        try context.save()

        DemoDataIntegrity.repairDuplicateGroups(context: context)

        let remainingGroups = try context.fetch(FetchDescriptor<Group>())
        XCTAssertEqual(remainingGroups.filter {
            DemoDataIntegrity.kind(of: $0) == .pizza
        }.count, 1)
        XCTAssertTrue(remainingGroups.contains { $0.id == realGroup.id })
        XCTAssertFalse(try context.fetch(FetchDescriptor<ActivityItem>())
            .contains { $0.id == duplicateActivity.id })
    }

    func testAutomaticShareDefersUntilEveryMemberHasCloudIdentity() {
        let current = Person(name: "You", isCurrentUser: true)
        let friend = Person(name: "Friend")
        let group = Group(name: "Dinner", members: [current, friend])

        XCTAssertEqual(
            AutomaticShareDecision.forGroup(group),
            .deferUntilMembersLinked
        )

        friend.cloudUserRecordName = "cloud-user-friend"
        XCTAssertEqual(AutomaticShareDecision.forGroup(group), .ready)
    }

    func testStaleRemoteManifestCannotDeleteOrHideConcurrentExpenses() {
        let localExpenseID = UUID()
        let remoteExpenseID = UUID()
        let staleRemoteManifest = Set<UUID>()

        XCTAssertEqual(
            CloudRecordMergePolicy.localRecordIDsToDelete(
                local: [localExpenseID], remoteManifest: staleRemoteManifest
            ),
            []
        )
        XCTAssertTrue(
            CloudRecordMergePolicy.shouldApplyIncomingRecord(
                remoteExpenseID, remoteManifest: staleRemoteManifest
            )
        )
    }

    func testCollaborationRetryBackoffIsFastThenBounded() {
        XCTAssertEqual(CollaborationRetryPolicy.delay(after: 0), 0)
        XCTAssertEqual(CollaborationRetryPolicy.delay(after: 1), 1)
        XCTAssertEqual(CollaborationRetryPolicy.delay(after: 2), 2)
        XCTAssertEqual(CollaborationRetryPolicy.delay(after: 5), 16)
        XCTAssertEqual(CollaborationRetryPolicy.delay(after: 20), 30)
    }

    func testCloudSyncGivesReadyLocalUploadsPriorityOverPulling() {
        XCTAssertTrue(CloudSyncWorkPolicy.shouldYieldToPendingUpload(
            hasPendingUploadReady: true
        ))
        XCTAssertFalse(CloudSyncWorkPolicy.shouldYieldToPendingUpload(
            hasPendingUploadReady: false
        ))
    }

    func testRecordZoneSubscriptionsArePrivateDatabaseOnly() {
        XCTAssertTrue(CloudSubscriptionPolicy.shouldCreateRecordZoneSubscription(
            scope: .private
        ))
        XCTAssertFalse(CloudSubscriptionPolicy.shouldCreateRecordZoneSubscription(
            scope: .shared
        ))
    }

    func testPersonUploadsDoNotWriteUndeployedProfileTimestamp() {
        XCTAssertFalse(
            CloudPersonRecordPolicy.writesProfileUpdatedAt,
            "BBPerson.profileUpdatedAt is absent from the checked-in CloudKit schema"
        )
    }

    func testPersonUploadPolicyMatchesCheckedInCloudKitSchema() throws {
        let schemaURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CloudKit/CloudKitSchema.ckdb")
        let schema = try String(contentsOf: schemaURL, encoding: .utf8)
        let personStart = try XCTUnwrap(schema.range(of: "RECORD TYPE BBPerson ("))
        let following = schema[personStart.upperBound...]
        let personEnd = try XCTUnwrap(following.range(of: ");"))
        let personSchema = following[..<personEnd.lowerBound]

        XCTAssertEqual(
            personSchema.contains("profileUpdatedAt"),
            CloudPersonRecordPolicy.writesProfileUpdatedAt
        )
    }

    func testCloudUploadRetriesNetworkErrorsButStopsSchemaFailures() {
        let network = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.networkFailure.rawValue
        )
        let invalidSchema = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.invalidArguments.rawValue
        )

        XCTAssertEqual(CloudUploadFailurePolicy.disposition(for: network), .retry)
        XCTAssertEqual(
            CloudUploadFailurePolicy.disposition(for: invalidSchema),
            .needsAttention
        )
    }

    func testPartialCloudFailureStopsWhenAnyRecordHasASchemaFailure() {
        let recordID = CKRecord.ID(recordName: "person-test")
        let invalidRecord = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.invalidArguments.rawValue
        )
        let partialFailure = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.partialFailure.rawValue,
            userInfo: [CKPartialErrorsByItemIDKey: [recordID: invalidRecord]]
        )

        XCTAssertEqual(
            CloudUploadFailurePolicy.disposition(for: partialFailure),
            .needsAttention
        )
        XCTAssertEqual(
            CloudUploadFailurePolicy.cloudCode(for: partialFailure),
            .invalidArguments
        )
    }

    func testCloudUploadHonorsServerRetryAfter() {
        let busy = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.requestRateLimited.rawValue,
            userInfo: [CKErrorRetryAfterKey: NSNumber(value: 12)]
        )

        XCTAssertEqual(CollaborationRetryPolicy.delay(after: 2, error: busy), 12)
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
    func testFriendAccountRepairLeavesOneRowPerCloudAccountAndRetargetsLedger() throws {
        let configuration = ModelConfiguration(
            "FriendAccountIntegrity", schema: AppStore.schema,
            isStoredInMemoryOnly: true, groupContainer: .none,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: AppStore.schema,
                                           configurations: configuration)
        let context = container.mainContext
        let current = Person(name: "Esha", isCurrentUser: true)
        let oldConnected = Person(name: "Arjun Rao")
        oldConnected.cloudUserRecordName = "cloud-arjun"
        oldConnected.profileUpdatedAt = Date(timeIntervalSince1970: 100)
        let newestConnected = Person(name: "Arjun Rao")
        newestConnected.cloudUserRecordName = "cloud-arjun"
        newestConnected.profileUpdatedAt = Date(timeIntervalSince1970: 200)
        let group = Group(name: "Dinner", members: [current, oldConnected])
        let expense = Expense(title: "Charmoula", amount: 500, group: group,
                              paidBy: oldConnected)
        let split = Split(value: 250, computedAmount: 250, person: oldConnected,
                          expense: expense)
        let settlement = Settlement(amount: 50, from: current, to: oldConnected,
                                    group: group)
        let activity = ActivityItem(kind: .expenseAdded, summary: "Added Charmoula",
                                    actorID: oldConnected.id, groupID: group.id,
                                    groupName: group.name)
        [current, oldConnected, newestConnected].forEach(context.insert)
        context.insert(group)
        context.insert(expense)
        context.insert(split)
        context.insert(settlement)
        context.insert(activity)
        group.expenses.append(expense)
        group.settlements.append(settlement)
        expense.splits.append(split)
        try context.save()

        let affected = ConnectedFriendIdentity.repairDuplicateAccounts(context: context)
        try context.save()

        let people = try context.fetch(FetchDescriptor<Person>())
        let friends = people.filter { !$0.isCurrentUser }
        XCTAssertEqual(friends.map(\.id), [newestConnected.id])
        XCTAssertEqual(friends.first?.cloudUserRecordName, "cloud-arjun")
        XCTAssertEqual(affected.map(\.id), [group.id])
        let actualMemberIDs: [String] = group.members.map { $0.id.uuidString }.sorted()
        let expectedMemberIDs: [String] = [current.id, newestConnected.id]
            .map(\.uuidString).sorted()
        XCTAssertEqual(actualMemberIDs, expectedMemberIDs)
        XCTAssertEqual(expense.paidBy?.id, newestConnected.id)
        XCTAssertEqual(expense.splits.first?.person?.id, newestConnected.id)
        XCTAssertEqual(settlement.to?.id, newestConnected.id)
        XCTAssertEqual(activity.actorID, newestConnected.id)
        XCTAssertEqual(
            ConnectedFriendIdentity.canonicalPeople(from: people)
                .filter { !$0.isCurrentUser }.map(\.id),
            [newestConnected.id]
        )
    }

    @MainActor
    func testDemoPersonRepairRemovesOnlyKnownSeedDuplicatesAndRetargetsLedger() throws {
        let configuration = ModelConfiguration(
            "DemoPersonIntegrity", schema: AppStore.schema,
            isStoredInMemoryOnly: true, groupContainer: .none,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: AppStore.schema,
                                           configurations: configuration)
        let context = container.mainContext
        SeedData.seedIfEmpty(context: context)

        let canonical = try context.fetch(FetchDescriptor<Person>())
            .first { $0.id == DemoDataIntegrity.PersonKind.maya.stableID }!
        let duplicate = Person(name: "Maya Chen", avatar: .bows)
        let duplicateArjun = Person(name: "Arjun Rao", avatar: .bucketHat)
        let duplicateRiya = Person(name: "Riya Kapoor", avatar: .headphones)
        let duplicateSam = Person(name: "Sam Ortiz", avatar: .messyTie)
        let coincidentalRealPerson = Person(name: "Maya Chen", avatar: .headphones)
        let current = try context.fetch(FetchDescriptor<Person>())
            .first(where: \Person.isCurrentUser)!
        let group = Group(name: "Real dinner", members: [current, duplicate])
        let expense = Expense(title: "Dinner", amount: 500, group: group,
                              paidBy: duplicate)
        let split = Split(value: 250, computedAmount: 250, person: duplicate,
                          expense: expense)
        let settlement = Settlement(amount: 50, from: current, to: duplicate,
                                    group: group)
        let activity = ActivityItem(kind: .expenseAdded, summary: "Added dinner",
                                    actorID: duplicate.id, groupID: group.id,
                                    groupName: group.name)
        [duplicate, duplicateArjun, duplicateRiya, duplicateSam,
         coincidentalRealPerson].forEach(context.insert)
        context.insert(group)
        context.insert(expense)
        context.insert(split)
        context.insert(settlement)
        context.insert(activity)
        group.expenses.append(expense)
        group.settlements.append(settlement)
        expense.splits.append(split)
        try context.save()

        DemoDataIntegrity.repairDuplicatePeople(context: context)

        let people = try context.fetch(FetchDescriptor<Person>())
        XCTAssertFalse(people.contains { $0.id == duplicate.id })
        XCTAssertTrue(people.contains { $0.id == canonical.id })
        XCTAssertTrue(people.contains { $0.id == coincidentalRealPerson.id })
        XCTAssertEqual(group.members.filter { $0.name == "Maya Chen" }.map(\.id),
                       [canonical.id])
        XCTAssertEqual(expense.paidBy?.id, canonical.id)
        XCTAssertEqual(expense.splits.first?.person?.id, canonical.id)
        XCTAssertEqual(settlement.to?.id, canonical.id)
        XCTAssertEqual(activity.actorID, canonical.id)
    }

    @MainActor
    func testDemoPersonRepairDoesNotGuessFromOneMatchingContact() throws {
        let configuration = ModelConfiguration(
            "DemoPersonConservativeRepair", schema: AppStore.schema,
            isStoredInMemoryOnly: true, groupContainer: .none,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: AppStore.schema,
                                           configurations: configuration)
        let context = container.mainContext
        SeedData.seedIfEmpty(context: context)
        let sameNameAndAvatar = Person(name: "Maya Chen", avatar: .bows)
        context.insert(sameNameAndAvatar)
        try context.save()

        DemoDataIntegrity.repairDuplicatePeople(context: context)

        XCTAssertTrue(try context.fetch(FetchDescriptor<Person>())
            .contains { $0.id == sameNameAndAvatar.id })
    }

    @MainActor
    func testOrdinaryLaunchRetiresFixturesButPreservesRealConnectedData() throws {
        let configuration = ModelConfiguration(
            "DemoRetirement", schema: AppStore.schema, isStoredInMemoryOnly: true,
            groupContainer: .none, cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: AppStore.schema,
                                           configurations: configuration)
        let context = container.mainContext
        SeedData.seedIfEmpty(context: context)

        let people = try context.fetch(FetchDescriptor<Person>())
        let current = people.first(where: \.isCurrentUser)!
        let maya = people.first { $0.id == DemoDataIntegrity.PersonKind.maya.stableID }!
        let arjun = people.first { $0.id == DemoDataIntegrity.PersonKind.arjun.stableID }!
        maya.cloudUserRecordName = "cloud-maya"
        let realGroup = Group(name: "Real ledger", members: [current, arjun])
        let realExpense = Expense(title: "Dinner", amount: 120, group: realGroup,
                                  paidBy: current)
        let realSplit = Split(value: 60, computedAmount: 60, person: arjun,
                              expense: realExpense)
        context.insert(realGroup)
        context.insert(realExpense)
        context.insert(realSplit)
        realGroup.expenses.append(realExpense)
        realExpense.splits.append(realSplit)
        try context.save()

        DemoDataIntegrity.retireFixtures(context: context)

        let remainingGroups = try context.fetch(FetchDescriptor<Group>())
        let remainingPeople = try context.fetch(FetchDescriptor<Person>())
        XCTAssertEqual(remainingGroups.map(\.id), [realGroup.id])
        XCTAssertTrue(remainingPeople.contains { $0.id == maya.id })
        XCTAssertTrue(remainingPeople.contains { $0.id == arjun.id })
        XCTAssertEqual(
            ConnectedFriendIdentity.actualFriends(from: remainingPeople).map(\.id),
            [maya.id]
        )
        XCTAssertEqual(
            Set(ConnectedFriendIdentity.groupMemberOptions(from: remainingPeople).map(\.id)),
            Set([current.id, maya.id])
        )
    }

    @MainActor
    func testConnectedFriendSurvivesSaveAndFreshContext() throws {
        let configuration = ModelConfiguration(
            "ConnectedFriendPersistence", schema: AppStore.schema,
            isStoredInMemoryOnly: true, groupContainer: .none,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: AppStore.schema,
                                           configurations: configuration)
        let current = Person(name: "owner", isCurrentUser: true)
        current.appleUserIdentifier = "apple-owner"
        let friend = Person(name: "friend_handle")
        friend.cloudUserRecordName = "cloud-friend"
        container.mainContext.insert(current)
        container.mainContext.insert(friend)
        try container.mainContext.save()

        let freshContext = ModelContext(container)
        let reloaded = try freshContext.fetch(FetchDescriptor<Person>())
        XCTAssertEqual(
            ConnectedFriendIdentity.actualFriends(from: reloaded).map(\.id),
            [friend.id]
        )
    }

    @MainActor
    func testAppleAccountCanonicalizationLeavesOneProfileAndRetargetsLedger() throws {
        let configuration = ModelConfiguration(
            "AccountProfileIntegrity", schema: AppStore.schema,
            isStoredInMemoryOnly: true, groupContainer: .none,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: AppStore.schema,
                                           configurations: configuration)
        let context = container.mainContext
        let older = Person(name: "Old Name", isCurrentUser: true)
        older.appleUserIdentifier = "apple-account-1"
        older.cloudUserRecordName = "cloud-account-1"
        older.profileUpdatedAt = Date(timeIntervalSince1970: 100)
        let newer = Person(name: "Profile Name", isCurrentUser: true)
        newer.appleUserIdentifier = "apple-account-1"
        newer.cloudUserRecordName = "cloud-account-1"
        newer.profileUpdatedAt = Date(timeIntervalSince1970: 200)
        let friend = Person(name: "Friend")
        let group = Group(name: "Dinner", members: [older, newer, friend])
        let expense = Expense(title: "Charmoula", amount: 500, group: group,
                              paidBy: older)
        let split = Split(value: 250, computedAmount: 250, person: older,
                          expense: expense)
        let activity = ActivityItem(kind: .expenseAdded, summary: "Added Charmoula",
                                    actorID: older.id, groupID: group.id,
                                    groupName: group.name)
        [older, newer, friend].forEach(context.insert)
        context.insert(group)
        context.insert(expense)
        context.insert(split)
        context.insert(activity)
        group.expenses.append(expense)
        expense.splits.append(split)
        try context.save()

        let canonical = AccountProfileIntegrity.canonicalize(
            appleUserIdentifier: "apple-account-1",
            cloudUserRecordName: "cloud-account-1",
            context: context
        )

        let people = try context.fetch(FetchDescriptor<Person>())
        XCTAssertEqual(canonical.id, newer.id)
        XCTAssertEqual(canonical.name, "Profile Name")
        XCTAssertEqual(people.filter(\.isCurrentUser).map(\.id), [newer.id])
        XCTAssertEqual(people.filter {
            $0.appleUserIdentifier == "apple-account-1"
        }.map(\.id), [newer.id])
        XCTAssertEqual(group.members.filter(\.isCurrentUser).map(\.id), [newer.id])
        XCTAssertEqual(expense.paidBy?.id, newer.id)
        XCTAssertEqual(expense.splits.first?.person?.id, newer.id)
        XCTAssertEqual(activity.actorID, newer.id)
    }

    func testStaleRemoteProfileCannotOverwriteProfilePageUsername() {
        XCTAssertFalse(AccountProfileMergePolicy.shouldApplyRemoteProfile(
            remoteUpdatedAt: Date(timeIntervalSince1970: 100),
            localUpdatedAt: Date(timeIntervalSince1970: 200),
            isCurrentUser: true
        ))
        XCTAssertFalse(AccountProfileMergePolicy.shouldApplyRemoteProfile(
            remoteUpdatedAt: nil,
            localUpdatedAt: Date(timeIntervalSince1970: 200),
            isCurrentUser: true
        ))
        XCTAssertTrue(AccountProfileMergePolicy.shouldApplyRemoteProfile(
            remoteUpdatedAt: Date(timeIntervalSince1970: 300),
            localUpdatedAt: Date(timeIntervalSince1970: 200),
            isCurrentUser: true
        ))
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

    func testActivitySectioningKeepsFiveNewestDatesThenEarlierActivity() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let newestDay = Date(timeIntervalSince1970: 2_000_000_000)
        let items = (0..<7).map { offset in
            ActivityItem(
                kind: .expenseAdded,
                summary: "day-\(offset)",
                timestamp: calendar.date(byAdding: .day, value: -offset,
                                         to: newestDay)!
            )
        }

        let sections = ActivitySectioning.sections(
            from: items, maximumDatedSections: 5, calendar: calendar
        )

        XCTAssertEqual(sections.count, 6)
        XCTAssertEqual(sections.prefix(5).compactMap(\.date).count, 5)
        XCTAssertEqual(sections.last?.kind, .earlier)
        XCTAssertEqual(sections.last?.items.map(\.summary), ["day-5", "day-6"])
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

struct AppleCredentialGatePolicyTests {
    @Test("A canonical server handle verifies the local account")
    func serverHandleVerifiesLocalAccount() {
        #expect(
            UsernameAccountReconciliationPolicy.decision(remoteUsername: "Bubby") ==
                .verified("bubby")
        )
    }

    @Test("A missing server handle requires an atomic claim")
    func missingServerHandleRequiresClaim() {
        #expect(
            UsernameAccountReconciliationPolicy.decision(remoteUsername: nil) ==
                .requiresClaim
        )
        #expect(
            UsernameAccountReconciliationPolicy.decision(remoteUsername: "") ==
                .requiresClaim
        )
    }

    @Test("Apple identity alone cannot complete a new account")
    func appleIdentityAloneCannotCompleteOnboarding() {
        #expect(
            AccountOnboardingAccessPolicy.mayEnterApp(
                hasAppleIdentifier: true,
                accountOnboardingComplete: false
            ) == false
        )
    }

    @Test("Existing completed accounts retain app access")
    func completedAccountRetainsAccess() {
        #expect(
            AccountOnboardingAccessPolicy.mayEnterApp(
                hasAppleIdentifier: true,
                accountOnboardingComplete: true
            )
        )
    }

    @Test("Missing defaults restore one persisted active Apple session")
    func missingDefaultsRestorePersistedSession() {
        let decision = AppleAccountBootstrapPolicy.decision(
            storedIdentifier: nil,
            currentAccounts: [
                .init(identifier: "apple-account-1", sessionIsActive: true),
            ]
        )

        #expect(
            decision == .authenticate(
                identifier: "apple-account-1",
                recoveredFromProfile: true
            )
        )
    }

    @Test("Legacy persisted Apple session is recoverable after defaults loss")
    func legacySessionRestoresAfterDefaultsLoss() {
        let decision = AppleAccountBootstrapPolicy.decision(
            storedIdentifier: "  ",
            currentAccounts: [
                .init(identifier: "apple-account-1", sessionIsActive: nil),
            ]
        )

        #expect(
            decision == .authenticate(
                identifier: "apple-account-1",
                recoveredFromProfile: true
            )
        )
    }

    @Test("Explicit sign out is never reversed from the persisted profile")
    func explicitSignOutStaysSignedOut() {
        let decision = AppleAccountBootstrapPolicy.decision(
            storedIdentifier: nil,
            currentAccounts: [
                .init(identifier: "apple-account-1", sessionIsActive: false),
            ]
        )

        #expect(decision == .signedOut)
    }

    @Test("Conflicting persisted accounts are never guessed")
    func conflictingPersistedAccountsStaySignedOut() {
        let decision = AppleAccountBootstrapPolicy.decision(
            storedIdentifier: nil,
            currentAccounts: [
                .init(identifier: "apple-account-1", sessionIsActive: true),
                .init(identifier: "apple-account-2", sessionIsActive: true),
            ]
        )

        #expect(decision == .ambiguous)
    }

    @Test("Existing defaults remain the authoritative account")
    func existingDefaultsRemainAuthoritative() {
        let decision = AppleAccountBootstrapPolicy.decision(
            storedIdentifier: " apple-account-1 ",
            currentAccounts: [
                .init(identifier: "apple-account-1", sessionIsActive: true),
            ]
        )

        #expect(
            decision == .authenticate(
                identifier: "apple-account-1",
                recoveredFromProfile: false
            )
        )
    }

    @Test("Fresh authorization is not immediately revalidated")
    func freshAuthorizationSkipsCredentialStateCheck() {
        #expect(
            AppleCredentialGatePolicy.shouldRequestCredentialState(
                hasIdentifier: true,
                accountOnboardingComplete: true,
                deferNextCheck: true
            ) == false
        )
    }

    @Test("Simulator launch skips unreliable Apple credential-state queries")
    func simulatorLaunchSkipsCredentialStateCheck() {
        #expect(
            AppleCredentialGatePolicy.shouldRequestCredentialState(
                hasIdentifier: true,
                accountOnboardingComplete: true,
                deferNextCheck: false,
                credentialStateChecksAreReliable: false
            ) == false
        )
    }

    @Test("Credential-state errors preserve an authenticated session")
    func credentialStateErrorPreservesSession() {
        let simulatorAuthError = NSError(
            domain: "AKAuthenticationError",
            code: -7084
        )

        #expect(
            AppleCredentialGatePolicy.decision(
                for: .notFound,
                error: simulatorAuthError
            ) == .preserveSession
        )
    }

    @Test("Missing credential state does not erase a persisted session")
    func missingCredentialStatePreservesSession() {
        #expect(
            AppleCredentialGatePolicy.decision(for: .notFound, error: nil)
                == .preserveSession
        )
    }

    @Test("Confirmed revocation still signs the user out")
    func confirmedRevocationSignsOut() {
        #expect(
            AppleCredentialGatePolicy.decision(for: .revoked, error: nil)
                == .signOut
        )
    }
}
