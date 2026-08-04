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
    /// Canonical exact value retained from the v2 money object.
    let minorUnits: String
    let currencyCode: String
    let currencyExponent: Int
    let mode: String

    init(
        planTransferId: String,
        payerParticipantId: String,
        recipientParticipantId: String,
        payerName: String,
        recipientName: String,
        amount: String,
        currencyCode: String,
        currencyExponent: Int,
        mode: String,
        minorUnits: String? = nil
    ) {
        self.planTransferId = planTransferId
        self.payerParticipantId = payerParticipantId
        self.recipientParticipantId = recipientParticipantId
        self.payerName = payerName
        self.recipientName = recipientName
        self.currencyCode = currencyCode
        self.currencyExponent = currencyExponent
        self.minorUnits = minorUnits ?? SettlementMoneyFormatting.minorUnits(
            from: amount,
            exponent: currencyExponent
        )
        self.amount = minorUnits.map {
            SettlementMoneyFormatting.decimalString(fromMinorUnits: $0, exponent: currencyExponent)
        } ?? amount
        self.mode = mode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let planTransferId = try container.decode(String.self, forKey: .planTransferId)
        let payerParticipantId = try container.decode(String.self, forKey: .payerParticipantId)
        let recipientParticipantId = try container.decode(String.self, forKey: .recipientParticipantId)
        let payerName = try container.decode(String.self, forKey: .payerName)
        let recipientName = try container.decode(String.self, forKey: .recipientName)
        let mode = try container.decode(String.self, forKey: .mode)

        if let exact = try? container.decode(ServerLedgerMoneyDTO.self, forKey: .amount) {
            let currencyCode = (try? container.decode(String.self, forKey: .currencyCode)) ?? exact.currencyCode
            let currencyExponent = (try? container.decode(Int.self, forKey: .currencyExponent)) ?? exact.currencyExponent
            guard currencyCode == exact.currencyCode, currencyExponent == exact.currencyExponent else {
                throw ServerLedgerDTOError.invalidMoney(path: "amount")
            }
            self.init(
                planTransferId: planTransferId,
                payerParticipantId: payerParticipantId,
                recipientParticipantId: recipientParticipantId,
                payerName: payerName,
                recipientName: recipientName,
                amount: SettlementMoneyFormatting.decimalString(
                    fromMinorUnits: exact.minorUnits,
                    exponent: exact.currencyExponent
                ),
                currencyCode: exact.currencyCode,
                currencyExponent: exact.currencyExponent,
                mode: mode,
                minorUnits: exact.minorUnits
            )
            return
        }

        // The old settle-up endpoint used a decimal string. Keep decoding it
        // without floating point while ensuring new numeric amounts fail.
        let amount = try container.decode(String.self, forKey: .amount)
        let currencyCode = try container.decode(String.self, forKey: .currencyCode)
        let currencyExponent = try container.decode(Int.self, forKey: .currencyExponent)
        self.init(
            planTransferId: planTransferId,
            payerParticipantId: payerParticipantId,
            recipientParticipantId: recipientParticipantId,
            payerName: payerName,
            recipientName: recipientName,
            amount: amount,
            currencyCode: currencyCode,
            currencyExponent: currencyExponent,
            mode: mode
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(planTransferId, forKey: .planTransferId)
        try container.encode(payerParticipantId, forKey: .payerParticipantId)
        try container.encode(recipientParticipantId, forKey: .recipientParticipantId)
        try container.encode(payerName, forKey: .payerName)
        try container.encode(recipientName, forKey: .recipientName)
        try container.encode(
            ServerLedgerMoneyDTO(
                minorUnits: minorUnits,
                currencyCode: currencyCode,
                currencyExponent: currencyExponent
            ),
            forKey: .amount
        )
        try container.encode(currencyCode, forKey: .currencyCode)
        try container.encode(currencyExponent, forKey: .currencyExponent)
        try container.encode(mode, forKey: .mode)
    }

    private enum CodingKeys: String, CodingKey {
        case planTransferId
        case payerParticipantId
        case recipientParticipantId
        case payerName
        case recipientName
        case amount
        case currencyCode
        case currencyExponent
        case mode
    }
}

struct SettlementHistoryItemDTO: Codable, Equatable, Identifiable {
    let id: String
    let type: String
    let payerName: String?
    let recipientName: String?
    let amount: String?
    let currencyCode: String?
    let currencyExponent: Int?
    let note: String?
    let actorName: String?
    let createdAt: String
    let settlementId: String?
    let minorUnits: String?

    init(
        id: String,
        type: String,
        payerName: String?,
        recipientName: String?,
        amount: String?,
        currencyCode: String?,
        currencyExponent: Int? = nil,
        note: String?,
        actorName: String?,
        createdAt: String,
        settlementId: String?,
        minorUnits: String? = nil
    ) {
        self.id = id
        self.type = type
        self.payerName = payerName
        self.recipientName = recipientName
        self.currencyCode = currencyCode
        self.currencyExponent = currencyExponent
        self.note = note
        self.actorName = actorName
        self.createdAt = createdAt
        self.settlementId = settlementId
        self.minorUnits = minorUnits
        self.amount = amount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let type = try container.decode(String.self, forKey: .type)
        let payerName = try container.decodeIfPresent(String.self, forKey: .payerName)
        let recipientName = try container.decodeIfPresent(String.self, forKey: .recipientName)
        let note = try container.decodeIfPresent(String.self, forKey: .note)
        let actorName = try container.decodeIfPresent(String.self, forKey: .actorName)
        let createdAt = try container.decode(String.self, forKey: .createdAt)
        let settlementId = try container.decodeIfPresent(String.self, forKey: .settlementId)

        if let exact = try? container.decode(ServerLedgerMoneyDTO.self, forKey: .amount) {
            self.init(
                id: id,
                type: type,
                payerName: payerName,
                recipientName: recipientName,
                amount: SettlementMoneyFormatting.decimalString(
                    fromMinorUnits: exact.minorUnits,
                    exponent: exact.currencyExponent
                ),
                currencyCode: exact.currencyCode,
                currencyExponent: exact.currencyExponent,
                note: note,
                actorName: actorName,
                createdAt: createdAt,
                settlementId: settlementId,
                minorUnits: exact.minorUnits
            )
            return
        }

        self.init(
            id: id,
            type: type,
            payerName: payerName,
            recipientName: recipientName,
            amount: try container.decodeIfPresent(String.self, forKey: .amount),
            currencyCode: try container.decodeIfPresent(String.self, forKey: .currencyCode),
            currencyExponent: try container.decodeIfPresent(Int.self, forKey: .currencyExponent),
            note: note,
            actorName: actorName,
            createdAt: createdAt,
            settlementId: settlementId
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(payerName, forKey: .payerName)
        try container.encodeIfPresent(recipientName, forKey: .recipientName)
        if let amount, let currencyCode, let minorUnits {
            let exponent = currencyExponent ?? SettlementMoneyFormatting.inferredExponent(
                amount: amount,
                minorUnits: minorUnits
            )
            try container.encode(
                ServerLedgerMoneyDTO(
                    minorUnits: minorUnits,
                    currencyCode: currencyCode,
                    currencyExponent: exponent
                ),
                forKey: .amount
            )
        } else {
            try container.encodeIfPresent(amount, forKey: .amount)
        }
        try container.encodeIfPresent(currencyCode, forKey: .currencyCode)
        try container.encodeIfPresent(currencyExponent, forKey: .currencyExponent)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encodeIfPresent(actorName, forKey: .actorName)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(settlementId, forKey: .settlementId)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case payerName
        case recipientName
        case amount
        case currencyCode
        case currencyExponent
        case note
        case actorName
        case createdAt
        case settlementId
    }
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
    let operationId: String?

    init(
        expectedVersion: Int,
        planTransferId: String,
        payerParticipantId: String,
        recipientParticipantId: String,
        currencyCode: String,
        currencyExponent: Int,
        minorUnits: String,
        note: String?,
        operationId: String? = nil
    ) {
        self.expectedVersion = expectedVersion
        self.planTransferId = planTransferId
        self.payerParticipantId = payerParticipantId
        self.recipientParticipantId = recipientParticipantId
        self.currencyCode = currencyCode
        self.currencyExponent = currencyExponent
        self.minorUnits = minorUnits
        self.note = note
        self.operationId = operationId
    }
}

struct CreateReversalRequest: Codable {
    let expectedVersion: Int
    let operationId: String?

    init(expectedVersion: Int, operationId: String? = nil) {
        self.expectedVersion = expectedVersion
        self.operationId = operationId
    }
}

struct UpdateSettlementSettingsRequest: Codable {
    let expectedVersion: Int
    let simplifyDebts: Bool
    let operationId: String?

    init(expectedVersion: Int, simplifyDebts: Bool, operationId: String? = nil) {
        self.expectedVersion = expectedVersion
        self.simplifyDebts = simplifyDebts
        self.operationId = operationId
    }
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
    let minorUnits: String?

    init(expenseId: String, description: String, amount: String, minorUnits: String? = nil) {
        self.expenseId = expenseId
        self.description = description
        self.amount = amount
        self.minorUnits = minorUnits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.expenseId = try container.decode(String.self, forKey: .expenseId)
        self.description = try container.decode(String.self, forKey: .description)
        if let exact = try? container.decode(ServerLedgerMoneyDTO.self, forKey: .amount) {
            self.amount = SettlementMoneyFormatting.decimalString(
                fromMinorUnits: exact.minorUnits,
                exponent: exact.currencyExponent
            )
            self.minorUnits = exact.minorUnits
        } else {
            self.amount = try container.decode(String.self, forKey: .amount)
            self.minorUnits = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case expenseId
        case description
        case amount
    }
}

struct SettlementExplanationPathDTO: Decodable, Equatable, Identifiable {
    var id: String { path }
    let path: String
    let amount: String
    let minorUnits: String?

    init(path: String, amount: String, minorUnits: String? = nil) {
        self.path = path
        self.amount = amount
        self.minorUnits = minorUnits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try container.decode(String.self, forKey: .path)
        if let exact = try? container.decode(ServerLedgerMoneyDTO.self, forKey: .amount) {
            self.amount = SettlementMoneyFormatting.decimalString(
                fromMinorUnits: exact.minorUnits,
                exponent: exact.currencyExponent
            )
            self.minorUnits = exact.minorUnits
        } else {
            self.amount = try container.decode(String.self, forKey: .amount)
            self.minorUnits = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case amount
    }
}

struct SettlementExplanationAdjustmentDTO: Decodable, Equatable, Identifiable {
    var id: String { label }
    let label: String
    let amount: String
    let minorUnits: String?

    init(label: String, amount: String, minorUnits: String? = nil) {
        self.label = label
        self.amount = amount
        self.minorUnits = minorUnits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.label = try container.decode(String.self, forKey: .label)
        if let exact = try? container.decode(ServerLedgerMoneyDTO.self, forKey: .amount) {
            self.amount = SettlementMoneyFormatting.decimalString(
                fromMinorUnits: exact.minorUnits,
                exponent: exact.currencyExponent
            )
            self.minorUnits = exact.minorUnits
        } else {
            self.amount = try container.decode(String.self, forKey: .amount)
            self.minorUnits = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case label
        case amount
    }
}

struct SettlementTransferConfirmation: Equatable, Identifiable {
    let id: String
    let transfer: SettlementPlanTransferDTO
    let expectedVersion: Int
}

enum SettlementClientError: LocalizedError, Equatable {
    case offline
    case unauthorized
    case versionConflict
    case requiresReconfirmation
    case staleResponse
    case writeDisabled
    case explanationUnavailable

    var errorDescription: String? {
        switch self {
        case .offline: "Offline"
        case .unauthorized: "Your session expired. Please sign in again."
        case .versionConflict: "Settlement changed. Confirm again."
        case .requiresReconfirmation: "Settlement changed. Confirm again."
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

    static func decimalString(fromMinorUnits minorUnits: String, exponent: Int) -> String {
        let negative = minorUnits.hasPrefix("-")
        let digits = negative ? String(minorUnits.dropFirst()) : minorUnits
        let normalized = digits.isEmpty ? "0" : digits
        guard exponent > 0 else {
            return "\(negative && normalized != "0" ? "-" : "")\(normalized)"
        }
        let padded = String(repeating: "0", count: max(0, exponent + 1 - normalized.count)) + normalized
        let splitIndex = padded.index(padded.endIndex, offsetBy: -exponent)
        let whole = String(padded[..<splitIndex])
        let fraction = String(padded[splitIndex...])
        let sign = negative && normalized != "0" ? "-" : ""
        return "\(sign)\(whole).\(fraction)"
    }

    static func inferredExponent(amount: String, minorUnits: String) -> Int {
        let fractionCount = amount.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first?.count ?? 0
        if fractionCount > 0 { return fractionCount }
        return max(0, minorUnits.count - amount.count)
    }
}

extension String {
    func paddingMinorUnits(exponent: Int) -> String {
        guard exponent >= 0 else { return "0" }
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        let negative = trimmed.hasPrefix("-")
        let unsigned = negative || trimmed.hasPrefix("+") ? String(trimmed.dropFirst()) : trimmed
        let parts = unsigned.split(separator: ".", omittingEmptySubsequences: false)
        let whole = parts.first.map(String.init) ?? "0"
        let fraction = parts.count > 1 ? String(parts[1]) : ""
        guard whole.allSatisfy(\.isNumber), fraction.allSatisfy(\.isNumber) else { return "0" }
        let padded = fraction.padding(toLength: exponent, withPad: "0", startingAt: 0)
        let combined = whole + padded
        let normalized = combined.replacingOccurrences(of: "^0+", with: "", options: .regularExpression)
        guard normalized.isEmpty == false else { return "0" }
        return negative ? "-\(normalized)" : normalized
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
