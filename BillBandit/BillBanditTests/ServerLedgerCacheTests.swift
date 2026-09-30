import Foundation
import Security
import SwiftData
import XCTest
@testable import BillBandit

@MainActor
final class ServerLedgerCacheTests: XCTestCase {
    func testCanonicalRouteConflictShapeStopsStaleMutationRetry() throws {
        let client = URLSessionServerLedgerAPIClient(
            baseURL: URL(string: "https://example.test")!,
            tokenProvider: { "token" }
        )
        let data = try XCTUnwrap(
            """
            {
              "error": "REVISION_CONFLICT",
              "message": "The shared ledger changed.",
              "details": {
                "expectedRevision": 4,
                "currentRevision": 5,
                "retryable": true,
                "serverAuthoritative": true
              }
            }
            """.data(using: .utf8)
        )

        let error = try client.decodeHTTPErrorForTesting(
            status: 409,
            data: data,
            scope: ServerBackedLedgerScope(
                accountID: "account-a",
                groupID: "group-a"
            ),
            expectedRevision: 4
        )
        guard case let .revisionConflict(expected, current, snapshot) = error else {
            return XCTFail("Expected revisionConflict, got \(error)")
        }
        XCTAssertEqual(expected, 4)
        XCTAssertEqual(current, 5)
        XCTAssertNil(snapshot)
    }

    func testSequentialOfflineExpensesReserveRevisionsWithoutChangingRetryIdentity() throws {
        let store = try makeStore()
        let scope = ServerLedgerMutationScope.serverBacked(accountID: "offline-alice", groupID: "offline-group")
        let firstID = UUID()
        _ = try store.enqueue(ServerLedgerMutationRequest(operationID: firstID, scope: scope,
            expectedRevision: 7, requestPayload: Data("first".utf8)))
        let secondID = UUID()
        XCTAssertEqual(try store.nextQueuedExpenseRevision(scope: scope, canonicalRevision: 7, operationID: secondID), 8)
        _ = try store.enqueue(ServerLedgerMutationRequest(operationID: secondID, scope: scope,
            expectedRevision: 8, requestPayload: Data("second".utf8)))
        XCTAssertEqual(try store.nextQueuedExpenseRevision(scope: scope, canonicalRevision: 7, operationID: firstID), 7)
        XCTAssertEqual(try store.nextQueuedExpenseRevision(scope: scope, canonicalRevision: 7, operationID: UUID()), 9)
        let other = ServerLedgerMutationScope.serverBacked(accountID: "offline-alice", groupID: "other-group")
        XCTAssertEqual(try store.nextQueuedExpenseRevision(scope: other, canonicalRevision: 7, operationID: UUID()), 7)
    }

    func testCacheAndQueueAreAccountScoped() throws {
        let store = try makeStore()
        let accountA = ServerBackedLedgerScope(accountID: "account-a", groupID: "group-a")
        let accountB = ServerBackedLedgerScope(accountID: "account-b", groupID: "group-b")

        _ = try store.cache(
            snapshot: ServerLedgerSnapshot(scope: accountA, revision: 4, payload: Data("A".utf8))
        )
        _ = try store.cache(
            snapshot: ServerLedgerSnapshot(scope: accountB, revision: 9, payload: Data("B".utf8))
        )

        let operationA = ServerLedgerMutationRequest(
            scope: .serverBacked(accountID: accountA.accountID, groupID: accountA.groupID),
            expectedRevision: 4,
            requestPayload: Data("operation-a".utf8)
        )
        let operationB = ServerLedgerMutationRequest(
            scope: .serverBacked(accountID: accountB.accountID, groupID: accountB.groupID),
            expectedRevision: 9,
            requestPayload: Data("operation-b".utf8)
        )
        _ = try store.enqueue(operationA)
        _ = try store.enqueue(operationB)

        XCTAssertNil(
            try store.cachedSnapshot(
                for: ServerBackedLedgerScope(accountID: accountA.accountID, groupID: accountB.groupID)
            )
        )
        XCTAssertEqual(try store.cachedSnapshots(for: accountA.accountID).map(\.accountID), [accountA.accountID])

        let accountAOperations = try store.pendingOperations(for: accountA.accountID)
        XCTAssertEqual(accountAOperations.count, 1)
        XCTAssertEqual(accountAOperations.first?.accountID, accountA.accountID)
        XCTAssertTrue(
            try store.pendingOperations(
                for: .serverBacked(accountID: accountA.accountID, groupID: accountB.groupID)
            ).isEmpty
        )
    }

    func testRetryKeepsTheSameOperationIDAndRequestPayload() throws {
        let store = try makeStore()
        let scope = ServerLedgerMutationScope.serverBacked(
            accountID: "account-a",
            groupID: "group-a"
        )
        let operationID = UUID()
        let request = ServerLedgerMutationRequest(
            operationID: operationID,
            scope: scope,
            expectedRevision: 12,
            requestPayload: Data("stable-payload".utf8)
        )
        let operation = try store.enqueue(request)

        XCTAssertEqual(operation.retry(error: "offline"), operationID)
        try store.persist()

        let retried = try XCTUnwrap(store.pendingOperations(for: "account-a").first)
        XCTAssertEqual(retried.operationID, operationID)
        XCTAssertEqual(retried.retryState, .retrying)
        XCTAssertEqual(retried.retryCount, 1)
        XCTAssertEqual(try retried.makeRequest().operationID, operationID)
        XCTAssertEqual(try retried.makeRequest().requestPayload, request.requestPayload)
        XCTAssertEqual(try retried.makeRequest().expectedRevision, request.expectedRevision)
    }

    func testPendingOperationSurvivesReopenedStoreAndReconnectRetainsIdentity() async throws {
        let schema = Schema([CachedLedgerSnapshot.self, PendingLedgerOperation.self])
        let evidenceRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BILLBANDIT_QA_EVIDENCE_DIR"]
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent(".scratch/vietnam-trip/test-stores").path)
        try FileManager.default.createDirectory(at: evidenceRoot, withIntermediateDirectories: true)
        let storeURL = evidenceRoot.appendingPathComponent("BillBanditServerLedger-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + "-shm"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + "-wal"))
        }

        let configuration = ModelConfiguration(
            "ServerLedgerPersistentReconnectTests",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let scope = ServerLedgerMutationScope.serverBacked(
            accountID: "account-relaunch",
            groupID: "group-relaunch"
        )
        let operationID = UUID()
        let payload = Data("stable-relaunch-payload".utf8)
        let request = ServerLedgerMutationRequest(
            operationID: operationID,
            scope: scope,
            expectedRevision: 7,
            requestPayload: payload
        )
        do {
            let firstContainer = try ModelContainer(for: schema, configurations: configuration)
            let firstStore = ServerLedgerStore(context: ModelContext(firstContainer))
            _ = try firstStore.enqueue(request)
        }

        let reopenedContainer = try ModelContainer(for: schema, configurations: configuration)
        let reopenedStore = ServerLedgerStore(context: ModelContext(reopenedContainer))
        let persisted = try XCTUnwrap(
            reopenedStore.pendingOperations(for: "account-relaunch").first
        )
        XCTAssertEqual(persisted.operationID, operationID)
        XCTAssertEqual(try persisted.makeRequest().requestPayload, payload)

        let canonical = ServerLedgerSnapshot(
            scope: ServerBackedLedgerScope(accountID: "account-relaunch", groupID: "group-relaunch"),
            revision: 8,
            payload: Data("canonical-relaunch".utf8)
        )
        let api = RecordingServerLedgerAPIClient(
            fetchResult: .success(canonical),
            submitResult: .success(canonical)
        )
        let sync = ServerLedgerSync(store: reopenedStore, apiClient: api)
        try sync.activate(accountID: "account-relaunch")
        _ = try await sync.onReconnect(
            scope: ServerBackedLedgerScope(accountID: "account-relaunch", groupID: "group-relaunch")
        )

        let submittedRequests = await api.submittedRequests
        let submitted = try XCTUnwrap(submittedRequests.first)
        XCTAssertEqual(submitted.operationID, operationID)
        XCTAssertEqual(submitted.requestPayload, payload)
        XCTAssertEqual(
            try reopenedStore.pendingOperations(for: "account-relaunch", includingCompleted: true)
                .first?.retryState,
            .succeeded
        )
    }

    func testUnauthorizedDrainPreservesPendingOperationForReauthentication() async throws {
        let store = try makeStore()
        let scope = ServerLedgerMutationScope.serverBacked(
            accountID: "account-unauthorized",
            groupID: "group-unauthorized"
        )
        let operationID = UUID()
        let request = ServerLedgerMutationRequest(
            operationID: operationID,
            scope: scope,
            expectedRevision: 3,
            requestPayload: Data("preserve-after-401".utf8)
        )
        _ = try store.enqueue(request)

        let api = RecordingServerLedgerAPIClient(
            submitResult: .failure(ServerLedgerAPIClientError.unauthorized)
        )
        let sync = ServerLedgerSync(store: store, apiClient: api)
        try sync.activate(accountID: "account-unauthorized")

        do {
            _ = try await sync.drainPendingOperations(for: "account-unauthorized")
            XCTFail("A 401 must pause the queue")
        } catch let error as ServerLedgerSyncError {
            XCTAssertEqual(error, .unauthorized)
        }

        let pending = try XCTUnwrap(
            store.pendingOperations(for: "account-unauthorized", includingCompleted: true).first
        )
        XCTAssertEqual(pending.operationID, operationID)
        XCTAssertEqual(pending.retryState, .retrying)
        XCTAssertEqual(try pending.makeRequest().requestPayload, request.requestPayload)
        XCTAssertEqual(sync.state, .unauthorized)
    }

    #if DEBUG && targetEnvironment(simulator)
    func testLegacyIdentityNetworkRequirementBlocksOfflineEntry() async throws {
        guard let token = ProcessInfo.processInfo.environment["BILLBANDIT_QA_TEST_TOKEN"] else {
            throw XCTSkip("Requires the loopback QA session")
        }
        _ = try await UsernameIdentityService.installSimulatorQASession(token: token)
        CloudCollaborationService.shared.stopForegroundSync()
        CountingOfflineURLProtocol.requestCount = 0
        URLProtocol.registerClass(CountingOfflineURLProtocol.self)
        defer { URLProtocol.unregisterClass(CountingOfflineURLProtocol.self) }
        do {
            _ = try await UsernameIdentityService.currentUser()
            XCTFail("The old network-first identity call must fail offline before enqueue")
        } catch {
            XCTAssertGreaterThanOrEqual(CountingOfflineURLProtocol.requestCount, 1)
        }
    }

    func testBoundSessionRestoresOfflineWithoutAuthMeRequest() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BILLBANDIT_QA_STORE_ID"]?.hasPrefix("vietnam-test-") == true,
              let token = environment["BILLBANDIT_QA_TEST_TOKEN"], !token.isEmpty else {
            throw XCTSkip("Requires the real loopback simulator QA session")
        }

        let verified = try await UsernameIdentityService.installSimulatorQASession(token: token)
        CloudCollaborationService.shared.stopForegroundSync()
        CountingOfflineURLProtocol.requestCount = 0
        URLProtocol.registerClass(CountingOfflineURLProtocol.self)
        defer { URLProtocol.unregisterClass(CountingOfflineURLProtocol.self) }

        let restored = try await UsernameIdentityService.authenticatedUserForLedger()
        XCTAssertEqual(restored.id, verified.id)
        XCTAssertEqual(CountingOfflineURLProtocol.requestCount, 0)
    }

    func testMissingMismatchedAndExpiredBindingsRequireOnlineVerification() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BILLBANDIT_QA_STORE_ID"]?.hasPrefix("vietnam-test-") == true,
              let token = environment["BILLBANDIT_QA_TEST_TOKEN"], !token.isEmpty else {
            throw XCTSkip("Requires the real loopback simulator QA session")
        }

        _ = try await UsernameIdentityService.installSimulatorQASession(token: token)
        deleteQABinding()
        try await assertLedgerIdentityNeedsNetwork(token: token)

        _ = try await UsernameIdentityService.installSimulatorQASession(token: token)
        writeQAToken(token + ".switched")
        try await assertLedgerIdentityNeedsNetwork(token: token + ".switched")

        _ = try await UsernameIdentityService.installSimulatorQASession(token: token)
        expireQABinding()
        try await assertLedgerIdentityNeedsNetwork(token: token)

        _ = try await UsernameIdentityService.installSimulatorQASession(token: token)
    }

    private func assertLedgerIdentityNeedsNetwork(token: String) async throws {
        CloudCollaborationService.shared.stopForegroundSync()
        CountingOfflineURLProtocol.requestCount = 0
        URLProtocol.registerClass(CountingOfflineURLProtocol.self)
        defer { URLProtocol.unregisterClass(CountingOfflineURLProtocol.self) }

        let expectation = expectation(description: "offline identity failure")
        Task { @MainActor in
            do {
                _ = try await UsernameIdentityService.authenticatedUserForLedger()
                XCTFail("Binding (token.prefix(8)) should require online verification")
            } catch {
                expectation.fulfill()
            }
        }
        await fulfillment(of: [expectation], timeout: 5)
        XCTAssertGreaterThanOrEqual(CountingOfflineURLProtocol.requestCount, 1,
                                    "An invalid binding must require online verification")
    }

    private func deleteQABinding() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: SettlementTokenStore.keychainService,
            kSecAttrAccount: "authenticated-session-binding-v1",
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func writeQAToken(_ token: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: SettlementTokenStore.keychainService,
            kSecAttrAccount: "authenticated-session",
        ]
        SecItemDelete(query as CFDictionary)
        let attributes = query.merging([
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: Data(token.utf8),
        ]) { _, right in right }
        XCTAssertEqual(SecItemAdd(attributes as CFDictionary, nil), errSecSuccess)
    }

    private func expireQABinding() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: SettlementTokenStore.keychainService,
            kSecAttrAccount: "authenticated-session-binding-v1",
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(
            query.merging([kSecReturnData: true]) { _, right in right } as CFDictionary,
            &item
        ) == errSecSuccess,
              let data = item as? Data,
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            XCTFail("Expected a QA session binding")
            return
        }
        object["tokenExpiresAt"] = 0
        guard let expired = try? JSONSerialization.data(withJSONObject: object) else {
            XCTFail("Could not encode the expired QA binding")
            return
        }
        XCTAssertEqual(
            SecItemUpdate(
                query as CFDictionary,
                [kSecValueData: expired] as CFDictionary
            ),
            errSecSuccess
        )
    }
    #endif

    func testLocalOnlyScopeCannotCreateAQueuedServerMutation() throws {
        let store = try makeStore()
        let localScope = LedgerScope.localOnly(accountID: "account-a", localGroupID: UUID())
        let policy = LocalOnlyPolicy(scope: localScope)

        XCTAssertTrue(policy.isLocalOnly)
        XCTAssertFalse(policy.canProduceServerMutation)
        XCTAssertFalse(policy.canEnterSharedSettlement)
        XCTAssertNil(LocalOnlyPolicy.serverMutationScope(for: localScope))
        XCTAssertThrowsError(try policy.serverMutationScope()) { error in
            XCTAssertEqual(error as? LocalOnlyPolicyError, .serverMutationNotPermitted)
        }

        let coordinator = ServerLedgerMutationCoordinator(store: store)
        XCTAssertThrowsError(
            try coordinator.enqueue(
                scope: localScope,
                expectedRevision: 0,
                requestPayload: Data("local".utf8)
            )
        ) { error in
            XCTAssertEqual(error as? LocalOnlyPolicyError, .serverMutationNotPermitted)
        }
        XCTAssertTrue(try store.pendingOperations(for: "account-a").isEmpty)
    }

    func testCacheModelsAreInTheProductionSwiftDataSchema() {
        let productionModelNames = Set(AppStore.schema.entities.map(\.name))
        XCTAssertTrue(productionModelNames.contains(String(describing: CachedLedgerSnapshot.self)))
        XCTAssertTrue(productionModelNames.contains(String(describing: PendingLedgerOperation.self)))
        XCTAssertTrue(productionModelNames.contains(String(describing: CloudKitLedgerImportState.self)))
    }

    func testV2MoneyRequiresCanonicalStringMinorUnits() throws {
        let valid = try JSONDecoder.serverLedger.decode(
            ServerLedgerMoneyDTO.self,
            from: Data(#"{"minorUnits":"-42","currencyCode":"INR","currencyExponent":2}"#.utf8)
        )
        XCTAssertEqual(valid.minorUnits, "-42")

        for raw in [
            #"{"minorUnits":42,"currencyCode":"INR","currencyExponent":2}"#,
            #"{"minorUnits":"0042","currencyCode":"INR","currencyExponent":2}"#,
            #"{"minorUnits":"-0","currencyCode":"INR","currencyExponent":2}"#,
        ] {
            XCTAssertThrowsError(
                try JSONDecoder.serverLedger.decode(ServerLedgerMoneyDTO.self, from: Data(raw.utf8))
            )
        }
    }

    func testOptimisticSnapshotIsReplacedAndSuccessfulOperationIsNotReplayed() async throws {
        let store = try makeStore()
        let scope = ServerLedgerMutationScope.serverBacked(accountID: "account-a", groupID: "group-a")
        let operationID = UUID()
        let request = ServerLedgerMutationRequest(
            operationID: operationID,
            scope: scope,
            expectedRevision: 4,
            requestPayload: Data("payload".utf8)
        )
        let optimistic = ServerLedgerSnapshot(
            accountID: "account-a",
            groupID: "group-a",
            revision: 4,
            payload: Data("optimistic".utf8)
        )
        let canonical = ServerLedgerSnapshot(
            accountID: "account-a",
            groupID: "group-a",
            revision: 5,
            payload: Data("canonical".utf8)
        )
        let api = RecordingServerLedgerAPIClient(submitResult: .success(canonical))
        let coordinator = ServerLedgerMutationCoordinator(store: store)
        _ = try coordinator.enqueue(request, optimisticSnapshot: optimistic)

        XCTAssertEqual(try store.cachedSnapshot(for: scope.ledgerScope)?.payload, Data("optimistic".utf8))

        let sync = ServerLedgerSync(store: store, apiClient: api)
        try sync.activate(accountID: "account-a")
        _ = try await sync.drainPendingOperations(for: "account-a")
        _ = try await sync.drainPendingOperations(for: "account-a")

        let submitCount = await api.submitCount
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(try store.cachedSnapshot(for: scope.ledgerScope)?.payload, Data("canonical".utf8))
        let completed = try XCTUnwrap(store.pendingOperations(for: "account-a", includingCompleted: true).first)
        XCTAssertEqual(completed.retryState, .succeeded)
        XCTAssertEqual(completed.operationID, operationID)
    }

    func testRevisionConflictRefreshesAndRequiresExplicitReconfirmation() async throws {
        let store = try makeStore()
        let scope = ServerBackedLedgerScope(accountID: "account-a", groupID: "group-a")
        let request = ServerLedgerMutationRequest(
            scope: .serverBacked(accountID: scope.accountID, groupID: scope.groupID),
            expectedRevision: 4,
            requestPayload: Data("stale".utf8)
        )
        _ = try store.enqueue(request)
        let refreshed = ServerLedgerSnapshot(scope: scope, revision: 5, payload: Data("server".utf8))
        let api = RecordingServerLedgerAPIClient(
            fetchResult: .success(refreshed),
            submitResult: .failure(
                ServerLedgerAPIClientError.revisionConflict(
                    expectedRevision: 4,
                    currentRevision: 5,
                    snapshot: nil
                )
            )
        )
        let sync = ServerLedgerSync(store: store, apiClient: api)
        try sync.activate(accountID: "account-a")

        do {
            _ = try await sync.drainPendingOperations(for: "account-a")
            XCTFail("A stale mutation must require explicit reconfirmation")
        } catch let error as ServerLedgerSyncError {
            XCTAssertEqual(error, .conflictRequiresReconfirmation)
        }

        let submitCount = await api.submitCount
        let fetchCount = await api.fetchCount
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(fetchCount, 1)
        XCTAssertTrue(sync.requiresReconfirmation)
        XCTAssertEqual(try store.cachedSnapshot(for: scope)?.revision, 5)
        XCTAssertEqual(
            try store.pendingOperations(for: "account-a", includingCompleted: true).first?.retryState,
            .failed
        )

        _ = try await sync.drainPendingOperations(for: "account-a")
        let finalSubmitCount = await api.submitCount
        XCTAssertEqual(finalSubmitCount, 1)
    }

    func testSwitchingAccountsClearsOldCacheAndQueue() throws {
        let store = try makeStore()
        let scope = ServerBackedLedgerScope(accountID: "account-a", groupID: "group-a")
        _ = try store.cache(snapshot: ServerLedgerSnapshot(scope: scope, revision: 1))
        _ = try store.enqueue(
            ServerLedgerMutationRequest(
                scope: .serverBacked(accountID: scope.accountID, groupID: scope.groupID),
                expectedRevision: 1,
                requestPayload: Data("account-a".utf8)
            )
        )
        let sync = ServerLedgerSync(store: store, apiClient: RecordingServerLedgerAPIClient())
        try sync.activate(accountID: "account-a")
        try sync.activate(accountID: "account-b")

        XCTAssertNil(try store.cachedSnapshot(for: scope))
        XCTAssertTrue(try store.pendingOperations(for: "account-a").isEmpty)
        XCTAssertEqual(sync.activeAccountID, "account-b")
    }

    func testSurfaceProjectionCombinesBalancesAtHighestGroupRevision() throws {
        let owed = try XCTUnwrap(
            ServerLedgerSurfaceMoney(minorUnits: "900", currencyCode: "INR", currencyExponent: 2)
        )
        let owe = try XCTUnwrap(
            ServerLedgerSurfaceMoney(minorUnits: "-100", currencyCode: "INR", currencyExponent: 2)
        )
        let first = ServerLedgerSurfaceGroup(
            serverGroupID: "group-a",
            accountID: "account-a",
            name: "A",
            readRevision: 12,
            currentMemberID: "member-a",
            currentAccount: [owed]
        )
        let second = ServerLedgerSurfaceGroup(
            serverGroupID: "group-b",
            accountID: "account-a",
            name: "B",
            readRevision: 9,
            currentMemberID: "member-a",
            currentAccount: [owe]
        )

        guard case let .ready(snapshot) = ServerLedgerSurfaceProjection.project(
            accountID: "account-a",
            groups: [first, second]
        ) else {
            return XCTFail("Groups with independent revisions should project")
        }
        XCTAssertEqual(snapshot.readRevision, 12)
        XCTAssertEqual(snapshot.balanceByCurrency.first?.minorUnits, "800")
        XCTAssertEqual(
            ServerLedgerSurfaceStatus(phase: .ready, readRevision: 12).label,
            "Balances are current"
        )

        let summary = try XCTUnwrap(snapshot.accountBalanceSummaries.first)
        XCTAssertEqual(summary.net.minorUnits, "800")
        XCTAssertEqual(summary.owed.minorUnits, "900")
        XCTAssertEqual(summary.owe.minorUnits, "100")
        XCTAssertEqual(summary.headline, "you're owed overall")
        XCTAssertTrue(snapshot.coversExactly(serverGroupIDs: ["group-a", "group-b"]))
        XCTAssertFalse(snapshot.coversExactly(serverGroupIDs: ["group-a"]))
    }

    func testAccountBalanceSummaryDoesNotNetDifferentCurrencies() throws {
        let inrOwed = try XCTUnwrap(
            ServerLedgerSurfaceMoney(minorUnits: "50000", currencyCode: "INR", currencyExponent: 2)
        )
        let usdOwe = try XCTUnwrap(
            ServerLedgerSurfaceMoney(minorUnits: "-1200", currencyCode: "USD", currencyExponent: 2)
        )
        let group = ServerLedgerSurfaceGroup(
            serverGroupID: "group-a",
            accountID: "account-a",
            name: "A",
            readRevision: 1,
            currentMemberID: "member-a",
            currentAccount: [inrOwed, usdOwe]
        )

        guard case let .ready(snapshot) = ServerLedgerSurfaceProjection.project(
            accountID: "account-a",
            groups: [group]
        ) else {
            return XCTFail("The group should project")
        }

        XCTAssertEqual(snapshot.accountBalanceSummaries.map(\.net.currencyCode), ["INR", "USD"])
        XCTAssertEqual(snapshot.accountBalanceSummaries.map(\.headline), ["you're owed overall", "you owe overall"])
    }

    func testAccountBalanceSummaryExplainsOffsettingGroupBalances() throws {
        let owed = try XCTUnwrap(
            ServerLedgerSurfaceMoney(minorUnits: "900", currencyCode: "INR", currencyExponent: 2)
        )
        let owe = try XCTUnwrap(
            ServerLedgerSurfaceMoney(minorUnits: "-900", currencyCode: "INR", currencyExponent: 2)
        )
        let first = ServerLedgerSurfaceGroup(
            serverGroupID: "group-a",
            accountID: "account-a",
            name: "A",
            readRevision: 1,
            currentMemberID: "member-a",
            currentAccount: [owed]
        )
        let second = ServerLedgerSurfaceGroup(
            serverGroupID: "group-b",
            accountID: "account-a",
            name: "B",
            readRevision: 1,
            currentMemberID: "member-a",
            currentAccount: [owe]
        )

        guard case let .ready(snapshot) = ServerLedgerSurfaceProjection.project(
            accountID: "account-a",
            groups: [first, second]
        ) else {
            return XCTFail("The groups should project")
        }

        let summary = try XCTUnwrap(snapshot.accountBalanceSummaries.first)
        XCTAssertEqual(summary.net.minorUnits, "0")
        XCTAssertEqual(summary.owed.minorUnits, "900")
        XCTAssertEqual(summary.owe.minorUnits, "900")
        XCTAssertEqual(summary.headline, "you owe and are owed")
    }

    func testSurfaceProjectionAllowsIndependentChangesAndAggregatesFlags() throws {
        let firstBalance = try XCTUnwrap(
            ServerLedgerSurfaceMoney(minorUnits: "250", currencyCode: "INR", currencyExponent: 2)
        )
        let secondBalance = try XCTUnwrap(
            ServerLedgerSurfaceMoney(minorUnits: "700", currencyCode: "INR", currencyExponent: 2)
        )
        let first = ServerLedgerSurfaceGroup(
            serverGroupID: "group-a",
            accountID: "account-a",
            name: "A",
            readRevision: 4,
            currentMemberID: "member-a",
            currentAccount: [firstBalance],
            isStale: true
        )
        let second = ServerLedgerSurfaceGroup(
            serverGroupID: "group-b",
            accountID: "account-a",
            name: "B",
            readRevision: 17,
            currentMemberID: "member-a",
            currentAccount: [secondBalance],
            isReadOnly: true
        )

        guard case let .ready(snapshot) = ServerLedgerSurfaceProjection.project(
            accountID: "account-a",
            groups: [first, second]
        ) else {
            return XCTFail("Independent group changes should remain visible together")
        }

        XCTAssertEqual(snapshot.readRevision, 17)
        XCTAssertEqual(snapshot.groups.map(\.serverGroupID), ["group-a", "group-b"])
        XCTAssertEqual(snapshot.balanceByCurrency.first?.minorUnits, "950")
        XCTAssertTrue(snapshot.isStale)
        XCTAssertTrue(snapshot.isReadOnly)
    }

    func testSurfaceScopePolicySeparatesLocalOnlyAndSharedGroups() {
        XCTAssertEqual(ServerLedgerSurfaceScopePolicy.kind(serverGroupID: nil), .localOnly)
        XCTAssertEqual(ServerLedgerSurfaceScopePolicy.kind(serverGroupID: " server-group "), .shared)
        XCTAssertNil(ServerLedgerSurfaceScopePolicy.normalizedServerGroupID("  "))

        let localGroup = Group(name: "local")
        let sharedGroup = Group(name: "shared", serverGroupId: "server-group")
        XCTAssertNil(localGroup.serverLedgerGroupID)
        XCTAssertEqual(sharedGroup.serverLedgerGroupID, "server-group")
    }

    func testSurfaceSnapshotCannotCrossAccountOrGroupScopes() throws {
        let snapshot = ServerLedgerSnapshot(
            accountID: "account-a",
            groupID: "group-a",
            revision: 7,
            payload: Data("canonical-a".utf8)
        )

        XCTAssertTrue(
            ServerLedgerSurfaceScopePolicy.accepts(
                snapshot: snapshot,
                accountID: "account-a",
                groupID: "group-a"
            )
        )
        XCTAssertFalse(
            ServerLedgerSurfaceScopePolicy.accepts(
                snapshot: snapshot,
                accountID: "account-b",
                groupID: "group-a"
            )
        )
        XCTAssertFalse(
            ServerLedgerSurfaceScopePolicy.accepts(
                snapshot: snapshot,
                accountID: "account-a",
                groupID: "group-b"
            )
        )

        let groupForOtherAccount = ServerLedgerSurfaceGroup(
            serverGroupID: "group-b",
            accountID: "account-b",
            name: "B",
            readRevision: 7,
            currentMemberID: "member-b",
            currentAccount: []
        )
        XCTAssertEqual(
            ServerLedgerSurfaceProjection.project(
                accountID: "account-a",
                groups: [groupForOtherAccount]
            ),
            .invalidScope
        )
    }

    func testFriendBalanceUsesStableAccountIDWhenLocalIdentityIsMissing() throws {
        let amount = try XCTUnwrap(
            ServerLedgerSurfaceMoney(
                minorUnits: "27700",
                currencyCode: "INR",
                currencyExponent: 2
            )
        )
        let group = ServerLedgerSurfaceGroup(
            serverGroupID: "group-goa",
            accountID: "account-esha",
            name: "Goa",
            readRevision: 2,
            currentMemberID: "member-esha",
            currentAccount: [amount],
            members: [
                ServerLedgerSurfaceMember(
                    memberID: "member-esha",
                    accountID: "account-esha",
                    localIdentityID: nil,
                    displayName: "esha"
                ),
                ServerLedgerSurfaceMember(
                    memberID: "member-bubby",
                    accountID: "account-bubby",
                    localIdentityID: nil,
                    displayName: "bubby"
                ),
            ],
            transfers: [
                ServerLedgerSurfaceTransfer(
                    payerMemberID: "member-bubby",
                    recipientMemberID: "member-esha",
                    amount: amount
                ),
            ]
        )
        guard case let .ready(snapshot) = ServerLedgerSurfaceProjection.project(
            accountID: "account-esha",
            groups: [group]
        ) else {
            return XCTFail("The snapshot must project")
        }

        let localID = UUID()
        XCTAssertEqual(
            snapshot.friendBalance(
                forAccountID: "account-bubby",
                localPersonID: localID
            )?.first?.minorUnits,
            "27700"
        )
        XCTAssertTrue(
            snapshot.hasMembership(
                forAccountID: "account-bubby",
                localPersonID: localID
            )
        )
    }

    func testActivitySummaryUsesExpenseAndActorNames() throws {
        let amount = try XCTUnwrap(
            ServerLedgerSurfaceMoney(
                minorUnits: "50000",
                currencyCode: "INR",
                currencyExponent: 2
            )
        )
        let item = ServerLedgerSurfaceActivityItem(
            id: "expense-lunch",
            type: "expense",
            groupID: "group-goa",
            groupName: "Goa",
            description: "Lunch",
            actorName: "esha",
            amount: amount,
            at: .now
        )

        XCTAssertEqual(item.displaySummary, "Lunch added in Goa by esha")
    }

    func testActivitySummariesDescribeEditsDeletesAndMembership() throws {
        let amount = try XCTUnwrap(
            ServerLedgerSurfaceMoney(
                minorUnits: "50000",
                currencyCode: "INR",
                currencyExponent: 2
            )
        )
        let edited = ServerLedgerSurfaceActivityItem(
            id: "expense-edit",
            type: "expense",
            action: "updated",
            groupID: "group-goa",
            groupName: "Goa",
            description: "Lunch",
            actorName: "bubby",
            amount: amount,
            at: .now
        )
        let deleted = ServerLedgerSurfaceActivityItem(
            id: "expense-delete",
            type: "expense",
            action: "deleted",
            groupID: "group-goa",
            groupName: "Goa",
            description: "Taxi",
            actorName: "esha",
            amount: amount,
            at: .now
        )
        let joined = ServerLedgerSurfaceActivityItem(
            id: "member-add",
            type: "membership",
            action: "added",
            groupID: "group-goa",
            groupName: "Goa",
            actorName: "esha",
            targetName: "bubby",
            amount: amount,
            at: .now
        )

        XCTAssertEqual(edited.displaySummary, "bubby updated Lunch in Goa")
        XCTAssertEqual(deleted.displaySummary, "esha deleted Taxi in Goa")
        XCTAssertEqual(joined.displaySummary, "esha added bubby to Goa")
        XCTAssertFalse(joined.showsAmount)
    }

    private func makeStore() throws -> ServerLedgerStore {
        let schema = Schema([CachedLedgerSnapshot.self, PendingLedgerOperation.self])
        let configuration = ModelConfiguration(
            "ServerLedgerCacheTests",
            schema: schema,
            isStoredInMemoryOnly: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: configuration)
        return ServerLedgerStore(context: ModelContext(container))
    }

    func testUserFacingCopyMapsLedgerReadUnavailable() {
        XCTAssertEqual(
            ServerLedgerUserFacingCopy.message(forAPIErrorCode: "LEDGER_READ_UNAVAILABLE"),
            ServerLedgerUserFacingCopy.sharedBalancesRetryHint
        )
        XCTAssertEqual(
            ServerLedgerAPIClientError.server(status: 409, code: "LEDGER_READ_UNAVAILABLE").errorDescription,
            ServerLedgerUserFacingCopy.sharedBalancesRetryHint
        )
    }

    func testSurfaceStatusErrorLabelNeverShowsRawCode() {
        let status = ServerLedgerSurfaceStatus(
            phase: .error,
            message: "LEDGER_READ_UNAVAILABLE"
        )
        XCTAssertFalse(status.label.contains("LEDGER_READ_UNAVAILABLE"))
        XCTAssertTrue(status.label.localizedCaseInsensitiveContains("refresh"))
    }
}

#if DEBUG && targetEnvironment(simulator)
private final class CountingOfflineURLProtocol: URLProtocol {
    private static let lock = NSLock()
    static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/api/mobile/auth/me"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
#endif

private actor RecordingServerLedgerAPIClient: ServerLedgerAPIClient {
    private let fetchResult: Result<ServerLedgerSnapshot, Error>
    private let submitResult: Result<ServerLedgerSnapshot, Error>
    private(set) var fetchCount = 0
    private(set) var submitCount = 0
    private(set) var submittedRequests: [ServerLedgerMutationRequest] = []

    init(
        fetchResult: Result<ServerLedgerSnapshot, Error> = .failure(ServerLedgerAPIClientError.notImplemented),
        submitResult: Result<ServerLedgerSnapshot, Error> = .failure(ServerLedgerAPIClientError.notImplemented)
    ) {
        self.fetchResult = fetchResult
        self.submitResult = submitResult
    }

    func fetchSnapshot(for scope: ServerBackedLedgerScope) async throws -> ServerLedgerSnapshot {
        fetchCount += 1
        return try fetchResult.get()
    }

    func submit(_ request: ServerLedgerMutationRequest) async throws -> ServerLedgerSnapshot {
        submitCount += 1
        submittedRequests.append(request)
        return try submitResult.get()
    }
}
