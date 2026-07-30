import Foundation
import Observation

@MainActor
@Observable
final class SettlementStore {
    private(set) var snapshot: SettlementSnapshotDTO?
    private(set) var isLoading = false
    private(set) var isUpdating = false
    private(set) var isOffline = false
    private(set) var lastError: String?
    private(set) var appliedVersion = 0
    private(set) var requiresReconfirmation = false
    private(set) var callerParticipantId: String?
    private(set) var explanation: SettlementExplanationDTO?
    private(set) var explanationError: String?

    private var apiClient: APIClient?
    private var groupId: String?
    private var pollingTask: Task<Void, Never>?
    private var isVisible = false
    private var realtimeClient: SettlementRealtimeClient
    private var pendingRefreshVersion: Int?
    private var currentUserLabel = "You"

    var writesEnabled: Bool {
        snapshot != nil && !isUpdating && !isOffline && requiresReconfirmation == false
            && snapshot?.lifecycle.isArchived == false
    }

    init(realtimeClient: SettlementRealtimeClient? = nil) {
        let client = realtimeClient ?? makeDefaultSettlementRealtimeClient()
        self.realtimeClient = client
        self.realtimeClient.onVersion = { [weak self] event in
            Task { @MainActor in
                self?.applyRealtimeVersion(event.version)
            }
        }
    }

    func configure(apiClient: APIClient, groupId: String, currentUserLabel: String = "You") {
        self.apiClient = apiClient
        self.groupId = groupId
        self.currentUserLabel = currentUserLabel
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        if visible {
            Task {
                await refresh(forceWritesDisabled: true)
            }
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
        guard let apiClient, let groupId else { return }
        if snapshot == nil {
            isLoading = true
        } else {
            isUpdating = true
        }
        if forceWritesDisabled {
            requiresReconfirmation = false
        }
        defer {
            isLoading = false
            isUpdating = false
            if forceWritesDisabled, snapshot != nil {
                requiresReconfirmation = false
            }
        }

        do {
            let response = try await apiClient.fetchSettleUp(
                groupId: groupId,
                afterVersion: appliedVersion > 0 ? appliedVersion : nil
            )
            apply(response)
            isOffline = false
            lastError = nil
            await subscribeRealtimeIfNeeded()
            startPollingIfNeeded()
        } catch {
            if snapshot != nil {
                isOffline = true
                lastError = SettlementAPILog.sanitizedError(error)
            } else {
                lastError = SettlementAPILog.sanitizedError(error)
            }
        }
    }

    func loadMoreHistory() async {
        guard let apiClient, let groupId, let cursor = snapshot?.settled.nextCursor else { return }
        do {
            let page: SettlementSettledPageDTO = try await apiClient.get(
                "/api/groups/\(groupId)/settle-up/history?cursor=\(cursor)"
            )
            guard let current = snapshot else { return }
            snapshot = current.updatingSettled(
                items: current.settled.items + page.items,
                nextCursor: page.nextCursor
            )
        } catch {
            lastError = SettlementAPILog.sanitizedError(error)
        }
    }

    func loadExplanation(for transfer: SettlementPlanTransferDTO) async {
        guard let apiClient, let groupId, let snapshot else { return }
        explanation = nil
        explanationError = nil
        let encodedTransferId = transfer.planTransferId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? transfer.planTransferId
        let path = "/api/groups/\(groupId)/settle-up/transfers/\(encodedTransferId)/explanation?version=\(snapshot.version)"
        do {
            explanation = try await apiClient.get(path)
        } catch {
            explanationError = SettlementAPILog.sanitizedError(error)
        }
    }

    func settle(transfer: SettlementPlanTransferDTO, note: String?, expectedVersion: Int) async throws {
        guard writesEnabled, let apiClient, let groupId, let snapshot else {
            throw SettlementClientError.writeDisabled
        }
        let request = CreateSettlementRequest(
            expectedVersion: expectedVersion,
            planTransferId: transfer.planTransferId,
            payerParticipantId: transfer.payerParticipantId,
            recipientParticipantId: transfer.recipientParticipantId,
            currencyCode: transfer.currencyCode,
            currencyExponent: transfer.currencyExponent,
            minorUnits: SettlementMoneyFormatting.minorUnits(from: transfer.amount, exponent: transfer.currencyExponent),
            note: note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? note : nil
        )
        let idempotency = UUID().uuidString
        do {
            let response = try await apiClient.postSettlementMutation(
                path: "/api/groups/\(groupId)/settlements",
                body: request,
                idempotencyKey: idempotency
            )
            apply(response.state)
            requiresReconfirmation = false
        } catch let conflict as SettlementMutationConflictError {
            apply(conflict.state)
            requiresReconfirmation = true
            throw SettlementClientError.versionConflict
        } catch {
            throw error
        }
    }

    func reverse(settlementId: String) async throws {
        guard writesEnabled, let apiClient, let groupId, let snapshot else {
            throw SettlementClientError.writeDisabled
        }
        let request = CreateReversalRequest(expectedVersion: snapshot.version)
        do {
            let response = try await apiClient.postSettlementMutation(
                path: "/api/groups/\(groupId)/settlements/\(settlementId)/reversals",
                body: request,
                idempotencyKey: UUID().uuidString
            )
            apply(response.state)
            requiresReconfirmation = false
        } catch let conflict as SettlementMutationConflictError {
            apply(conflict.state)
            requiresReconfirmation = true
            throw SettlementClientError.versionConflict
        } catch {
            throw error
        }
    }

    func updateSimplifyDebts(_ enabled: Bool) async throws {
        guard writesEnabled, let apiClient, let groupId, let snapshot else {
            throw SettlementClientError.writeDisabled
        }
        guard snapshot.permissions.canChangeSetting else { return }
        guard snapshot.simplifyDebts != enabled else { return }
        let request = UpdateSettlementSettingsRequest(expectedVersion: snapshot.version, simplifyDebts: enabled)
        do {
            let response = try await apiClient.patchSettlementMutation(
                path: "/api/groups/\(groupId)/settlement-settings",
                body: request,
                idempotencyKey: UUID().uuidString
            )
            apply(response.state)
        } catch let conflict as SettlementMutationConflictError {
            apply(conflict.state)
            requiresReconfirmation = true
            throw SettlementClientError.versionConflict
        } catch {
            throw error
        }
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

    private func apply(_ response: SettlementSnapshotDTO) {
        if response.version < appliedVersion { return }

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

        if response.reason == "VERSION_GAP" || response.mode == "snapshot" {
            snapshot = response
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

    private func subscribeRealtimeIfNeeded() async {
        guard let apiClient, let groupId, snapshot?.realtime.available == true else { return }
        await realtimeClient.subscribe(groupId: groupId, apiClient: apiClient)
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
}

private extension SettlementSnapshotDTO {
    func updatingSettled(items: [SettlementHistoryItemDTO], nextCursor: String?) -> SettlementSnapshotDTO {
        SettlementSnapshotDTO(
            mode: mode,
            version: version,
            lifecycle: lifecycle,
            simplifyDebts: simplifyDebts,
            latestSettingAudit: latestSettingAudit,
            settlementCompletedAt: settlementCompletedAt,
            permissions: permissions,
            realtime: realtime,
            plan: plan,
            settled: SettlementSettledPageDTO(items: items, nextCursor: nextCursor),
            reason: reason,
            fromVersion: fromVersion,
            toVersion: toVersion,
            envelopes: envelopes
        )
    }

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
            envelopes: response.envelopes
        )
    }
}
