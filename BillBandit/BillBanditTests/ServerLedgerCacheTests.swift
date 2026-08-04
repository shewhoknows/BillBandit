import Foundation
import SwiftData
import XCTest
@testable import BillBandit

@MainActor
final class ServerLedgerCacheTests: XCTestCase {
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

    func testSurfaceProjectionRequiresOneCanonicalReadRevision() throws {
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
            readRevision: 12,
            currentMemberID: "member-a",
            currentAccount: [owe]
        )

        guard case let .ready(snapshot) = ServerLedgerSurfaceProjection.project(
            accountID: "account-a",
            groups: [first, second]
        ) else {
            return XCTFail("Groups with one canonical revision should project")
        }
        XCTAssertEqual(snapshot.readRevision, 12)
        XCTAssertEqual(snapshot.balanceByCurrency.first?.minorUnits, "800")
        XCTAssertEqual(
            ServerLedgerSurfaceStatus(phase: .ready, readRevision: 12).label,
            "Shared balances are up to date"
        )

        let inconsistent = ServerLedgerSurfaceGroup(
            serverGroupID: "group-c",
            accountID: "account-a",
            name: "C",
            readRevision: 13,
            currentMemberID: "member-a",
            currentAccount: [owed]
        )
        guard case let .inconsistent(revisions) = ServerLedgerSurfaceProjection.project(
            accountID: "account-a",
            groups: [first, inconsistent]
        ) else {
            return XCTFail("Different read revisions must not be blended")
        }
        XCTAssertEqual(revisions, Set([12, 13]))
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

private actor RecordingServerLedgerAPIClient: ServerLedgerAPIClient {
    private let fetchResult: Result<ServerLedgerSnapshot, Error>
    private let submitResult: Result<ServerLedgerSnapshot, Error>
    private(set) var fetchCount = 0
    private(set) var submitCount = 0

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
        return try submitResult.get()
    }
}
