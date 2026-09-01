import Foundation

/// The storage and authority boundary for a ledger.
///
/// A local-only ledger deliberately has no server group identifier. That
/// absence is part of the type's contract: server mutations can only be
/// created from `ServerLedgerMutationScope`, which has no local-only case.
enum LedgerScope: Codable, Equatable, Hashable, Sendable {
    case serverBacked(accountID: String, groupID: String)
    case pendingServer(accountID: String, localGroupID: UUID)
    case localOnly(accountID: String, localGroupID: UUID)

    var kind: LedgerScopeKind {
        switch self {
        case .serverBacked: return .serverBacked
        case .pendingServer: return .pendingServer
        case .localOnly: return .localOnly
        }
    }

    var accountID: String {
        switch self {
        case let .serverBacked(accountID, _),
             let .pendingServer(accountID, _),
             let .localOnly(accountID, _):
            return accountID
        }
    }

    var serverGroupID: String? {
        guard case let .serverBacked(_, groupID) = self else { return nil }
        return groupID
    }

    var localGroupID: UUID? {
        switch self {
        case .serverBacked: return nil
        case let .pendingServer(_, localGroupID), let .localOnly(_, localGroupID):
            return localGroupID
        }
    }

    var isLocalOnly: Bool {
        if case .localOnly = self { return true }
        return false
    }

    /// A pending server group may enqueue a create operation, but it cannot
    /// yet participate in server-derived settlement until it has a server ID.
    var canEnterSharedSettlement: Bool {
        if case .serverBacked = self { return true }
        return false
    }

    /// The only bridge from an arbitrary ledger scope to a server mutation.
    /// There is intentionally no `.localOnly` representation in the result.
    var serverMutationScope: ServerLedgerMutationScope? {
        switch self {
        case let .serverBacked(accountID, groupID):
            return .serverBacked(accountID: accountID, groupID: groupID)
        case let .pendingServer(accountID, localGroupID):
            return .pendingServer(accountID: accountID, localGroupID: localGroupID)
        case .localOnly:
            return nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case accountID
        case groupID
        case localGroupID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(LedgerScopeKind.self, forKey: .kind)
        let accountID = try container.decode(String.self, forKey: .accountID)

        switch kind {
        case .serverBacked:
            self = .serverBacked(
                accountID: accountID,
                groupID: try container.decode(String.self, forKey: .groupID)
            )
        case .pendingServer:
            self = .pendingServer(
                accountID: accountID,
                localGroupID: try container.decode(UUID.self, forKey: .localGroupID)
            )
        case .localOnly:
            self = .localOnly(
                accountID: accountID,
                localGroupID: try container.decode(UUID.self, forKey: .localGroupID)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(accountID, forKey: .accountID)

        switch self {
        case let .serverBacked(_, groupID):
            try container.encode(groupID, forKey: .groupID)
        case let .pendingServer(_, localGroupID), let .localOnly(_, localGroupID):
            try container.encode(localGroupID, forKey: .localGroupID)
        }
    }
}

enum LedgerScopeKind: String, Codable, CaseIterable, Sendable {
    case serverBacked
    case pendingServer
    case localOnly
}

/// A scope that already has a server group identifier.
struct ServerBackedLedgerScope: Codable, Equatable, Hashable, Sendable {
    let accountID: String
    let groupID: String

    init(accountID: String, groupID: String) {
        self.accountID = accountID
        self.groupID = groupID
    }

    init(_ scope: LedgerScope) throws {
        guard case let .serverBacked(accountID, groupID) = scope else {
            throw LedgerScopeError.requiresServerBackedScope
        }
        self.init(accountID: accountID, groupID: groupID)
    }

    var ledgerScope: LedgerScope {
        .serverBacked(accountID: accountID, groupID: groupID)
    }
}

/// A locally-created group that is intended for the server but has not been
/// assigned a canonical server group ID yet.
struct PendingServerLedgerScope: Codable, Equatable, Hashable, Sendable {
    let accountID: String
    let localGroupID: UUID

    init(accountID: String, localGroupID: UUID) {
        self.accountID = accountID
        self.localGroupID = localGroupID
    }

    init(_ scope: LedgerScope) throws {
        guard case let .pendingServer(accountID, localGroupID) = scope else {
            throw LedgerScopeError.requiresPendingServerScope
        }
        self.init(accountID: accountID, localGroupID: localGroupID)
    }

    var ledgerScope: LedgerScope {
        .pendingServer(accountID: accountID, localGroupID: localGroupID)
    }
}

/// The scope allowed on a queued server operation. A local-only scope cannot
/// be represented by this type at all.
enum ServerLedgerMutationScope: Codable, Equatable, Hashable, Sendable {
    case serverBacked(accountID: String, groupID: String)
    case pendingServer(accountID: String, localGroupID: UUID)

    var accountID: String {
        switch self {
        case let .serverBacked(accountID, _), let .pendingServer(accountID, _):
            return accountID
        }
    }

    var serverGroupID: String? {
        guard case let .serverBacked(_, groupID) = self else { return nil }
        return groupID
    }

    var localGroupID: UUID? {
        guard case let .pendingServer(_, localGroupID) = self else { return nil }
        return localGroupID
    }

    var ledgerScope: LedgerScope {
        switch self {
        case let .serverBacked(accountID, groupID):
            return .serverBacked(accountID: accountID, groupID: groupID)
        case let .pendingServer(accountID, localGroupID):
            return .pendingServer(accountID: accountID, localGroupID: localGroupID)
        }
    }

    init(_ scope: LedgerScope) throws {
        guard let mutationScope = scope.serverMutationScope else {
            throw LedgerScopeError.localOnlyCannotProduceServerMutation
        }
        self = mutationScope
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case accountID
        case groupID
        case localGroupID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(LedgerScopeKind.self, forKey: .kind)
        let accountID = try container.decode(String.self, forKey: .accountID)

        switch kind {
        case .serverBacked:
            self = .serverBacked(
                accountID: accountID,
                groupID: try container.decode(String.self, forKey: .groupID)
            )
        case .pendingServer:
            self = .pendingServer(
                accountID: accountID,
                localGroupID: try container.decode(UUID.self, forKey: .localGroupID)
            )
        case .localOnly:
            throw LedgerScopeError.localOnlyCannotProduceServerMutation
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .serverBacked(accountID, groupID):
            try container.encode(LedgerScopeKind.serverBacked, forKey: .kind)
            try container.encode(accountID, forKey: .accountID)
            try container.encode(groupID, forKey: .groupID)
        case let .pendingServer(accountID, localGroupID):
            try container.encode(LedgerScopeKind.pendingServer, forKey: .kind)
            try container.encode(accountID, forKey: .accountID)
            try container.encode(localGroupID, forKey: .localGroupID)
        }
    }
}

enum LedgerScopeError: Error, Equatable, Sendable {
    case localOnlyCannotProduceServerMutation
    case requiresServerBackedScope
    case requiresPendingServerScope
}
