import Foundation

struct SettlementPermissionsDTO: Codable, Equatable {
    let canReadPlan: Bool
    let canReadHistory: Bool
    let canSettleOrReverse: Bool
    let canChangeSetting: Bool
    let canAuthorizeRealtime: Bool
    let readScope: String
    let callerParticipantId: String?
}

struct SettlementPlanTransferDTO: Codable, Equatable, Hashable, Identifiable {
    var id: String { planTransferId }
    let planTransferId: String
    let payerParticipantId: String
    let recipientParticipantId: String
    let payerName: String
    let recipientName: String
    let amount: String
    let currencyCode: String
    let currencyExponent: Int
    let mode: String
}

struct SettlementHistoryItemDTO: Codable, Equatable, Identifiable {
    let id: String
    let type: String
    let payerName: String?
    let recipientName: String?
    let amount: String?
    let currencyCode: String?
    let note: String?
    let actorName: String?
    let createdAt: String
    let settlementId: String?
}

struct SettlementSettingAuditDTO: Codable, Equatable {
    let simplifyDebts: Bool
    let actorUserId: String
    let actorName: String?
    let createdAt: String
}

struct SettlementLifecycleDTO: Codable, Equatable {
    let isArchived: Bool
    let isFinalized: Bool
}

struct SettlementRealtimeDTO: Codable, Equatable {
    let available: Bool
}

struct SettlementSettledPageDTO: Codable, Equatable {
    let items: [SettlementHistoryItemDTO]
    let nextCursor: String?
}

struct SettlementVersionEnvelopeDTO: Codable, Equatable {
    let version: Int
    let eventType: String
    let recordId: String?
    let createdAt: String
}

struct SettlementSnapshotDTO: Codable, Equatable {
    let mode: String
    let version: Int
    let lifecycle: SettlementLifecycleDTO
    let simplifyDebts: Bool
    let latestSettingAudit: SettlementSettingAuditDTO?
    let settlementCompletedAt: String?
    let permissions: SettlementPermissionsDTO
    let realtime: SettlementRealtimeDTO
    let plan: [SettlementPlanTransferDTO]
    let settled: SettlementSettledPageDTO
    let reason: String?
    let fromVersion: Int?
    let toVersion: Int?
    let envelopes: [SettlementVersionEnvelopeDTO]?

    func mergingPlanAndHistory(from previous: SettlementSnapshotDTO?) -> SettlementSnapshotDTO {
        guard mode == "no_change", let previous else { return self }
        return SettlementSnapshotDTO(
            mode: mode,
            version: version,
            lifecycle: lifecycle,
            simplifyDebts: simplifyDebts,
            latestSettingAudit: latestSettingAudit,
            settlementCompletedAt: settlementCompletedAt,
            permissions: permissions,
            realtime: realtime,
            plan: previous.plan,
            settled: previous.settled,
            reason: reason,
            fromVersion: fromVersion,
            toVersion: toVersion,
            envelopes: envelopes
        )
    }
}

struct CreateSettlementRequest: Codable {
    let expectedVersion: Int
    let planTransferId: String
    let payerParticipantId: String
    let recipientParticipantId: String
    let currencyCode: String
    let currencyExponent: Int
    let minorUnits: String
    let note: String?
}

struct CreateReversalRequest: Codable {
    let expectedVersion: Int
}

struct UpdateSettlementSettingsRequest: Codable {
    let expectedVersion: Int
    let simplifyDebts: Bool
}

struct SettlementMutationResponseDTO: Codable {
    let result: SettlementMutationResultDTO
    let state: SettlementSnapshotDTO
}

struct SettlementMutationResultDTO: Codable {
    let version: Int
    let recordId: String
    let eventType: String
}

struct SettleUpVersionAheadResponse: Decodable {
    let error: String
    let snapshot: SettlementSnapshotDTO?
}

struct SettlementConflictResponse: Codable {
    let error: String
    let requiresReconfirmation: Bool?
    let state: SettlementSnapshotDTO?
}

struct SettlementExplanationDTO: Decodable, Equatable {
    let mode: String
    let planTransferId: String
    let version: Int
    let directExpenses: [SettlementExplanationExpenseDTO]?
    let simplifiedPaths: [SettlementExplanationPathDTO]?
    let adjustments: [SettlementExplanationAdjustmentDTO]?
}

struct SettlementExplanationExpenseDTO: Decodable, Equatable, Identifiable {
    var id: String { expenseId }
    let expenseId: String
    let description: String
    let amount: String
}

struct SettlementExplanationPathDTO: Decodable, Equatable, Identifiable {
    var id: String { path }
    let path: String
    let amount: String
}

struct SettlementExplanationAdjustmentDTO: Decodable, Equatable, Identifiable {
    var id: String { label }
    let label: String
    let amount: String
}

struct SettlementTransferConfirmation: Equatable, Identifiable {
    let id: String
    let transfer: SettlementPlanTransferDTO
    let expectedVersion: Int
}

enum SettlementClientError: LocalizedError, Equatable {
    case offline
    case versionConflict
    case staleResponse
    case writeDisabled
    case explanationUnavailable

    var errorDescription: String? {
        switch self {
        case .offline: "Offline"
        case .versionConflict: "Settlement changed. Confirm again."
        case .staleResponse: "Stale response ignored"
        case .writeDisabled: "Writes disabled while updating"
        case .explanationUnavailable: "Could not load transfer details"
        }
    }
}

struct SettlementMutationConflictError: Error {
    let state: SettlementSnapshotDTO
}

enum SettlementMoneyFormatting {
    static func minorUnits(from decimalAmount: String, exponent: Int) -> String {
        decimalAmount.paddingMinorUnits(exponent: exponent)
    }
}

extension String {
    func paddingMinorUnits(exponent: Int) -> String {
        let parts = split(separator: ".", omittingEmptySubsequences: false)
        let whole = parts.first.map(String.init) ?? "0"
        let fraction = parts.count > 1 ? String(parts[1]) : ""
        let padded = fraction.padding(toLength: exponent, withPad: "0", startingAt: 0)
        let combined = whole + padded
        if combined.allSatisfy({ $0 == "0" }) { return "0" }
        return combined.replacingOccurrences(of: "^0+", with: "", options: .regularExpression)
    }
}

enum SharedSettleUpProjection {
    static func yourTransfers(
        plan: [SettlementPlanTransferDTO],
        permissions: SettlementPermissionsDTO,
        callerParticipantId: String?,
        currentUserLabel: String
    ) -> [SettlementPlanTransferDTO] {
        if permissions.readScope == "limited" {
            return plan
        }
        if let callerParticipantId {
            return plan.filter {
                $0.payerParticipantId == callerParticipantId || $0.recipientParticipantId == callerParticipantId
            }
        }
        return plan.filter { transfer in
            nameMatchesCurrentUser(transfer.payerName, currentUserLabel)
                || nameMatchesCurrentUser(transfer.recipientName, currentUserLabel)
        }
    }

    static func everyoneTransfers(
        plan: [SettlementPlanTransferDTO],
        permissions: SettlementPermissionsDTO,
        yourTransfers: [SettlementPlanTransferDTO]
    ) -> [SettlementPlanTransferDTO] {
        guard permissions.readScope == "full" else { return [] }
        let yours = Set(yourTransfers.map(\.planTransferId))
        return plan.filter { !yours.contains($0.planTransferId) }
    }

    static func canSettle(
        transfer: SettlementPlanTransferDTO,
        permissions: SettlementPermissionsDTO,
        callerParticipantId: String?,
        currentUserLabel: String
    ) -> Bool {
        guard permissions.canSettleOrReverse else { return false }
        if permissions.readScope == "limited" { return true }
        if let callerParticipantId {
            return transfer.payerParticipantId == callerParticipantId
                || transfer.recipientParticipantId == callerParticipantId
        }
        return nameMatchesCurrentUser(transfer.payerName, currentUserLabel)
            || nameMatchesCurrentUser(transfer.recipientName, currentUserLabel)
    }

    static func canReverse(
        historyItem: SettlementHistoryItemDTO,
        permissions: SettlementPermissionsDTO
    ) -> Bool {
        guard permissions.canSettleOrReverse, historyItem.type == "settlement" else { return false }
        return historyItem.settlementId == nil
    }

    private static func nameMatchesCurrentUser(_ name: String, _ currentUserLabel: String) -> Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedUser = currentUserLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedName == "you" || normalizedName == normalizedUser
    }
}
