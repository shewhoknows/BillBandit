import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class SettlementStore {
    private(set) var snapshot: SettlementSnapshotDTO?
    private(set) var isLoading = false
    private(set) var isUpdating = false
    private(set) var isOffline = false
    private(set) var lastError: String?
    private(set) var appliedVersion = 0
    private(set) var readRevision: Int64?
    private(set) var requiresReconfirmation = false
    private(set) var callerParticipantId: String?
    private(set) var explanation: SettlementExplanationDTO?
    private(set) var explanationError: String?
    private(set) var canonicalServerSnapshot: ServerLedgerSnapshot?
    private(set) var canonicalSnapshot: SettlementCanonicalLedgerSnapshot?
    private(set) var isMigrationBlocked = false

    private let serverLedgerStore: ServerLedgerStore
    private var serverLedgerAPIClient: any ServerLedgerAPIClient
    private var serverLedgerSync: ServerLedgerSync?
    private var configuredScope: ServerBackedLedgerScope?
    private var legacyAPIClient = APIClient.live()
    private var pollingTask: Task<Void, Never>?
    private var isVisible = false
    private var realtimeClient: SettlementRealtimeClient
    private var pendingRefreshVersion: Int?
    private var currentUserLabel = "You"
    private var operationIDsByActionKey: [String: UUID] = [:]

    var writesEnabled: Bool {
        guard let snapshot, let canonicalSnapshot else { return false }
        return !isUpdating
            && !isOffline
            && !requiresReconfirmation
            && !isMigrationBlocked
            && !canonicalSnapshot.isStale
            && snapshot.lifecycle.isArchived == false
            && snapshot.permissions.canSettleOrReverse
    }

    /// T-12 supplies an account-scoped durable queue. Offline settlement is
    /// therefore allowed only when the current canonical snapshot is usable;
    /// the local SwiftData Group/Settlement graph is never an alternative.
    var canQueueSettlement: Bool {
        guard let snapshot, let canonicalSnapshot else { return false }
        return isOffline
            && !isMigrationBlocked
            && !canonicalSnapshot.isStale
            && snapshot.lifecycle.isArchived == false
            && snapshot.permissions.canSettleOrReverse
    }

    var hasCanonicalReadModel: Bool { canonicalSnapshot != nil }

    var canonicalExpenses: [SettlementLedgerExpense] {
        canonicalSnapshot?.group.invoiceExpenses() ?? []
    }

    var canonicalTotalMoney: ServerLedgerMoneyDTO? {
        guard let group = canonicalSnapshot?.group else { return nil }
        return sumBaseCurrency(
            group.expenses.filter { $0.status == "active" }.map { $0.amount }
        )
    }

    var canonicalMyPaidMoney: ServerLedgerMoneyDTO? {
        guard let group = canonicalSnapshot?.group, let memberID = group.currentMemberID else { return nil }
        return sumBaseCurrency(
            group.expenses.filter { $0.status == "active" && $0.paidByMemberID == memberID }.map { $0.amount }
        )
    }

    var canonicalMyShareMoney: ServerLedgerMoneyDTO? {
        guard let group = canonicalSnapshot?.group, let memberID = group.currentMemberID else { return nil }
        return sumBaseCurrency(
            group.expenses
                .filter { $0.status == "active" }
                .flatMap { $0.splits }
                .filter { $0.memberID == memberID }
                .map { $0.amount }
        )
    }

    var canonicalBalanceMoney: ServerLedgerMoneyDTO? {
        guard let group = canonicalSnapshot?.group else { return nil }
        return group.baseCurrencyMoney(from: group.balances.currentAccount.byCurrency)
    }

    var canonicalBalanceLines: [SettlementLedgerBalanceLine] {
        guard let group = canonicalSnapshot?.group, let memberID = group.currentMemberID else { return [] }
        let members = group.memberByID
        return group.settlementPlan.transfers.compactMap { transfer in
            guard transfer.amount.currencyCode == group.baseCurrency.currencyCode,
                  transfer.amount.currencyExponent == group.baseCurrency.currencyExponent else { return nil }
            if transfer.payerMemberID == memberID, let recipient = members[transfer.recipientMemberID] {
                return SettlementLedgerBalanceLine(
                    id: transfer.planTransferID,
                    memberID: recipient.memberID,
                    memberName: "You owe \(recipient.displayName)",
                    amount: transfer.amount
                )
            }
            if transfer.recipientMemberID == memberID, let payer = members[transfer.payerMemberID] {
                return SettlementLedgerBalanceLine(
                    id: transfer.planTransferID,
                    memberID: payer.memberID,
                    memberName: "\(payer.displayName) owes you",
                    amount: transfer.amount
                )
            }
            return nil
        }
    }

    init(
        realtimeClient: SettlementRealtimeClient? = nil,
        serverLedgerStore: ServerLedgerStore? = nil,
        serverLedgerAPIClient: (any ServerLedgerAPIClient)? = nil
    ) {
        self.serverLedgerStore = serverLedgerStore ?? SettlementLedgerRuntime.store
        self.serverLedgerAPIClient = serverLedgerAPIClient ?? SettlementServerLedgerTransport()
        let client = realtimeClient ?? makeDefaultSettlementRealtimeClient()
        self.realtimeClient = client
        self.realtimeClient.onVersion = { [weak self] event in
            Task { @MainActor in
                self?.applyRealtimeVersion(event.version)
            }
        }
    }

    /// Configures the canonical account/group scope. The old settle-up
    /// endpoint is not used as a read authority; it is retained only inside
    /// the compatibility mutation adapter below.
    func configure(
        serverLedgerAPIClient: (any ServerLedgerAPIClient)? = nil,
        accountID: String,
        groupID: String,
        currentUserLabel: String = "You"
    ) {
        let accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountID.isEmpty, !groupID.isEmpty else {
            markIdentityUnavailable()
            return
        }

        if let serverLedgerAPIClient {
            self.serverLedgerAPIClient = serverLedgerAPIClient
        }
        let scope = ServerBackedLedgerScope(accountID: accountID, groupID: groupID)
        let scopeChanged = configuredScope != scope
        configuredScope = scope
        self.currentUserLabel = currentUserLabel
        if scopeChanged {
            snapshot = nil
            canonicalServerSnapshot = nil
            canonicalSnapshot = nil
            readRevision = nil
            appliedVersion = 0
            callerParticipantId = nil
            isMigrationBlocked = false
            requiresReconfirmation = false
            operationIDsByActionKey.removeAll()
        }

        do {
            let sync = ServerLedgerSync(store: serverLedgerStore, apiClient: self.serverLedgerAPIClient)
            try sync.activate(accountID: accountID)
            serverLedgerSync = sync
            lastError = nil
        } catch {
            serverLedgerSync = nil
            lastError = errorDescription(error)
        }
    }

    func markIdentityUnavailable() {
        lastError = SettlementClientError.unauthorized.errorDescription
        isOffline = false
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        if visible {
            Task { await refresh(forceWritesDisabled: true) }
        } else {
            stopPolling()
            Task { @MainActor in
                await realtimeClient.unsubscribe()
            }
        }
    }

    func refreshOnForeground() async {
        guard isVisible else { return }
        await refresh(forceWritesDisabled: true)
    }

    func refresh(forceWritesDisabled: Bool = false) async {
        _ = forceWritesDisabled
        guard let scope = configuredScope, let serverLedgerSync else { return }
        if snapshot == nil {
            isLoading = true
        } else {
            isUpdating = true
        }
        defer {
            isLoading = false
            isUpdating = false
        }

        loadCachedSnapshot(for: scope)
        serverLedgerSync.markReconnected()
        do {
            let serverSnapshot = try await serverLedgerSync.onForeground(scope: scope)
            try applyCanonical(serverSnapshot)
            isOffline = false
            lastError = nil
            await subscribeRealtimeIfNeeded()
            startPollingIfNeeded()
        } catch {
            if isOfflineError(error) {
                isOffline = true
            }
            lastError = errorDescription(error)
            if case ServerLedgerSyncError.conflictRequiresReconfirmation = error {
                requiresReconfirmation = true
            }
        }
    }

    func loadMoreHistory() async {
        // The canonical ledger read model carries the complete history for
        // this surface. There is no legacy cursor that may become a second
        // source of settlement truth.
    }

    func loadExplanation(for transfer: SettlementPlanTransferDTO) async {
        _ = transfer
        explanation = nil
        explanationError = nil
        guard canonicalSnapshot != nil else {
            explanationError = SettlementClientError.explanationUnavailable.errorDescription
            return
        }
        // The v2 read model exposes the exact plan/history, not a separate
        // legacy explanation endpoint. Keeping this read-only makes the
        // Details affordance honest until a canonical explanation is added.
        explanationError = SettlementClientError.explanationUnavailable.errorDescription
    }

    func canStartSettlement(_ transfer: SettlementPlanTransferDTO) -> Bool {
        guard isCurrentTransfer(transfer), canSettle(transfer) else { return false }
        return writesEnabled || canQueueSettlement || requiresReconfirmation
    }

    func canConfirmSettlement(_ transfer: SettlementPlanTransferDTO, expectedVersion: Int) -> Bool {
        guard isCurrentTransfer(transfer), let snapshot,
              expectedVersion == snapshot.version else { return false }
        return canStartSettlement(transfer)
    }

    func settle(transfer: SettlementPlanTransferDTO, note: String?, expectedVersion: Int) async throws {
        guard let scope = configuredScope, let snapshot, canonicalSnapshot != nil else {
            throw SettlementClientError.writeDisabled
        }
        guard expectedVersion == snapshot.version,
              isCurrentTransfer(transfer),
              canSettle(transfer) else {
            requiresReconfirmation = true
            throw SettlementClientError.requiresReconfirmation
        }
        guard writesEnabled || canQueueSettlement || requiresReconfirmation else {
            throw SettlementClientError.writeDisabled
        }

        let note = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = CreateSettlementRequest(
            expectedVersion: expectedVersion,
            planTransferId: transfer.planTransferId,
            payerParticipantId: transfer.payerParticipantId,
            recipientParticipantId: transfer.recipientParticipantId,
            currencyCode: transfer.currencyCode,
            currencyExponent: transfer.currencyExponent,
            // This is copied from the canonical transfer; it is never
            // reconstructed from the compatibility decimal display string.
            minorUnits: transfer.minorUnits,
            note: note?.isEmpty == false ? note : nil
        )
        let actionKey = "settlement:\(scope.groupID):\(transfer.planTransferId):\(expectedVersion):\(transfer.minorUnits)"
        let operationID = try operationID(for: actionKey, scope: scope)
        let body = try JSONEncoder.serverLedger.encode(request)
        let mutation = ServerLedgerMutationRequest(
            operationID: operationID,
            scope: .serverBacked(accountID: scope.accountID, groupID: scope.groupID),
            expectedRevision: Int64(expectedVersion),
            kind: "settlement.create",
            method: "POST",
            path: settlementPath(groupID: scope.groupID),
            body: body
        )
        try enqueueIfNeeded(mutation, actionKey: actionKey)
        requiresReconfirmation = false
        isUpdating = true
        defer { isUpdating = false }
        do {
            try await reconcileAfterMutation(scope: scope)
        } catch let error as SettlementClientError where error == .offline {
            // The durable queue is the eligible offline path. The UI can
            // remain on the cached canonical read model and will drain on the
            // next foreground/reconnect cycle.
        } catch {
            throw error
        }
    }

    func reverse(settlementId: String) async throws {
        guard let scope = configuredScope, let snapshot, canonicalSnapshot != nil else {
            throw SettlementClientError.writeDisabled
        }
        guard writesEnabled || canQueueSettlement else {
            throw SettlementClientError.writeDisabled
        }
        let actionKey = "reversal:\(scope.groupID):\(settlementId):\(snapshot.version)"
        let operationID = try operationID(for: actionKey, scope: scope)
        let request = CreateReversalRequest(expectedVersion: snapshot.version)
        let body = try JSONEncoder.serverLedger.encode(request)
        let mutation = ServerLedgerMutationRequest(
            operationID: operationID,
            scope: .serverBacked(accountID: scope.accountID, groupID: scope.groupID),
            expectedRevision: Int64(snapshot.version),
            kind: "settlement.reverse",
            method: "POST",
            path: reversalPath(groupID: scope.groupID, settlementID: settlementId),
            body: body
        )
        try enqueueIfNeeded(mutation, actionKey: actionKey)
        isUpdating = true
        defer { isUpdating = false }
        do {
            try await reconcileAfterMutation(scope: scope)
        } catch let error as SettlementClientError where error == .offline {
            // Keep the queued reversal durable and show the cached history.
        } catch {
            throw error
        }
    }

    func updateSimplifyDebts(_ enabled: Bool) async throws {
        _ = enabled
        // The canonical group read model is authoritative and this ticket
        // does not expose a server setting mutation. The toggle is therefore
        // visibly disabled instead of mutating the local Group flag.
        throw SettlementClientError.writeDisabled
    }

    func applyRealtimeVersion(_ version: Int) {
        guard version > appliedVersion else { return }
        if isUpdating {
            pendingRefreshVersion = max(pendingRefreshVersion ?? 0, version)
            return
        }
        Task { await refresh(forceWritesDisabled: true) }
    }

    func yourTransfers() -> [SettlementPlanTransferDTO] {
        guard let snapshot else { return [] }
        return SharedSettleUpProjection.yourTransfers(
            plan: snapshot.plan,
            permissions: snapshot.permissions,
            callerParticipantId: callerParticipantId,
            currentUserLabel: currentUserLabel
        )
    }

    func everyoneTransfers() -> [SettlementPlanTransferDTO] {
        guard let snapshot else { return [] }
        let yours = yourTransfers()
        return SharedSettleUpProjection.everyoneTransfers(
            plan: snapshot.plan,
            permissions: snapshot.permissions,
            yourTransfers: yours
        )
    }

    func canSettle(_ transfer: SettlementPlanTransferDTO) -> Bool {
        guard let snapshot else { return false }
        return SharedSettleUpProjection.canSettle(
            transfer: transfer,
            permissions: snapshot.permissions,
            callerParticipantId: callerParticipantId,
            currentUserLabel: currentUserLabel
        )
    }

    // MARK: - Internal test hooks

    func applyForTesting(_ response: SettlementSnapshotDTO) {
        apply(response)
    }

    func applyCanonicalForTesting(_ serverSnapshot: ServerLedgerSnapshot) throws {
        try applyCanonical(serverSnapshot)
    }

    private func apply(_ response: SettlementSnapshotDTO) {
        guard response.version >= appliedVersion else { return }
        canonicalServerSnapshot = nil
        canonicalSnapshot = nil
        isMigrationBlocked = false
        readRevision = response.readRevision

        if response.mode == "no_change" {
            appliedVersion = response.version
            if let current = snapshot {
                snapshot = response.mergingPlanAndHistory(from: current)
            } else {
                snapshot = response
            }
            updateCallerParticipantId(from: snapshot)
            return
        }

        if response.mode == "incremental", response.reason == nil, let current = snapshot, response.plan.isEmpty {
            snapshot = current.updatingMetadata(from: response)
            appliedVersion = response.version
            updateCallerParticipantId(from: snapshot)
            return
        }

        snapshot = response
        appliedVersion = response.version
        updateCallerParticipantId(from: snapshot)

        if let pendingRefreshVersion, pendingRefreshVersion > appliedVersion {
            self.pendingRefreshVersion = nil
            Task { await refresh(forceWritesDisabled: true) }
        }
    }

    private func applyCanonical(_ serverSnapshot: ServerLedgerSnapshot) throws {
        guard let scope = configuredScope,
              serverSnapshot.accountID == scope.accountID,
              serverSnapshot.groupID == scope.groupID else {
            throw ServerLedgerSyncError.snapshotScopeMismatch
        }
        let envelope = try JSONDecoder.serverLedger.decode(
            SettlementCanonicalLedgerReadEnvelope.self,
            from: serverSnapshot.payload
        )
        guard envelope.contractVersion == ServerLedgerContract.version,
              envelope.kind == "read",
              envelope.scope.kind == .shared,
              envelope.scope.accountID == scope.accountID,
              envelope.scope.groupID == scope.groupID,
              envelope.scope.localOnly == false,
              envelope.data.group.groupID == scope.groupID,
              envelope.data.group.accountID == scope.accountID,
              envelope.data.group.localOnly == false,
              envelope.data.group.scope == "shared",
              envelope.revision == serverSnapshot.revision,
              Int64(envelope.data.group.revision) == envelope.revision,
              Int64(envelope.data.group.readRevision) == envelope.readRevision else {
            throw ServerLedgerAPIClientError.snapshotScopeMismatch
        }

        let canonical = SettlementCanonicalLedgerSnapshot(envelope: envelope)
        canonicalServerSnapshot = serverSnapshot
        canonicalSnapshot = canonical
        readRevision = canonical.readRevision
        appliedVersion = Int(canonical.revision)
        isMigrationBlocked = !canonical.group.isMigrationReady
        snapshot = canonical.group.uiSnapshot(
            realtimeAvailable: SettlementRealtimeConfig.isPusherConfigured
        )
        updateCallerParticipantId(from: snapshot)
    }

    private func loadCachedSnapshot(for scope: ServerBackedLedgerScope) {
        do {
            guard let cached = try serverLedgerStore.cachedSnapshot(for: scope) else { return }
            try applyCanonical(cached)
        } catch {
            lastError = errorDescription(error)
        }
    }

    private func updateCallerParticipantId(from snapshot: SettlementSnapshotDTO?) {
        if let explicit = snapshot?.permissions.callerParticipantId {
            callerParticipantId = explicit
            return
        }
        guard callerParticipantId == nil, let snapshot else { return }
        for transfer in snapshot.plan {
            if transfer.payerName.caseInsensitiveCompare("You") == .orderedSame
                || transfer.payerName.caseInsensitiveCompare(currentUserLabel) == .orderedSame {
                callerParticipantId = transfer.payerParticipantId
                return
            }
            if transfer.recipientName.caseInsensitiveCompare("You") == .orderedSame
                || transfer.recipientName.caseInsensitiveCompare(currentUserLabel) == .orderedSame {
                callerParticipantId = transfer.recipientParticipantId
                return
            }
        }
    }

    private func isCurrentTransfer(_ transfer: SettlementPlanTransferDTO) -> Bool {
        guard let current = snapshot?.plan.first(where: { $0.planTransferId == transfer.planTransferId }) else {
            return false
        }
        return current.payerParticipantId == transfer.payerParticipantId
            && current.recipientParticipantId == transfer.recipientParticipantId
            && current.currencyCode == transfer.currencyCode
            && current.currencyExponent == transfer.currencyExponent
            && current.minorUnits == transfer.minorUnits
    }

    private func operationID(for actionKey: String, scope: ServerBackedLedgerScope) throws -> UUID {
        if let operationID = operationIDsByActionKey[actionKey] {
            if let existing = try serverLedgerStore.pendingOperations(
                for: .serverBacked(accountID: scope.accountID, groupID: scope.groupID),
                includingCompleted: true
            ).first(where: { $0.operationID == operationID }) {
                if existing.retryState == .failed {
                    requiresReconfirmation = true
                    throw SettlementClientError.requiresReconfirmation
                }
                return operationID
            }
            return operationID
        }
        let operationID = UUID()
        operationIDsByActionKey[actionKey] = operationID
        return operationID
    }

    private func enqueueIfNeeded(
        _ mutation: ServerLedgerMutationRequest,
        actionKey: String
    ) throws {
        let rows = try serverLedgerStore.pendingOperations(
            for: mutation.scope,
            includingCompleted: true
        )
        if let existing = rows.first(where: { $0.operationID == mutation.operationID }) {
            guard existing.requestPayload == mutation.requestPayload,
                  existing.expectedRevision == mutation.expectedRevision else {
                throw ServerLedgerStoreError.operationIDCollision
            }
            if existing.retryState == .failed {
                requiresReconfirmation = true
                throw SettlementClientError.requiresReconfirmation
            }
            return
        }
        _ = try serverLedgerStore.enqueue(mutation)
        operationIDsByActionKey[actionKey] = mutation.operationID
    }

    private func reconcileAfterMutation(scope: ServerBackedLedgerScope) async throws {
        guard let serverLedgerSync else { throw SettlementClientError.writeDisabled }
        do {
            let canonical = try await serverLedgerSync.onForeground(scope: scope)
            try applyCanonical(canonical)
            isOffline = false
            lastError = nil
            requiresReconfirmation = false
        } catch {
            if isOfflineError(error) {
                isOffline = true
                lastError = errorDescription(error)
                throw SettlementClientError.offline
            }
            if isConflictError(error) {
                loadCachedSnapshot(for: scope)
                requiresReconfirmation = true
                lastError = SettlementClientError.requiresReconfirmation.errorDescription
                throw SettlementClientError.requiresReconfirmation
            }
            lastError = errorDescription(error)
            throw mapClientError(error)
        }
    }

    private func sumBaseCurrency(_ values: [ServerLedgerMoneyDTO]) -> ServerLedgerMoneyDTO {
        let group = canonicalSnapshot?.group
        let code = group?.baseCurrency.currencyCode ?? values.first?.currencyCode ?? Money.currentCurrency.rawValue
        let exponent = group?.baseCurrency.currencyExponent ?? values.first?.currencyExponent ?? 2
        let minorUnits = values
            .filter { $0.currencyCode == code && $0.currencyExponent == exponent }
            .reduce("0") { SettlementMoneyFormatting.add($0, $1.minorUnits) }
        return ServerLedgerMoneyDTO(
            minorUnits: minorUnits,
            currencyCode: code,
            currencyExponent: exponent
        )
    }

    private func subscribeRealtimeIfNeeded() async {
        guard let scope = configuredScope,
              snapshot?.realtime.available == true else { return }
        await realtimeClient.subscribe(groupId: scope.groupID, apiClient: legacyAPIClient)
    }

    private func startPollingIfNeeded() {
        stopPolling()
        guard isVisible, snapshot?.realtime.available == false else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.isVisible else { continue }
                await self.refresh(forceWritesDisabled: false)
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func settlementPath(groupID: String) -> String {
        "/api/groups/\(encodedPathComponent(groupID))/settlements"
    }

    private func reversalPath(groupID: String, settlementID: String) -> String {
        "/api/groups/\(encodedPathComponent(groupID))/settlements/\(encodedPathComponent(settlementID))/reversals"
    }

    private func encodedPathComponent(_ value: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func isOfflineError(_ error: Error) -> Bool {
        switch error {
        case ServerLedgerSyncError.offline, ServerLedgerAPIClientError.offline,
             SettlementAPIError.offline:
            return true
        default:
            return false
        }
    }

    private func isConflictError(_ error: Error) -> Bool {
        switch error {
        case ServerLedgerSyncError.conflictRequiresReconfirmation,
             ServerLedgerAPIClientError.revisionConflict,
             SettlementClientError.versionConflict,
             SettlementClientError.requiresReconfirmation:
            return true
        default:
            return false
        }
    }

    private func mapClientError(_ error: Error) -> Error {
        switch error {
        case ServerLedgerSyncError.unauthorized, ServerLedgerAPIClientError.unauthorized,
             SettlementAPIError.unauthorized:
            return SettlementClientError.unauthorized
        case ServerLedgerSyncError.offline, ServerLedgerAPIClientError.offline,
             SettlementAPIError.offline:
            return SettlementClientError.offline
        case ServerLedgerSyncError.conflictRequiresReconfirmation,
             ServerLedgerAPIClientError.revisionConflict:
            return SettlementClientError.requiresReconfirmation
        default:
            return error
        }
    }

    private func errorDescription(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: type(of: error))
    }
}

@MainActor
private enum SettlementLedgerRuntime {
    static let store = AppStore.serverLedgerStore
}

/// The old settlement routes still return a legacy mutation DTO. This adapter
/// lets queued T-12 operations use those routes while fetching the canonical
/// ledger immediately afterward. No legacy response is ever rendered.
private final class SettlementServerLedgerTransport: ServerLedgerAPIClient, @unchecked Sendable {
    private let canonical = URLSessionServerLedgerAPIClient.live()
    private let legacy = APIClient.live()

    func fetchSnapshot(for scope: ServerBackedLedgerScope) async throws -> ServerLedgerSnapshot {
        try await canonical.fetchSnapshot(for: scope)
    }

    func submit(_ request: ServerLedgerMutationRequest) async throws -> ServerLedgerSnapshot {
        guard case let .serverBacked(accountID, groupID) = request.scope else {
            throw ServerLedgerAPIClientError.invalidRequest
        }
        let scope = ServerBackedLedgerScope(accountID: accountID, groupID: groupID)
        do {
            switch request.kind.lowercased() {
            case "settlement.create":
                let body = try JSONDecoder.serverLedger.decode(
                    CreateSettlementRequest.self,
                    from: request.bodyPayload
                )
                _ = try await legacy.postSettlementMutation(
                    path: request.endpointPath ?? "/api/groups/\(groupID)/settlements",
                    body: body,
                    idempotencyKey: request.idempotencyKey
                )
            case "settlement.reverse":
                let body = try JSONDecoder.serverLedger.decode(
                    CreateReversalRequest.self,
                    from: request.bodyPayload
                )
                _ = try await legacy.postSettlementMutation(
                    path: request.endpointPath ?? "/api/groups/\(groupID)/settlements",
                    body: body,
                    idempotencyKey: request.idempotencyKey
                )
            default:
                return try await canonical.submit(request)
            }
            return try await canonical.fetchSnapshot(for: scope)
        } catch is SettlementMutationConflictError {
            let refreshed = try? await canonical.fetchSnapshot(for: scope)
            throw ServerLedgerAPIClientError.revisionConflict(
                expectedRevision: request.expectedRevision,
                currentRevision: refreshed?.revision,
                snapshot: refreshed
            )
        } catch let error as SettlementClientError where error == .versionConflict {
            let refreshed = try? await canonical.fetchSnapshot(for: scope)
            throw ServerLedgerAPIClientError.revisionConflict(
                expectedRevision: request.expectedRevision,
                currentRevision: refreshed?.revision,
                snapshot: refreshed
            )
        } catch let error as SettlementAPIError {
            switch error {
            case .unauthorized:
                throw ServerLedgerAPIClientError.unauthorized
            case .offline:
                throw ServerLedgerAPIClientError.offline
            case let .structured(code, status, _)
                where status == 409 || code == "REVISION_CONFLICT" || code == "SETTLEMENT_VERSION_CONFLICT":
                throw ServerLedgerAPIClientError.revisionConflict(
                    expectedRevision: request.expectedRevision,
                    currentRevision: nil,
                    snapshot: try? await canonical.fetchSnapshot(for: scope)
                )
            default:
                throw ServerLedgerAPIClientError.server(status: 500, code: error.localizedDescription)
            }
        } catch {
            throw error
        }
    }
}

private extension SettlementSnapshotDTO {
    func updatingMetadata(from response: SettlementSnapshotDTO) -> SettlementSnapshotDTO {
        SettlementSnapshotDTO(
            mode: response.mode,
            version: response.version,
            lifecycle: response.lifecycle,
            simplifyDebts: response.simplifyDebts,
            latestSettingAudit: response.latestSettingAudit,
            settlementCompletedAt: response.settlementCompletedAt,
            permissions: response.permissions,
            realtime: response.realtime,
            plan: plan,
            settled: settled,
            reason: response.reason,
            fromVersion: response.fromVersion,
            toVersion: response.toVersion,
            envelopes: response.envelopes,
            readRevision: response.readRevision
        )
    }
}
