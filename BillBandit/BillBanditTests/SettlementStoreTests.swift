import XCTest
@testable import BillBandit

@MainActor
final class SettlementStoreTests: XCTestCase {
    func testStaleResponseDoesNotRegressVersion() async throws {
        let client = APIClient(baseURL: try XCTUnwrap(URL(string: "mock://billbandit"))) { "mock-token" }
        let store = SettlementStore()
        store.configure(apiClient: client, groupId: "group-nyc")

        let initial = SettlementSnapshotDTO(
            mode: "snapshot",
            version: 5,
            lifecycle: SettlementLifecycleDTO(isArchived: false, isFinalized: false),
            simplifyDebts: true,
            latestSettingAudit: nil,
            settlementCompletedAt: nil,
            permissions: SettlementPermissionsDTO(
                canReadPlan: true,
                canReadHistory: true,
                canSettleOrReverse: true,
                canChangeSetting: true,
                canAuthorizeRealtime: true,
                readScope: "full",
                callerParticipantId: "participant-user-alice"
            ),
            realtime: SettlementRealtimeDTO(available: false),
            plan: [],
            settled: SettlementSettledPageDTO(items: [], nextCursor: nil),
            reason: nil,
            fromVersion: nil,
            toVersion: nil,
            envelopes: nil
        )
        store.applyForTesting(initial)
        XCTAssertEqual(store.appliedVersion, 5)

        let stale = SettlementSnapshotDTO(
            mode: "snapshot",
            version: 3,
            lifecycle: initial.lifecycle,
            simplifyDebts: true,
            latestSettingAudit: nil,
            settlementCompletedAt: nil,
            permissions: initial.permissions,
            realtime: initial.realtime,
            plan: [sampleTransfer()],
            settled: initial.settled,
            reason: nil,
            fromVersion: nil,
            toVersion: nil,
            envelopes: nil
        )
        store.applyForTesting(stale)
        XCTAssertEqual(store.appliedVersion, 5)
        XCTAssertTrue(store.snapshot?.plan.isEmpty == true)
    }

    func testDuplicateRealtimeEventsCoalesce() async {
        let realtime = FakeSettlementRealtimeClient()
        let store = SettlementStore(realtimeClient: realtime)
        store.configure(apiClient: APIClient(baseURL: URL(string: "mock://billbandit")!) { "mock-token" }, groupId: "group-alice-bob")
        store.applyForTesting(snapshot(version: 2))

        store.applyRealtimeVersion(2)
        store.applyRealtimeVersion(1)
        store.applyRealtimeVersion(2)
        XCTAssertEqual(store.appliedVersion, 2)
    }

    func testNoChangePreservesPlan() {
        let store = SettlementStore()
        let plan = [sampleTransfer()]
        store.applyForTesting(snapshot(version: 4, plan: plan))
        let noChange = SettlementSnapshotDTO(
            mode: "no_change",
            version: 4,
            lifecycle: SettlementLifecycleDTO(isArchived: false, isFinalized: false),
            simplifyDebts: true,
            latestSettingAudit: nil,
            settlementCompletedAt: nil,
            permissions: fullPermissions(),
            realtime: SettlementRealtimeDTO(available: false),
            plan: [],
            settled: SettlementSettledPageDTO(items: [], nextCursor: nil),
            reason: nil,
            fromVersion: nil,
            toVersion: nil,
            envelopes: nil
        )
        store.applyForTesting(noChange)
        XCTAssertEqual(store.snapshot?.plan.count, 1)
        XCTAssertEqual(store.appliedVersion, 4)
    }

    func testLimitedReadScopeYourTransfersUsesFullPlan() {
        let transfer = sampleTransfer()
        let permissions = SettlementPermissionsDTO(
            canReadPlan: true,
            canReadHistory: true,
            canSettleOrReverse: true,
            canChangeSetting: false,
            canAuthorizeRealtime: true,
            readScope: "limited",
            callerParticipantId: "participant-user-alice"
        )
        let yours = SharedSettleUpProjection.yourTransfers(
            plan: [transfer],
            permissions: permissions,
            callerParticipantId: "participant-user-alice",
            currentUserLabel: "You"
        )
        XCTAssertEqual(yours.count, 1)
        let everyone = SharedSettleUpProjection.everyoneTransfers(
            plan: [transfer],
            permissions: permissions,
            yourTransfers: yours
        )
        XCTAssertTrue(everyone.isEmpty)
    }

    func testUnrelatedAdministratorCannotSettle() {
        let transfer = sampleTransfer()
        let permissions = fullPermissions()
        XCTAssertFalse(
            SharedSettleUpProjection.canSettle(
                transfer: transfer,
                permissions: permissions,
                callerParticipantId: "participant-user-carol",
                currentUserLabel: "Carol"
            )
        )
    }

    func testMinorUnitFormatting() {
        XCTAssertEqual("10.50".paddingMinorUnits(exponent: 2), "1050")
        XCTAssertEqual("250".paddingMinorUnits(exponent: 0), "250")
    }

    func testRefreshLoadsMockSnapshot() async throws {
        let client = APIClient(baseURL: try XCTUnwrap(URL(string: "mock://billbandit"))) { "mock-token-alice" }
        let store = SettlementStore()
        store.configure(apiClient: client, groupId: "group-nyc")
        await store.refresh()
        XCTAssertNotNil(store.snapshot, store.lastError ?? "expected snapshot")
        XCTAssertFalse(store.isLoading)
    }

    private func sampleTransfer() -> SettlementPlanTransferDTO {
        SettlementPlanTransferDTO(
            planTransferId: "transfer-1",
            payerParticipantId: "participant-user-alice",
            recipientParticipantId: "participant-user-bob",
            payerName: "You",
            recipientName: "Bob Smith",
            amount: "25.00",
            currencyCode: "USD",
            currencyExponent: 2,
            mode: "simplified"
        )
    }

    private func snapshot(version: Int, plan: [SettlementPlanTransferDTO] = []) -> SettlementSnapshotDTO {
        SettlementSnapshotDTO(
            mode: "snapshot",
            version: version,
            lifecycle: SettlementLifecycleDTO(isArchived: false, isFinalized: false),
            simplifyDebts: true,
            latestSettingAudit: nil,
            settlementCompletedAt: nil,
            permissions: fullPermissions(),
            realtime: SettlementRealtimeDTO(available: false),
            plan: plan,
            settled: SettlementSettledPageDTO(items: [], nextCursor: nil),
            reason: nil,
            fromVersion: nil,
            toVersion: nil,
            envelopes: nil
        )
    }

    private func fullPermissions() -> SettlementPermissionsDTO {
        SettlementPermissionsDTO(
            canReadPlan: true,
            canReadHistory: true,
            canSettleOrReverse: true,
            canChangeSetting: true,
            canAuthorizeRealtime: true,
            readScope: "full",
            callerParticipantId: "participant-user-alice"
        )
    }
}
