import Foundation

actor MockSettlementAPI {
    static let shared = MockSettlementAPI()

    private var versions: [String: Int] = [:]

    func requestData(path: String, method: String, body: Data?, hasToken: Bool) async throws -> Data {
        guard hasToken else { throw SettlementAPIError.unauthorized }

        let value: Encodable
        switch (method, path) {
        case ("GET", let settlePath) where settlePath.hasPrefix("/api/groups/") && settlePath.hasSuffix("/settle-up"):
            let groupId = pathComponents(settlePath).dropLast().last ?? ""
            let afterVersion = queryValue(named: "afterVersion", in: settlePath).flatMap(Int.init)
            value = try snapshot(groupId: groupId, afterVersion: afterVersion)
        case ("GET", let historyPath) where historyPath.contains("/settle-up/history"):
            let groupId = pathComponents(historyPath).first(where: { $0.hasPrefix("group-") }) ?? "group-nyc"
            value = try history(groupId: groupId)
        case ("POST", let settlementPath) where settlementPath.hasSuffix("/settlements"):
            let groupId = pathComponents(settlementPath).dropLast().last ?? ""
            let request = try decode(CreateSettlementRequest.self, from: body)
            value = try postSettlement(groupId: groupId, request: request)
        case ("POST", let reversalPath) where reversalPath.contains("/settlements/") && reversalPath.hasSuffix("/reversals"):
            let parts = pathComponents(reversalPath)
            let groupId = parts.dropLast(2).last ?? ""
            let request = try decode(CreateReversalRequest.self, from: body)
            value = try postReversal(groupId: groupId, request: request)
        case ("PATCH", let settingsPath) where settingsPath.hasSuffix("/settlement-settings"):
            let groupId = pathComponents(settingsPath).dropLast().last ?? ""
            let request = try decode(UpdateSettlementSettingsRequest.self, from: body)
            value = try patchSettings(groupId: groupId, request: request)
        default:
            throw SettlementAPIError.server("Unhandled mock route \(method) \(path)")
        }
        return try JSONEncoder.settlement.encode(value)
    }

    private func snapshot(groupId: String, afterVersion: Int?) throws -> SettlementSnapshotDTO {
        let version = versions[groupId, default: 3]
        if let afterVersion, afterVersion == version {
            return baseSnapshot(groupId: groupId, mode: "no_change", version: version, plan: [])
        }
        return baseSnapshot(groupId: groupId, mode: "snapshot", version: version, plan: samplePlan())
    }

    private func history(groupId: String) throws -> SettlementSettledPageDTO {
        _ = groupId
        return SettlementSettledPageDTO(items: [], nextCursor: nil)
    }

    private func postSettlement(groupId: String, request: CreateSettlementRequest) throws -> SettlementMutationResponseDTO {
        guard request.expectedVersion == versions[groupId, default: 3] else {
            throw SettlementAPIError.structured(code: "SETTLEMENT_VERSION_CONFLICT", status: 409, body: nil)
        }
        versions[groupId] = request.expectedVersion + 1
        let state = try snapshot(groupId: groupId, afterVersion: nil)
        return SettlementMutationResponseDTO(
            result: SettlementMutationResultDTO(version: state.version, recordId: "record-mock", eventType: "settlement.created"),
            state: state
        )
    }

    private func postReversal(groupId: String, request: CreateReversalRequest) throws -> SettlementMutationResponseDTO {
        guard request.expectedVersion == versions[groupId, default: 3] else {
            throw SettlementClientError.versionConflict
        }
        versions[groupId] = request.expectedVersion + 1
        let state = try snapshot(groupId: groupId, afterVersion: nil)
        return SettlementMutationResponseDTO(
            result: SettlementMutationResultDTO(version: state.version, recordId: "reversal-mock", eventType: "settlement.reversed"),
            state: state
        )
    }

    private func patchSettings(groupId: String, request: UpdateSettlementSettingsRequest) throws -> SettlementMutationResponseDTO {
        guard request.expectedVersion == versions[groupId, default: 3] else {
            throw SettlementClientError.versionConflict
        }
        versions[groupId] = request.expectedVersion + 1
        let state = try snapshot(groupId: groupId, afterVersion: nil)
        return SettlementMutationResponseDTO(
            result: SettlementMutationResultDTO(version: state.version, recordId: "setting-mock", eventType: "setting.changed"),
            state: state
        )
    }

    private func baseSnapshot(
        groupId: String,
        mode: String,
        version: Int,
        plan: [SettlementPlanTransferDTO]
    ) -> SettlementSnapshotDTO {
        _ = groupId
        return SettlementSnapshotDTO(
            mode: mode,
            version: version,
            lifecycle: SettlementLifecycleDTO(isArchived: false, isFinalized: false),
            simplifyDebts: true,
            latestSettingAudit: nil,
            settlementCompletedAt: plan.isEmpty ? "2026-01-15T10:00:00.000Z" : nil,
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
            plan: plan,
            settled: SettlementSettledPageDTO(items: [], nextCursor: nil),
            reason: nil,
            fromVersion: nil,
            toVersion: nil,
            envelopes: nil
        )
    }

    private func samplePlan() -> [SettlementPlanTransferDTO] {
        [
            SettlementPlanTransferDTO(
                planTransferId: "transfer-1",
                payerParticipantId: "participant-user-alice",
                recipientParticipantId: "participant-user-bob",
                payerName: "You",
                recipientName: "Bob Smith",
                amount: "25.00",
                currencyCode: "INR",
                currencyExponent: 2,
                mode: "simplified"
            ),
        ]
    }

    private func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    private func queryValue(named name: String, in path: String) -> String? {
        guard let query = path.split(separator: "?", maxSplits: 1).dropFirst().first else { return nil }
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.first == name { return parts.count > 1 ? parts[1] : "" }
        }
        return nil
    }

    private func decode<T: Decodable>(_ type: T.Type, from body: Data?) throws -> T {
        guard let body else { throw SettlementAPIError.invalidResponse }
        return try JSONDecoder.settlement.decode(T.self, from: body)
    }
}
