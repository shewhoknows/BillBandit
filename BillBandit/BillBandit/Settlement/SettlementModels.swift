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
    /// The revision represented by the canonical read payload. `version` is
    /// retained as the compatibility name used by the existing Settle Up UI.
    let readRevision: Int64
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

    init(
        mode: String,
        version: Int,
        lifecycle: SettlementLifecycleDTO,
        simplifyDebts: Bool,
        latestSettingAudit: SettlementSettingAuditDTO?,
        settlementCompletedAt: String?,
        permissions: SettlementPermissionsDTO,
        realtime: SettlementRealtimeDTO,
        plan: [SettlementPlanTransferDTO],
        settled: SettlementSettledPageDTO,
        reason: String?,
        fromVersion: Int?,
        toVersion: Int?,
        envelopes: [SettlementVersionEnvelopeDTO]?,
        readRevision: Int64? = nil
    ) {
        self.mode = mode
        self.version = version
        self.readRevision = readRevision ?? Int64(version)
        self.lifecycle = lifecycle
        self.simplifyDebts = simplifyDebts
        self.latestSettingAudit = latestSettingAudit
        self.settlementCompletedAt = settlementCompletedAt
        self.permissions = permissions
        self.realtime = realtime
        self.plan = plan
        self.settled = settled
        self.reason = reason
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.envelopes = envelopes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mode: try container.decode(String.self, forKey: .mode),
            version: try container.decode(Int.self, forKey: .version),
            lifecycle: try container.decode(SettlementLifecycleDTO.self, forKey: .lifecycle),
            simplifyDebts: try container.decode(Bool.self, forKey: .simplifyDebts),
            latestSettingAudit: try container.decodeIfPresent(SettlementSettingAuditDTO.self, forKey: .latestSettingAudit),
            settlementCompletedAt: try container.decodeIfPresent(String.self, forKey: .settlementCompletedAt),
            permissions: try container.decode(SettlementPermissionsDTO.self, forKey: .permissions),
            realtime: try container.decode(SettlementRealtimeDTO.self, forKey: .realtime),
            plan: try container.decode([SettlementPlanTransferDTO].self, forKey: .plan),
            settled: try container.decode(SettlementSettledPageDTO.self, forKey: .settled),
            reason: try container.decodeIfPresent(String.self, forKey: .reason),
            fromVersion: try container.decodeIfPresent(Int.self, forKey: .fromVersion),
            toVersion: try container.decodeIfPresent(Int.self, forKey: .toVersion),
            envelopes: try container.decodeIfPresent([SettlementVersionEnvelopeDTO].self, forKey: .envelopes),
            readRevision: try container.decodeIfPresent(Int64.self, forKey: .readRevision)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case version
        case readRevision
        case lifecycle
        case simplifyDebts
        case latestSettingAudit
        case settlementCompletedAt
        case permissions
        case realtime
        case plan
        case settled
        case reason
        case fromVersion
        case toVersion
        case envelopes
    }

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
            envelopes: envelopes,
            readRevision: readRevision
        )
    }
}

// MARK: - Canonical ledger read model

/// The T-12 transport keeps the response payload opaque so the cache can be
/// upgraded independently. Settlement and invoice surfaces decode only this
/// checked-in ledger-v2 projection; they never reconstruct a shared balance
/// from SwiftData entities.
struct SettlementCanonicalLedgerReadEnvelope: Decodable, Equatable, Sendable {
    let contractVersion: Int
    let kind: String
    let scope: ServerLedgerScopeDTO
    let revision: Int64
    let readRevision: Int64
    let pendingOperationIDs: [String]
    let migration: ServerLedgerMigrationDTO
    let stale: ServerLedgerStaleStateDTO
    let authority: ServerLedgerAuthorityDTO
    let data: SettlementCanonicalLedgerData

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case kind
        case scope
        case revision
        case readRevision
        case pendingOperationIDs = "pendingOperationIds"
        case migration
        case stale
        case authority
        case data
    }
}

struct SettlementCanonicalLedgerData: Decodable, Equatable, Sendable {
    let group: SettlementCanonicalLedgerGroup
}

struct SettlementCanonicalCurrencyDescriptor: Codable, Equatable, Sendable {
    let currencyCode: String
    let currencyExponent: Int
}

struct SettlementCanonicalLedgerMember: Decodable, Equatable, Sendable {
    let memberID: String
    let accountID: String
    let localIdentityID: String?
    let displayName: String
    let email: String?
    let role: String
    let status: String

    private enum CodingKeys: String, CodingKey {
        case memberID = "memberId"
        case accountID = "accountId"
        case localIdentityID = "localIdentityId"
        case displayName
        case email
        case role
        case status
    }
}

struct SettlementCanonicalLedgerSplit: Decodable, Equatable, Sendable {
    let splitID: String
    let memberID: String
    let amount: ServerLedgerMoneyDTO
    let percentage: String?
    let shares: Int?

    private enum CodingKeys: String, CodingKey {
        case splitID = "splitId"
        case memberID = "memberId"
        case amount
        case percentage
        case shares
    }
}

struct SettlementCanonicalLedgerExpense: Decodable, Equatable, Sendable {
    let expenseID: String
    let description: String
    let paidByMemberID: String
    let amount: ServerLedgerMoneyDTO
    let splitMethod: String
    let splits: [SettlementCanonicalLedgerSplit]
    let status: String
    let createdAt: String
    let updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case expenseID = "expenseId"
        case description
        case paidByMemberID = "paidByMemberId"
        case amount
        case splitMethod
        case splits
        case status
        case createdAt
        case updatedAt
    }
}

struct SettlementCanonicalMemberBalance: Decodable, Equatable, Sendable {
    let memberID: String
    let byCurrency: [ServerLedgerMoneyDTO]

    private enum CodingKeys: String, CodingKey {
        case memberID = "memberId"
        case byCurrency
    }
}

struct SettlementCanonicalCurrencyBalance: Decodable, Equatable, Sendable {
    let currency: SettlementCanonicalCurrencyDescriptor
    let totalPositive: ServerLedgerMoneyDTO
    let totalNegative: ServerLedgerMoneyDTO
    let net: ServerLedgerMoneyDTO
}

struct SettlementCanonicalCurrentAccountBalance: Decodable, Equatable, Sendable {
    let accountID: String
    let memberID: String
    let byCurrency: [ServerLedgerMoneyDTO]

    private enum CodingKeys: String, CodingKey {
        case accountID = "accountId"
        case memberID = "memberId"
        case byCurrency
    }
}

struct SettlementCanonicalBalances: Decodable, Equatable, Sendable {
    let byMember: [SettlementCanonicalMemberBalance]
    let byCurrency: [SettlementCanonicalCurrencyBalance]
    let currentAccount: SettlementCanonicalCurrentAccountBalance
}

struct SettlementCanonicalSettlementTransfer: Decodable, Equatable, Sendable {
    let planTransferID: String
    let payerMemberID: String
    let recipientMemberID: String
    let amount: ServerLedgerMoneyDTO
    let mode: String
    let obligationComponentIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case planTransferID = "planTransferId"
        case payerMemberID = "payerMemberId"
        case recipientMemberID = "recipientMemberId"
        case amount
        case mode
        case obligationComponentIDs = "obligationComponentIds"
    }
}

struct SettlementCanonicalSettlementPlan: Decodable, Equatable, Sendable {
    let revision: Int
    let mode: String
    let transfers: [SettlementCanonicalSettlementTransfer]
}

struct SettlementCanonicalSettlementHistoryItem: Decodable, Equatable, Sendable {
    let type: String
    let settlementID: String?
    let reversalID: String?
    let payerMemberID: String?
    let recipientMemberID: String?
    let amount: ServerLedgerMoneyDTO
    let status: String?
    let actorMemberID: String
    let createdAt: String

    private enum CodingKeys: String, CodingKey {
        case type
        case settlementID = "settlementId"
        case reversalID = "reversalId"
        case payerMemberID = "payerMemberId"
        case recipientMemberID = "recipientMemberId"
        case amount
        case status
        case actorMemberID = "actorMemberId"
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        settlementID = try container.decodeIfPresent(String.self, forKey: .settlementID)
        reversalID = try container.decodeIfPresent(String.self, forKey: .reversalID)
        payerMemberID = try container.decodeIfPresent(String.self, forKey: .payerMemberID)
        recipientMemberID = try container.decodeIfPresent(String.self, forKey: .recipientMemberID)
        amount = try container.decode(ServerLedgerMoneyDTO.self, forKey: .amount)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        actorMemberID = try container.decode(String.self, forKey: .actorMemberID)
        createdAt = try container.decode(String.self, forKey: .createdAt)
    }
}

struct SettlementCanonicalLedgerActivity: Decodable, Equatable, Sendable {
    let activityID: String
    let type: String
    let expenseID: String?
    let settlementID: String?
    let reversalID: String?
    let amount: ServerLedgerMoneyDTO
    let at: String

    private enum CodingKeys: String, CodingKey {
        case activityID = "activityId"
        case type
        case expenseID = "expenseId"
        case settlementID = "settlementId"
        case reversalID = "reversalId"
        case amount
        case at
    }
}

struct SettlementCanonicalLedgerGroup: Decodable, Equatable, Sendable {
    let groupID: String
    let accountID: String
    let name: String
    let baseCurrency: SettlementCanonicalCurrencyDescriptor
    let scope: String
    let localOnly: Bool
    let revision: Int
    let readRevision: Int
    let members: [SettlementCanonicalLedgerMember]
    let expenses: [SettlementCanonicalLedgerExpense]
    let balances: SettlementCanonicalBalances
    let settlementPlan: SettlementCanonicalSettlementPlan
    let settlementHistory: [SettlementCanonicalSettlementHistoryItem]
    let activity: [SettlementCanonicalLedgerActivity]
    let pendingOperationIDs: [String]
    let migration: ServerLedgerMigrationDTO
    let stale: ServerLedgerStaleStateDTO
    let authority: ServerLedgerAuthorityDTO

    private enum CodingKeys: String, CodingKey {
        case groupID = "groupId"
        case accountID = "accountId"
        case name
        case baseCurrency
        case scope
        case localOnly
        case revision
        case readRevision
        case members
        case expenses
        case balances
        case settlementPlan
        case settlementHistory
        case activity
        case pendingOperationIDs = "pendingOperationIds"
        case migration
        case stale
        case authority
    }
}

struct SettlementCanonicalLedgerSnapshot: Equatable, Sendable {
    let envelope: SettlementCanonicalLedgerReadEnvelope

    var group: SettlementCanonicalLedgerGroup { envelope.data.group }
    var scope: ServerBackedLedgerScope {
        ServerBackedLedgerScope(accountID: group.accountID, groupID: group.groupID)
    }
    var revision: Int64 { envelope.revision }
    var readRevision: Int64 { envelope.readRevision }
    var isStale: Bool { envelope.stale.isStale || group.stale.isStale }
    var migrationStatus: String { envelope.migration.status }
}

struct SettlementLedgerExpense: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let amount: ServerLedgerMoneyDTO
    let payerMemberID: String
    let payerName: String
    let splitCount: Int
    let date: String
}

struct SettlementLedgerBalanceLine: Equatable, Identifiable, Sendable {
    let id: String
    let memberID: String
    let memberName: String
    let amount: ServerLedgerMoneyDTO
}

extension SettlementCanonicalLedgerGroup {
    var memberByID: [String: SettlementCanonicalLedgerMember] {
        Dictionary(uniqueKeysWithValues: members.map { ($0.memberID, $0) })
    }

    var currentMemberID: String? {
        members.first(where: { $0.accountID == accountID })?.memberID
    }

    var isMigrationReady: Bool {
        migration.status == "complete" || migration.status == "not_required"
    }

    func baseCurrencyMoney(from values: [ServerLedgerMoneyDTO]) -> ServerLedgerMoneyDTO {
        values.first(where: {
            $0.currencyCode == baseCurrency.currencyCode
                && $0.currencyExponent == baseCurrency.currencyExponent
        }) ?? ServerLedgerMoneyDTO(
            minorUnits: "0",
            currencyCode: baseCurrency.currencyCode,
            currencyExponent: baseCurrency.currencyExponent
        )
    }

    func invoiceExpenses() -> [SettlementLedgerExpense] {
        let memberByID = memberByID
        return expenses
            .filter { $0.status == "active" }
            .sorted { $0.createdAt > $1.createdAt }
            .map {
                SettlementLedgerExpense(
                    id: $0.expenseID,
                    title: $0.description,
                    amount: $0.amount,
                    payerMemberID: $0.paidByMemberID,
                    payerName: memberByID[$0.paidByMemberID]?.displayName ?? "Unknown",
                    splitCount: $0.splits.count,
                    date: $0.createdAt
                )
            }
    }

    func uiPlan() -> [SettlementPlanTransferDTO] {
        let memberByID = memberByID
        return settlementPlan.transfers.map { transfer in
            SettlementPlanTransferDTO(
                planTransferId: transfer.planTransferID,
                payerParticipantId: transfer.payerMemberID,
                recipientParticipantId: transfer.recipientMemberID,
                payerName: memberByID[transfer.payerMemberID]?.displayName ?? "Unknown member",
                recipientName: memberByID[transfer.recipientMemberID]?.displayName ?? "Unknown member",
                amount: SettlementMoneyFormatting.decimalString(
                    fromMinorUnits: transfer.amount.minorUnits,
                    exponent: transfer.amount.currencyExponent
                ),
                currencyCode: transfer.amount.currencyCode,
                currencyExponent: transfer.amount.currencyExponent,
                mode: transfer.mode,
                minorUnits: transfer.amount.minorUnits
            )
        }
    }

    func uiHistory() -> [SettlementHistoryItemDTO] {
        let memberByID = memberByID
        return settlementHistory.map { item in
            let id = item.type == "reversal"
                ? (item.reversalID ?? item.settlementID ?? "reversal-\(item.createdAt)")
                : (item.settlementID ?? "settlement-\(item.createdAt)")
            return SettlementHistoryItemDTO(
                id: id,
                type: item.type,
                payerName: item.payerMemberID.flatMap { memberByID[$0]?.displayName },
                recipientName: item.recipientMemberID.flatMap { memberByID[$0]?.displayName },
                amount: SettlementMoneyFormatting.decimalString(
                    fromMinorUnits: item.amount.minorUnits,
                    exponent: item.amount.currencyExponent
                ),
                currencyCode: item.amount.currencyCode,
                currencyExponent: item.amount.currencyExponent,
                note: nil,
                actorName: memberByID[item.actorMemberID]?.displayName,
                createdAt: item.createdAt,
                settlementId: item.settlementID,
                minorUnits: item.amount.minorUnits
            )
        }
    }

    func uiSnapshot(realtimeAvailable: Bool) -> SettlementSnapshotDTO {
        let migrationReady = isMigrationReady
        let currentMember = currentMemberID.flatMap { memberByID[$0] }
        let canRead = scope == "shared" && localOnly == false && authority.serverAuthoritative
        let canMutate = canRead && migrationReady && !stale.isStale && currentMember?.status == "active"
        let permissions = SettlementPermissionsDTO(
            canReadPlan: canRead,
            canReadHistory: canRead,
            canSettleOrReverse: canMutate,
            canChangeSetting: false,
            canAuthorizeRealtime: realtimeAvailable,
            readScope: "full",
            callerParticipantId: currentMemberID
        )
        let reason = stale.isStale ? stale.reason : (migrationReady ? nil : "MIGRATION_\(migration.status.uppercased())")
        return SettlementSnapshotDTO(
            mode: "snapshot",
            version: revision,
            lifecycle: SettlementLifecycleDTO(isArchived: false, isFinalized: false),
            simplifyDebts: settlementPlan.mode.uppercased() == "SIMPLIFIED",
            latestSettingAudit: nil,
            settlementCompletedAt: nil,
            permissions: permissions,
            realtime: SettlementRealtimeDTO(available: realtimeAvailable),
            plan: uiPlan(),
            settled: SettlementSettledPageDTO(items: uiHistory(), nextCursor: nil),
            reason: reason,
            fromVersion: nil,
            toVersion: nil,
            envelopes: nil,
            readRevision: Int64(readRevision)
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

    /// Exact signed minor-unit arithmetic used for projecting canonical
    /// balances into invoice labels. Values remain decimal strings from the
    /// transport boundary through the final display string.
    static func add(_ lhs: String, _ rhs: String) -> String {
        let left = normalizedSigned(lhs)
        let right = normalizedSigned(rhs)
        if left.negative == right.negative {
            return signedString(
                negative: left.negative,
                digits: addMagnitudes(left.digits, right.digits)
            )
        }
        let comparison = compareMagnitudes(left.digits, right.digits)
        if comparison == 0 { return "0" }
        if comparison > 0 {
            return signedString(
                negative: left.negative,
                digits: subtractMagnitudes(left.digits, right.digits)
            )
        }
        return signedString(
            negative: right.negative,
            digits: subtractMagnitudes(right.digits, left.digits)
        )
    }

    static func subtract(_ lhs: String, _ rhs: String) -> String {
        add(lhs, negated(rhs))
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = normalizedSigned(lhs)
        let right = normalizedSigned(rhs)
        if left.negative != right.negative {
            return left.negative ? .orderedAscending : .orderedDescending
        }
        let magnitude = compareMagnitudes(left.digits, right.digits)
        if magnitude == 0 { return .orderedSame }
        if left.negative {
            return magnitude > 0 ? .orderedAscending : .orderedDescending
        }
        return magnitude > 0 ? .orderedDescending : .orderedAscending
    }

    static func isNegative(_ value: String) -> Bool {
        normalizedSigned(value).negative
    }

    static func isZero(_ value: String) -> Bool {
        normalizedSigned(value).digits == "0"
    }

    static func display(minorUnits: String, currencyCode: String, currencyExponent: Int) -> String {
        let amount = decimalString(fromMinorUnits: minorUnits, exponent: currencyExponent)
        let symbol = currencySymbol(for: currencyCode)
        if symbol == currencyCode.uppercased() {
            return "\(symbol) \(amount)"
        }
        if amount.hasPrefix("-") {
            return "-\(symbol)\(amount.dropFirst())"
        }
        return "\(symbol)\(amount)"
    }

    private static func currencySymbol(for currencyCode: String) -> String {
        switch currencyCode.uppercased() {
        case "INR": return "₹"
        case "USD": return "$"
        case "EUR": return "€"
        case "GBP": return "£"
        case "JPY": return "¥"
        case "KWD": return "KD "
        default: return currencyCode.uppercased()
        }
    }

    private static func normalizedSigned(_ value: String) -> (negative: Bool, digits: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let negative = trimmed.hasPrefix("-")
        let unsigned = (negative || trimmed.hasPrefix("+"))
            ? String(trimmed.dropFirst())
            : trimmed
        let digits = unsigned.isEmpty ? "0" : unsigned
        let normalized = digits.drop(while: { $0 == "0" })
        let canonical = normalized.isEmpty ? "0" : String(normalized)
        return (canonical == "0" ? false : negative, canonical)
    }

    private static func negated(_ value: String) -> String {
        let normalized = normalizedSigned(value)
        return normalized.digits == "0"
            ? "0"
            : (normalized.negative ? normalized.digits : "-\(normalized.digits)")
    }

    private static func signedString(negative: Bool, digits: String) -> String {
        let normalized = normalizedSigned(digits).digits
        return normalized == "0" ? "0" : (negative ? "-\(normalized)" : normalized)
    }

    private static func compareMagnitudes(_ lhs: String, _ rhs: String) -> Int {
        if lhs.count != rhs.count { return lhs.count > rhs.count ? 1 : -1 }
        if lhs == rhs { return 0 }
        return lhs > rhs ? 1 : -1
    }

    private static func addMagnitudes(_ lhs: String, _ rhs: String) -> String {
        let left = Array(lhs.utf8.reversed())
        let right = Array(rhs.utf8.reversed())
        let count = max(left.count, right.count)
        var result: [UInt8] = []
        result.reserveCapacity(count + 1)
        var carry: UInt8 = 0
        for index in 0..<count {
            let a = index < left.count ? left[index] - 48 : 0
            let b = index < right.count ? right[index] - 48 : 0
            let sum = a + b + carry
            result.append((sum % 10) + 48)
            carry = sum / 10
        }
        if carry > 0 { result.append(carry + 48) }
        return String(decoding: result.reversed(), as: UTF8.self)
    }

    private static func subtractMagnitudes(_ lhs: String, _ rhs: String) -> String {
        let left = Array(lhs.utf8.reversed())
        let right = Array(rhs.utf8.reversed())
        var result: [UInt8] = []
        result.reserveCapacity(left.count)
        var borrow: UInt8 = 0
        for index in 0..<left.count {
            var digit = left[index] - 48
            let subtrahend = (index < right.count ? right[index] - 48 : 0) + borrow
            if digit < subtrahend {
                digit += 10
                borrow = 1
            } else {
                borrow = 0
            }
            result.append(digit - subtrahend + 48)
        }
        while result.count > 1, result.last == 48 { result.removeLast() }
        return String(decoding: result.reversed(), as: UTF8.self)
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
