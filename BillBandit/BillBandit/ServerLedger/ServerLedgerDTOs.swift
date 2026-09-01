import Foundation

enum ServerLedgerContract {
    static let version = 2
    static let clientValue = "ledger-v2"
    static let clientContractHeader = "Client-Contract"
    static let clientCompatibilityHeader = "Client-Compatibility"
    static let idempotencyHeader = "Idempotency-Key"
    static let expectedRevisionHeader = "Expected-Revision"
}

enum ServerLedgerDTOError: LocalizedError, Equatable, Sendable {
    case contractVersionMismatch(Int?)
    case invalidEnvelope
    case invalidScope
    case invalidMoney(path: String)
    case nonCanonicalMinorUnits(path: String)
    case numericMinorUnits(path: String)
    case unsupportedPayload

    var errorDescription: String? {
        switch self {
        case let .contractVersionMismatch(version):
            return "Unsupported ledger contract version \(version.map(String.init) ?? "missing")"
        case .invalidEnvelope: return "Invalid ledger read envelope"
        case .invalidScope: return "Invalid shared-ledger scope"
        case let .invalidMoney(path): return "Invalid exact money at \(path)"
        case let .nonCanonicalMinorUnits(path): return "Non-canonical minor units at \(path)"
        case let .numericMinorUnits(path): return "minorUnits must be a string at \(path)"
        case .unsupportedPayload: return "Unsupported ledger payload"
        }
    }
}

/// V2 exact money. The client deliberately retains minor units as a string;
/// converting it to a floating-point, decimal, or major-unit value would lose the
/// contract's exactness and can change signed values at large magnitudes.
struct ServerLedgerMoneyDTO: Codable, Equatable, Hashable, Sendable {
    let minorUnits: String
    let currencyCode: String
    let currencyExponent: Int

    init(minorUnits: String, currencyCode: String, currencyExponent: Int) {
        self.minorUnits = minorUnits
        self.currencyCode = currencyCode
        self.currencyExponent = currencyExponent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let minorUnits = try container.decode(String.self, forKey: .minorUnits)
        let currencyCode = try container.decode(String.self, forKey: .currencyCode)
        let currencyExponent = try container.decode(Int.self, forKey: .currencyExponent)
        try Self.validate(
            minorUnits: minorUnits,
            currencyCode: currencyCode,
            currencyExponent: currencyExponent
        )
        self.init(
            minorUnits: minorUnits,
            currencyCode: currencyCode,
            currencyExponent: currencyExponent
        )
    }

    func encode(to encoder: Encoder) throws {
        try Self.validate(
            minorUnits: minorUnits,
            currencyCode: currencyCode,
            currencyExponent: currencyExponent
        )
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(minorUnits, forKey: .minorUnits)
        try container.encode(currencyCode, forKey: .currencyCode)
        try container.encode(currencyExponent, forKey: .currencyExponent)
    }

    static func isCanonicalMinorUnits(_ value: String) -> Bool {
        value == "0" || value.range(of: #"^-?[1-9][0-9]*$"#, options: .regularExpression) != nil
    }

    static func validate(
        minorUnits: String,
        currencyCode: String,
        currencyExponent: Int
    ) throws {
        guard Self.isCanonicalMinorUnits(minorUnits) else {
            throw ServerLedgerDTOError.nonCanonicalMinorUnits(path: "minorUnits")
        }
        guard currencyCode.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil,
              (0...9).contains(currencyExponent) else {
            throw ServerLedgerDTOError.invalidMoney(path: "money")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case minorUnits
        case currencyCode
        case currencyExponent
    }
}

typealias LedgerMoneyDTO = ServerLedgerMoneyDTO
typealias ExactMoneyDTO = ServerLedgerMoneyDTO

enum ServerLedgerScopeKindDTO: String, Codable, Sendable {
    case shared
}

struct ServerLedgerScopeDTO: Codable, Equatable, Sendable {
    let kind: ServerLedgerScopeKindDTO
    let accountID: String
    let groupID: String
    let localOnly: Bool

    init(
        kind: ServerLedgerScopeKindDTO = .shared,
        accountID: String,
        groupID: String,
        localOnly: Bool = false
    ) {
        self.kind = kind
        self.accountID = accountID
        self.groupID = groupID
        self.localOnly = localOnly
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try container.decode(ServerLedgerScopeKindDTO.self, forKey: .kind),
            accountID: try container.decode(String.self, forKey: .accountID),
            groupID: try container.decode(String.self, forKey: .groupID),
            localOnly: try container.decode(Bool.self, forKey: .localOnly)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case accountID = "accountId"
        case groupID = "groupId"
        case localOnly
    }
}

struct ServerLedgerMigrationDTO: Codable, Equatable, Sendable {
    let status: String
    let source: String
    let migrationID: String?
    let importedAt: String?
    let dualWriteEnabled: Bool
    let recoveryReadOnly: Bool

    init(
        status: String,
        source: String,
        migrationID: String?,
        importedAt: String?,
        dualWriteEnabled: Bool,
        recoveryReadOnly: Bool
    ) {
        self.status = status
        self.source = source
        self.migrationID = migrationID
        self.importedAt = importedAt
        self.dualWriteEnabled = dualWriteEnabled
        self.recoveryReadOnly = recoveryReadOnly
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case source
        case migrationID = "migrationId"
        case importedAt
        case dualWriteEnabled
        case recoveryReadOnly
    }
}

struct ServerLedgerStaleStateDTO: Codable, Equatable, Sendable {
    let isStale: Bool
    let reason: String
    let observedAt: String
    let readRevision: Int64
    let serverRevision: Int64?
}

struct ServerLedgerAuthorityDTO: Codable, Equatable, Sendable {
    let serverAuthoritative: Bool
    let source: String
    let readModel: String
    let ledger: String
    let balances: String
    let settlementPlan: String
    let settlementHistory: String
    let identity: String
    let cacheRole: String
}

struct ServerLedgerPendingOperationDTO: Codable, Equatable, Sendable {
    let operationID: String
    let idempotencyKey: String
    let kind: String
    let expectedRevision: Int64
    let status: String
    let createdAt: String
    let requestHash: String

    private enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case idempotencyKey
        case kind
        case expectedRevision
        case status
        case createdAt
        case requestHash
    }
}

/// A lossless-enough JSON value used for the opaque portion of a server
/// snapshot. Money is decoded separately and validated before this value is
/// constructed by the transport.
enum ServerLedgerJSONValue: Codable, Equatable, Sendable {
    case object([String: ServerLedgerJSONValue])
    case array([ServerLedgerJSONValue])
    case string(String)
    case number(String)
    case boolean(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode([String: ServerLedgerJSONValue].self) {
            if let minorUnits = value["minorUnits"] {
                switch minorUnits {
                case let .string(string):
                    guard ServerLedgerMoneyDTO.isCanonicalMinorUnits(string) else {
                        throw ServerLedgerDTOError.nonCanonicalMinorUnits(path: "minorUnits")
                    }
                default:
                    throw ServerLedgerDTOError.numericMinorUnits(path: "minorUnits")
                }
            }
            self = .object(value)
        } else if let value = try? container.decode([ServerLedgerJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .number(String(value))
        } else if let value = try? container.decode(Decimal.self) {
            self = .number(NSDecimalNumber(decimal: value).stringValue)
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else {
            throw ServerLedgerDTOError.unsupportedPayload
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .boolean(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct ServerLedgerReadEnvelopeDTO: Codable, Equatable, Sendable {
    let contractVersion: Int
    let kind: String
    let scope: ServerLedgerScopeDTO
    let revision: Int64
    let readRevision: Int64
    let pendingOperationIDs: [String]
    let migration: ServerLedgerMigrationDTO
    let stale: ServerLedgerStaleStateDTO
    let authority: ServerLedgerAuthorityDTO
    let data: ServerLedgerJSONValue

    init(
        contractVersion: Int = ServerLedgerContract.version,
        kind: String = "read",
        scope: ServerLedgerScopeDTO,
        revision: Int64,
        readRevision: Int64,
        pendingOperationIDs: [String] = [],
        migration: ServerLedgerMigrationDTO,
        stale: ServerLedgerStaleStateDTO,
        authority: ServerLedgerAuthorityDTO,
        data: ServerLedgerJSONValue
    ) {
        self.contractVersion = contractVersion
        self.kind = kind
        self.scope = scope
        self.revision = revision
        self.readRevision = readRevision
        self.pendingOperationIDs = pendingOperationIDs
        self.migration = migration
        self.stale = stale
        self.authority = authority
        self.data = data
    }

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

struct ServerLedgerMutationResultDTO: Codable, Equatable, Sendable {
    let contractVersion: Int
    let kind: String
    let groupID: String
    let operationID: String
    let outcome: String
    let revision: Int64
    let readRevision: Int64
    let result: ServerLedgerMutationRecordDTO
    let idempotency: ServerLedgerIdempotencyDTO
    let authority: ServerLedgerAuthorityDTO

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case kind
        case groupID = "groupId"
        case operationID = "operationId"
        case outcome
        case revision
        case readRevision
        case result
        case idempotency
        case authority
    }
}

struct ServerLedgerMutationRecordDTO: Codable, Equatable, Sendable {
    let recordID: String
    let eventType: String

    private enum CodingKeys: String, CodingKey {
        case recordID = "recordId"
        case eventType
    }
}

struct ServerLedgerIdempotencyDTO: Codable, Equatable, Sendable {
    let key: String
    let requestHash: String
    let replayed: Bool?
    let resultRevision: Int64?
    let retainedUntil: String?
}

struct ServerLedgerConflictDTO: Codable, Equatable, Sendable {
    let code: String
    let expectedRevision: Int64?
    let currentRevision: Int64?
    let retryable: Bool
    let message: String?
    let serverAuthoritative: Bool?
}

struct ServerLedgerConflictEnvelopeDTO: Codable, Equatable, Sendable {
    let contractVersion: Int
    let kind: String
    let groupID: String
    let operationID: String
    let revision: Int64
    let readRevision: Int64
    let conflict: ServerLedgerConflictDTO
    let idempotency: ServerLedgerIdempotencyDTO?
    let snapshot: ServerLedgerReadEnvelopeDTO?
    let authority: ServerLedgerAuthorityDTO?

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case kind
        case groupID = "groupId"
        case operationID = "operationId"
        case revision
        case readRevision
        case conflict
        case idempotency
        case snapshot
        case authority
    }
}

/// Metadata persisted inside a queue payload when a mutation needs a route
/// or HTTP method in addition to its body. The outer queue record remains the
/// existing SwiftData model, so older rows stay readable and retryable.
struct ServerLedgerQueuedMutationEnvelope: Codable, Equatable, Sendable {
    static let marker = "server-ledger-queued-mutation-v2"

    let format: String
    let kind: String
    let method: String
    let path: String
    let body: Data

    init(kind: String, method: String = "POST", path: String, body: Data) {
        self.format = Self.marker
        self.kind = kind
        self.method = method
        self.path = path
        self.body = body
    }

    static func encode(kind: String, method: String = "POST", path: String, body: Data) throws -> Data {
        try JSONEncoder.serverLedger.encode(
            ServerLedgerQueuedMutationEnvelope(kind: kind, method: method, path: path, body: body)
        )
    }

    static func decode(_ data: Data) -> ServerLedgerQueuedMutationEnvelope? {
        guard let envelope = try? JSONDecoder.serverLedger.decode(Self.self, from: data),
              envelope.format == Self.marker else { return nil }
        return envelope
    }
}

extension JSONDecoder {
    static let serverLedger: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        return decoder
    }()
}

extension JSONEncoder {
    static let serverLedger: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .useDefaultKeys
        return encoder
    }()
}

enum ServerLedgerDocumentValidator {
    static func validateV2Document(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServerLedgerDTOError.invalidEnvelope
        }
        let version = integerValue(object["contractVersion"])
        guard version == Int64(ServerLedgerContract.version) else {
            throw ServerLedgerDTOError.contractVersionMismatch(version.map(Int.init))
        }
        try validateExactMoney(in: object, path: "$")
    }

    static func validateExactMoney(in value: Any, path: String) throws {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                let childPath = "\(path).\(key)"
                if key == "minorUnits" {
                    guard let string = child as? String else {
                        throw ServerLedgerDTOError.numericMinorUnits(path: childPath)
                    }
                    guard ServerLedgerMoneyDTO.isCanonicalMinorUnits(string) else {
                        throw ServerLedgerDTOError.nonCanonicalMinorUnits(path: childPath)
                    }
                    guard let currencyCode = object["currencyCode"] as? String,
                          currencyCode.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil,
                          let currencyExponent = integerValue(object["currencyExponent"]),
                          (0...9).contains(currencyExponent) else {
                        throw ServerLedgerDTOError.invalidMoney(path: path)
                    }
                }
                try validateExactMoney(in: child, path: childPath)
            }
            return
        }
        if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                try validateExactMoney(in: child, path: "\(path)[\(index)]")
            }
        }
    }

    static func snapshot(
        from data: Data,
        scope: ServerBackedLedgerScope,
        fallbackRevision: Int64? = nil
    ) throws -> ServerLedgerSnapshot {
        try validateV2Document(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServerLedgerDTOError.invalidEnvelope
        }

        if let scopeObject = object["scope"] as? [String: Any] {
            guard scopeObject["kind"] as? String == "shared",
                  scopeObject["localOnly"] as? Bool == false else {
                throw ServerLedgerDTOError.invalidScope
            }
        }
        let envelope = (try? JSONDecoder.serverLedger.decode(ServerLedgerReadEnvelopeDTO.self, from: data))
        if let envelope {
            guard envelope.scope.kind == .shared, envelope.scope.localOnly == false else {
                throw ServerLedgerDTOError.invalidScope
            }
        }
        let decodedAccountID = envelope?.scope.accountID ?? stringValue(object["accountId"])
        let decodedGroupID = envelope?.scope.groupID ?? stringValue(object["groupId"])
        let accountID = decodedAccountID ?? scope.accountID
        let groupID = decodedGroupID ?? scope.groupID
        guard accountID == scope.accountID, groupID == scope.groupID else {
            throw ServerLedgerAPIClientError.snapshotScopeMismatch
        }

        let revision = envelope?.revision
            ?? integerValue(object["revision"])
            ?? fallbackRevision
            ?? 0
        let money = firstMoney(in: object)
        return ServerLedgerSnapshot(
            accountID: accountID,
            groupID: groupID,
            revision: revision,
            payload: data,
            fetchedAt: .now,
            money: money.map {
                ServerLedgerMoney(
                    currencyCode: $0.currencyCode,
                    currencyExponent: $0.currencyExponent,
                    minorUnits: $0.minorUnits
                )
            }
        )
    }

    private static func firstMoney(in value: Any) -> ServerLedgerMoneyDTO? {
        if let object = value as? [String: Any] {
            if let minorUnits = object["minorUnits"] as? String,
               let currencyCode = object["currencyCode"] as? String,
               let currencyExponent = integerValue(object["currencyExponent"]) {
                return ServerLedgerMoneyDTO(
                    minorUnits: minorUnits,
                    currencyCode: currencyCode,
                    currencyExponent: Int(currencyExponent)
                )
            }
            for child in object.values {
                if let result = firstMoney(in: child) { return result }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let result = firstMoney(in: child) { return result }
            }
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private static func integerValue(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber else { return nil }
        return Int64(number.stringValue)
    }
}
