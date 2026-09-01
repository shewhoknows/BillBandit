import Foundation
import SwiftData
import XCTest
@testable import BillBandit

@MainActor
final class SettlementStoreTests: XCTestCase {
    func testCanonicalDisplayUsesLedgerSnapshotAndReadRevision() throws {
        let cache = try makeCacheStore()
        let api = RecordingCanonicalLedgerAPI()
        let store = SettlementStore(
            realtimeClient: SettlementPollingRealtimeClient(),
            serverLedgerStore: cache,
            serverLedgerAPIClient: api
        )
        store.configure(
            accountID: "account-a",
            groupID: "group-a",
            currentUserLabel: "You"
        )
        let snapshot = canonicalSnapshot(revision: 4, readRevision: 4)
        _ = try cache.cache(snapshot: snapshot)
        try store.applyCanonicalForTesting(snapshot)

        XCTAssertEqual(store.readRevision, 4)
        XCTAssertEqual(store.snapshot?.version, 4)
        XCTAssertEqual(store.snapshot?.plan.first?.minorUnits, "6173")
        XCTAssertEqual(store.canonicalExpenses.first?.amount.minorUnits, "12345")
        XCTAssertEqual(store.canonicalTotalMoney?.minorUnits, "12345")
        XCTAssertEqual(store.canonicalMyPaidMoney?.minorUnits, "12345")
        XCTAssertEqual(store.canonicalMyShareMoney?.minorUnits, "6173")
        XCTAssertEqual(store.canonicalBalanceMoney?.minorUnits, "-6173")
        XCTAssertEqual(
            SettlementMoneyFormatting.add("999999999999999999", "2"),
            "1000000000000000001"
        )
    }

    func testStaleMutationRefreshesCanonicalStateAndRequiresReconfirmation() async throws {
        let cache = try makeCacheStore()
        let initial = canonicalSnapshot(revision: 4, readRevision: 4)
        let authoritative = canonicalSnapshot(revision: 5, readRevision: 5)
        _ = try cache.cache(snapshot: initial)
        let api = RecordingCanonicalLedgerAPI(
            fetchResult: .snapshot(authoritative),
            submitResults: [.conflict(authoritative)]
        )
        let store = SettlementStore(
            realtimeClient: SettlementPollingRealtimeClient(),
            serverLedgerStore: cache,
            serverLedgerAPIClient: api
        )
        store.configure(accountID: "account-a", groupID: "group-a", currentUserLabel: "You")
        try store.applyCanonicalForTesting(initial)
        let transfer = try XCTUnwrap(store.snapshot?.plan.first)

        do {
            try await store.settle(transfer: transfer, note: nil, expectedVersion: 4)
            XCTFail("A stale mutation must require explicit reconfirmation")
        } catch let error as SettlementClientError {
            XCTAssertEqual(error, .requiresReconfirmation)
        }

        let firstSubmitCount = await api.submitCount
        XCTAssertEqual(firstSubmitCount, 1)
        XCTAssertTrue(store.requiresReconfirmation)
        XCTAssertEqual(store.snapshot?.version, 5)
        XCTAssertEqual(store.readRevision, 5)

        await store.refresh(forceWritesDisabled: true)
        let finalSubmitCount = await api.submitCount
        XCTAssertEqual(finalSubmitCount, 1)
    }

    func testSuccessfulMutationIsExactlyOnceAndNeverReplaysTheOperation() async throws {
        let cache = try makeCacheStore()
        let initial = canonicalSnapshot(revision: 4, readRevision: 4)
        let canonical = canonicalSnapshot(revision: 5, readRevision: 5)
        _ = try cache.cache(snapshot: initial)
        let api = RecordingCanonicalLedgerAPI(
            fetchResult: .snapshot(canonical),
            submitResults: [.snapshot(canonical)]
        )
        let store = SettlementStore(
            realtimeClient: SettlementPollingRealtimeClient(),
            serverLedgerStore: cache,
            serverLedgerAPIClient: api
        )
        store.configure(accountID: "account-a", groupID: "group-a", currentUserLabel: "You")
        try store.applyCanonicalForTesting(initial)
        let transfer = try XCTUnwrap(store.snapshot?.plan.first)

        try await store.settle(transfer: transfer, note: "paid", expectedVersion: 4)
        let firstSubmitCount = await api.submitCount
        XCTAssertEqual(firstSubmitCount, 1)
        XCTAssertEqual(store.snapshot?.version, 5)

        do {
            try await store.settle(transfer: transfer, note: "paid", expectedVersion: 4)
            XCTFail("The old revision must not silently replay")
        } catch let error as SettlementClientError {
            XCTAssertEqual(error, .requiresReconfirmation)
        }
        let finalSubmitCount = await api.submitCount
        XCTAssertEqual(finalSubmitCount, 1)
        XCTAssertTrue(try cache.pendingOperations(for: "account-a", includingCompleted: true)
            .contains { $0.retryState == .succeeded })
    }

    func testOfflineRefreshUsesCachedCanonicalStateAndSurfacesError() async throws {
        let cache = try makeCacheStore()
        let cached = canonicalSnapshot(revision: 4, readRevision: 4)
        _ = try cache.cache(snapshot: cached)
        let api = RecordingCanonicalLedgerAPI(fetchResult: .offline)
        let store = SettlementStore(
            realtimeClient: SettlementPollingRealtimeClient(),
            serverLedgerStore: cache,
            serverLedgerAPIClient: api
        )
        store.configure(accountID: "account-a", groupID: "group-a", currentUserLabel: "You")

        await store.refresh(forceWritesDisabled: true)

        XCTAssertTrue(store.isOffline)
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(store.snapshot?.version, 4)
        XCTAssertTrue(store.hasCanonicalReadModel)
        XCTAssertFalse(store.writesEnabled)
        XCTAssertTrue(store.canQueueSettlement)
        XCTAssertTrue(try cache.pendingOperations(for: "account-a").isEmpty)
    }

    func testCanonicalSettlementDoesNotInsertLegacyLocalSettlement() async throws {
        let cache = try makeCacheStore()
        let localContainer = try makeLocalAppContainer()
        let localContext = localContainer.mainContext
        let me = Person(name: "You", isCurrentUser: true)
        let friend = Person(name: "Friend")
        let localGroup = Group(
            name: "Server-backed copy",
            members: [me, friend],
            serverGroupId: "group-a"
        )
        localContext.insert(me)
        localContext.insert(friend)
        localContext.insert(localGroup)
        try localContext.save()

        let initial = canonicalSnapshot(revision: 4, readRevision: 4)
        let canonical = canonicalSnapshot(revision: 5, readRevision: 5)
        _ = try cache.cache(snapshot: initial)
        let api = RecordingCanonicalLedgerAPI(
            fetchResult: .snapshot(canonical),
            submitResults: [.snapshot(canonical)]
        )
        let store = SettlementStore(
            realtimeClient: SettlementPollingRealtimeClient(),
            serverLedgerStore: cache,
            serverLedgerAPIClient: api
        )
        store.configure(accountID: "account-a", groupID: "group-a", currentUserLabel: "You")
        try store.applyCanonicalForTesting(initial)
        let transfer = try XCTUnwrap(store.snapshot?.plan.first)

        try await store.settle(transfer: transfer, note: nil, expectedVersion: 4)

        XCTAssertEqual(try localContext.fetch(FetchDescriptor<Settlement>()).count, 0)
        XCTAssertTrue(localGroup.settlements.isEmpty)
    }

    private func makeCacheStore() throws -> ServerLedgerStore {
        let schema = Schema([CachedLedgerSnapshot.self, PendingLedgerOperation.self])
        let configuration = ModelConfiguration(
            "SettlementStoreTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: configuration)
        return ServerLedgerStore(context: ModelContext(container))
    }

    private func makeLocalAppContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "SettlementStoreLocalTests-\(UUID().uuidString)",
            schema: AppStore.schema,
            isStoredInMemoryOnly: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: AppStore.schema, configurations: configuration)
    }

    private func canonicalSnapshot(revision: Int64, readRevision: Int64) -> ServerLedgerSnapshot {
        let payload = """
        {
          "contractVersion": 2,
          "kind": "read",
          "scope": {
            "kind": "shared",
            "accountId": "account-a",
            "groupId": "group-a",
            "localOnly": false
          },
          "revision": \(revision),
          "readRevision": \(readRevision),
          "pendingOperationIds": [],
          "migration": {
            "status": "complete",
            "source": "server",
            "migrationId": null,
            "importedAt": null,
            "dualWriteEnabled": false,
            "recoveryReadOnly": false
          },
          "stale": {
            "isStale": false,
            "reason": "",
            "observedAt": "2026-08-04T00:00:00.000Z",
            "readRevision": \(readRevision),
            "serverRevision": \(revision)
          },
          "authority": {
            "serverAuthoritative": true,
            "source": "server",
            "readModel": "server",
            "ledger": "server",
            "balances": "server",
            "settlementPlan": "server",
            "settlementHistory": "server",
            "identity": "server",
            "cacheRole": "read_only"
          },
          "data": {
            "group": {
              "groupId": "group-a",
              "accountId": "account-a",
              "name": "Dinner",
              "baseCurrency": { "currencyCode": "INR", "currencyExponent": 2 },
              "scope": "shared",
              "localOnly": false,
              "revision": \(revision),
              "readRevision": \(readRevision),
              "members": [
                {
                  "memberId": "member-a",
                  "accountId": "account-a",
                  "localIdentityId": null,
                  "displayName": "You",
                  "email": null,
                  "role": "owner",
                  "status": "active"
                },
                {
                  "memberId": "member-b",
                  "accountId": "account-b",
                  "localIdentityId": null,
                  "displayName": "Friend",
                  "email": null,
                  "role": "member",
                  "status": "active"
                }
              ],
              "expenses": [
                {
                  "expenseId": "expense-a",
                  "description": "Dinner",
                  "paidByMemberId": "member-a",
                  "amount": { "minorUnits": "12345", "currencyCode": "INR", "currencyExponent": 2 },
                  "splitMethod": "EQUAL",
                  "splits": [
                    {
                      "splitId": "split-a",
                      "memberId": "member-a",
                      "amount": { "minorUnits": "6173", "currencyCode": "INR", "currencyExponent": 2 },
                      "percentage": null,
                      "shares": null
                    },
                    {
                      "splitId": "split-b",
                      "memberId": "member-b",
                      "amount": { "minorUnits": "6172", "currencyCode": "INR", "currencyExponent": 2 },
                      "percentage": null,
                      "shares": null
                    }
                  ],
                  "status": "active",
                  "createdAt": "2026-08-04T00:00:00.000Z",
                  "updatedAt": "2026-08-04T00:00:00.000Z"
                }
              ],
              "balances": {
                "byMember": [
                  {
                    "memberId": "member-a",
                    "byCurrency": [
                      { "minorUnits": "-6173", "currencyCode": "INR", "currencyExponent": 2 }
                    ]
                  },
                  {
                    "memberId": "member-b",
                    "byCurrency": [
                      { "minorUnits": "6173", "currencyCode": "INR", "currencyExponent": 2 }
                    ]
                  }
                ],
                "byCurrency": [
                  {
                    "currency": { "currencyCode": "INR", "currencyExponent": 2 },
                    "totalPositive": { "minorUnits": "6173", "currencyCode": "INR", "currencyExponent": 2 },
                    "totalNegative": { "minorUnits": "-6173", "currencyCode": "INR", "currencyExponent": 2 },
                    "net": { "minorUnits": "0", "currencyCode": "INR", "currencyExponent": 2 }
                  }
                ],
                "currentAccount": {
                  "accountId": "account-a",
                  "memberId": "member-a",
                  "byCurrency": [
                    { "minorUnits": "-6173", "currencyCode": "INR", "currencyExponent": 2 }
                  ]
                }
              },
              "settlementPlan": {
                "revision": \(revision),
                "mode": "DIRECT",
                "transfers": [
                  {
                    "planTransferId": "transfer-a",
                    "payerMemberId": "member-a",
                    "recipientMemberId": "member-b",
                    "amount": { "minorUnits": "6173", "currencyCode": "INR", "currencyExponent": 2 },
                    "mode": "DIRECT",
                    "obligationComponentIds": ["expense-a"]
                  }
                ]
              },
              "settlementHistory": [],
              "activity": [],
              "pendingOperationIds": [],
              "migration": {
                "status": "complete",
                "source": "server",
                "migrationId": null,
                "importedAt": null,
                "dualWriteEnabled": false,
                "recoveryReadOnly": false
              },
              "stale": {
                "isStale": false,
                "reason": "",
                "observedAt": "2026-08-04T00:00:00.000Z",
                "readRevision": \(readRevision),
                "serverRevision": \(revision)
              },
              "authority": {
                "serverAuthoritative": true,
                "source": "server",
                "readModel": "server",
                "ledger": "server",
                "balances": "server",
                "settlementPlan": "server",
                "settlementHistory": "server",
                "identity": "server",
                "cacheRole": "read_only"
              }
            }
          }
        }
        """
        return ServerLedgerSnapshot(
            accountID: "account-a",
            groupID: "group-a",
            revision: revision,
            payload: Data(payload.utf8)
        )
    }
}

private enum FakeCanonicalResult: Sendable {
    case snapshot(ServerLedgerSnapshot)
    case offline
    case conflict(ServerLedgerSnapshot)

    func value() throws -> ServerLedgerSnapshot {
        switch self {
        case let .snapshot(snapshot):
            return snapshot
        case .offline:
            throw ServerLedgerAPIClientError.offline
        case let .conflict(snapshot):
            throw ServerLedgerAPIClientError.revisionConflict(
                expectedRevision: 4,
                currentRevision: snapshot.revision,
                snapshot: snapshot
            )
        }
    }
}

private actor RecordingCanonicalLedgerAPI: ServerLedgerAPIClient {
    let fetchResult: FakeCanonicalResult
    var submitResults: [FakeCanonicalResult]
    private(set) var submitCount = 0

    init(
        fetchResult: FakeCanonicalResult = .offline,
        submitResults: [FakeCanonicalResult] = []
    ) {
        self.fetchResult = fetchResult
        self.submitResults = submitResults
    }

    func fetchSnapshot(for scope: ServerBackedLedgerScope) async throws -> ServerLedgerSnapshot {
        try fetchResult.value()
    }

    func submit(_ request: ServerLedgerMutationRequest) async throws -> ServerLedgerSnapshot {
        submitCount += 1
        guard submitResults.isEmpty == false else {
            throw ServerLedgerAPIClientError.offline
        }
        return try submitResults.removeFirst().value()
    }
}
