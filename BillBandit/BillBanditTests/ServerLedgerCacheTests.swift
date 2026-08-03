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

    func testCacheModelsAreNotInTheProductionSwiftDataSchemaYet() {
        let productionModelNames = Set(AppStore.schema.entities.map(\.name))
        XCTAssertFalse(productionModelNames.contains(String(describing: CachedLedgerSnapshot.self)))
        XCTAssertFalse(productionModelNames.contains(String(describing: PendingLedgerOperation.self)))
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
}
