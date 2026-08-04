import Foundation

enum ServerLedgerSyncError: LocalizedError, Equatable, Sendable {
    case snapshotScopeMismatch
    case accountScopeRequired
    case activeAccountMismatch
    case accountChanged
    case conflictRequiresReconfirmation
    case unauthorized
    case offline
    case staleRevision

    var errorDescription: String? {
        switch self {
        case .snapshotScopeMismatch: return "The server returned another ledger scope"
        case .accountScopeRequired: return "An API account is required before syncing"
        case .activeAccountMismatch: return "The active API account does not own this ledger"
        case .accountChanged: return "The account changed while the ledger was syncing"
        case .conflictRequiresReconfirmation: return "The ledger changed; confirm this action again"
        case .unauthorized: return "The API session expired"
        case .offline: return "The ledger is waiting for a network connection"
        case .staleRevision: return "The server returned an older ledger revision"
        }
    }
}

enum ServerLedgerSyncState: Equatable, Sendable {
    case idle
    case refreshing
    case draining
    case offline
    case unauthorized
    case conflictRequiresReconfirmation
}

struct ServerLedgerSyncStatus: Equatable, Sendable {
    let accountID: String?
    let state: ServerLedgerSyncState
    let requiresReconfirmation: Bool
    let lastError: String?
}

/// Coordinates foreground/reconnect refreshes and the durable mutation queue.
/// All writes are sent through `ServerLedgerAPIClient`; the legacy SwiftData
/// Group/Expense/Settlement models are not part of this path.
@MainActor
final class ServerLedgerSync {
    private let store: ServerLedgerStore
    private let apiClient: any ServerLedgerAPIClient
    private let now: @Sendable () -> Date
    private let backoff: ServerLedgerBackoff

    private(set) var activeAccountID: String?
    private(set) var state: ServerLedgerSyncState = .idle
    private(set) var requiresReconfirmation = false
    private(set) var lastError: String?
    private var accountGeneration = 0

    init(
        store: ServerLedgerStore,
        apiClient: any ServerLedgerAPIClient,
        now: @escaping @Sendable () -> Date = { .now },
        backoff: ServerLedgerBackoff = ServerLedgerBackoff()
    ) {
        self.store = store
        self.apiClient = apiClient
        self.now = now
        self.backoff = backoff
    }

    var status: ServerLedgerSyncStatus {
        ServerLedgerSyncStatus(
            accountID: activeAccountID,
            state: state,
            requiresReconfirmation: requiresReconfirmation,
            lastError: lastError
        )
    }

    /// Starts a new account session. Any previous account's cache and queue
    /// are cleared before the new identity becomes active.
    func activate(accountID: String) throws {
        let accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard accountID.isEmpty == false else {
            throw ServerLedgerSyncError.accountScopeRequired
        }
        if let previous = activeAccountID, previous != accountID {
            try store.clear(accountID: previous)
        }
        accountGeneration &+= 1
        activeAccountID = accountID
        requiresReconfirmation = false
        lastError = nil
        state = .idle
    }

    func setActiveAccount(_ accountID: String) throws {
        try activate(accountID: accountID)
    }

    /// Clears the signed-out account and invalidates any in-flight result so a
    /// late response cannot repopulate the old account's cache.
    func signOut(accountID: String? = nil) throws {
        let account = accountID ?? activeAccountID
        guard let account else {
            activeAccountID = nil
            accountGeneration &+= 1
            state = .idle
            return
        }
        try store.clear(accountID: account)
        if activeAccountID == account {
            activeAccountID = nil
            accountGeneration &+= 1
            requiresReconfirmation = false
            lastError = nil
            state = .idle
        }
    }

    func markOffline() {
        state = .offline
        lastError = ServerLedgerAPIClientError.offline.localizedDescription
    }

    func markReconnected() {
        if state == .offline || state == .unauthorized {
            state = .idle
            lastError = nil
        }
    }

    @discardableResult
    func refresh(scope: ServerBackedLedgerScope) async throws -> ServerLedgerSnapshot {
        try ensureActiveAccount(scope.accountID)
        if state == .offline {
            throw ServerLedgerSyncError.offline
        }
        if state == .unauthorized {
            throw ServerLedgerSyncError.unauthorized
        }
        let generation = accountGeneration
        state = .refreshing

        do {
            let snapshot = try await apiClient.fetchSnapshot(for: scope)
            try ensureGeneration(generation, accountID: scope.accountID)
            guard snapshot.accountID == scope.accountID, snapshot.groupID == scope.groupID else {
                state = .idle
                throw ServerLedgerSyncError.snapshotScopeMismatch
            }
            if let cached = try store.cachedSnapshot(for: scope), snapshot.revision < cached.revision {
                throw ServerLedgerSyncError.staleRevision
            }
            let canonical = try store.replaceWithCanonical(snapshot: snapshot)
            state = .idle
            lastError = nil
            return canonical
        } catch {
            handle(error)
            throw map(error)
        }
    }

    /// Foreground reconciliation refreshes the canonical snapshot and then
    /// drains any operations that are due for the active account.
    @discardableResult
    func onForeground(scope: ServerBackedLedgerScope) async throws -> ServerLedgerSnapshot {
        _ = try await drainPendingOperations(for: scope.accountID)
        return try await refresh(scope: scope)
    }

    func refreshOnForeground(scope: ServerBackedLedgerScope) async throws -> ServerLedgerSnapshot {
        try await onForeground(scope: scope)
    }

    /// Reconnect is a queue-first event: accepted operations are sent once,
    /// then the read model is replaced with the server's canonical snapshot.
    @discardableResult
    func onReconnect(scope: ServerBackedLedgerScope) async throws -> ServerLedgerSnapshot {
        markReconnected()
        _ = try await drainPendingOperations(for: scope.accountID)
        return try await refresh(scope: scope)
    }

    func reconnect(scope: ServerBackedLedgerScope) async throws -> ServerLedgerSnapshot {
        try await onReconnect(scope: scope)
    }

    /// Submit queued operations in creation order. A successful response is
    /// cached before the row is marked succeeded, so a completed operation is
    /// never replayed merely because the process restarted after a response.
    @discardableResult
    func drainPendingOperations(for accountID: String) async throws -> [ServerLedgerSnapshot] {
        try ensureActiveAccount(accountID)
        if state == .draining {
            return []
        }
        if state == .offline {
            throw ServerLedgerSyncError.offline
        }
        if state == .unauthorized {
            throw ServerLedgerSyncError.unauthorized
        }
        let generation = accountGeneration
        let operations = try store.pendingOperations(
            for: accountID,
            includingCompleted: false,
            includingFailed: false,
            dueAt: now()
        )
        var snapshots: [ServerLedgerSnapshot] = []
        state = .draining
        defer {
            if state == .draining {
                state = .idle
            }
        }

        for operation in operations {
            try ensureGeneration(generation, accountID: accountID)
            operation.markInFlight()
            try store.markPending(operation)

            do {
                let request = try operation.makeRequest()
                let snapshot = try await apiClient.submit(request)
                try ensureGeneration(generation, accountID: accountID)
                guard snapshot.accountID == accountID else {
                    throw ServerLedgerSyncError.snapshotScopeMismatch
                }
                if case let .serverBacked(_, groupID) = request.scope,
                   snapshot.groupID != groupID {
                    throw ServerLedgerSyncError.snapshotScopeMismatch
                }
                if case let .serverBacked(requestAccountID, groupID) = request.scope,
                   let cached = try store.cachedSnapshot(
                       for: ServerBackedLedgerScope(accountID: requestAccountID, groupID: groupID)
                   ), snapshot.revision < cached.revision {
                    throw ServerLedgerSyncError.staleRevision
                }
                let canonical = try store.replaceWithCanonical(snapshot: snapshot)
                operation.markSucceeded()
                try store.markPending(operation)
                snapshots.append(canonical)
            } catch {
                if let syncError = error as? ServerLedgerSyncError,
                   syncError == .accountChanged {
                    state = .idle
                    lastError = nil
                    throw syncError
                }
                await refreshAfterRevisionConflict(
                    error,
                    operation: operation,
                    generation: generation,
                    accountID: accountID
                )
                try recordFailure(error, operation: operation)
                handle(error)
                throw map(error)
            }
        }

        state = .idle
        lastError = nil
        return snapshots
    }

    /// Allows an explicit confirmation to create a fresh logical operation
    /// after a revision conflict. The old conflicted row remains an audit
    /// record and is not automatically replayed.
    @discardableResult
    func reconfirm(
        operationID: UUID,
        scope: ServerLedgerMutationScope,
        expectedRevision: Int64,
        requestPayload: Data
    ) throws -> PendingLedgerOperation {
        guard activeAccountID == scope.accountID else {
            throw ServerLedgerSyncError.activeAccountMismatch
        }
        requiresReconfirmation = false
        return try store.enqueue(
            ServerLedgerMutationRequest(
                operationID: operationID,
                scope: scope,
                expectedRevision: expectedRevision,
                requestPayload: requestPayload
            )
        )
    }

    private func ensureActiveAccount(_ accountID: String) throws {
        guard accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw ServerLedgerSyncError.accountScopeRequired
        }
        if let activeAccountID {
            guard activeAccountID == accountID else {
                throw ServerLedgerSyncError.activeAccountMismatch
            }
        } else {
            activeAccountID = accountID
            accountGeneration &+= 1
        }
    }

    private func ensureGeneration(_ generation: Int, accountID: String) throws {
        guard generation == accountGeneration, activeAccountID == accountID else {
            throw ServerLedgerSyncError.accountChanged
        }
    }

    private func recordFailure(
        _ error: Error,
        operation: PendingLedgerOperation
    ) throws {
        switch error {
        case let conflict as ServerLedgerAPIClientError:
            switch conflict {
            case let .revisionConflict(_, _, snapshot):
                if let snapshot,
                   snapshot.accountID == operation.accountID {
                    _ = try? store.replaceWithCanonical(snapshot: snapshot)
                }
                operation.markFailed(error: "revision_conflict_requires_reconfirmation")
                requiresReconfirmation = true
            case .idempotencyKeyReused:
                operation.markFailed(error: "idempotency_key_reused")
            case .unauthorized:
                // Keep the operation durable across token renewal, but do not
                // give it another attempt until the caller explicitly enters
                // a new authenticated/reconnected sync cycle.
                operation.retry(after: nil, error: "unauthorized")
            case .offline:
                operation.retry(after: now().addingTimeInterval(backoff.delay(for: operation.retryCount + 1)), error: "offline")
            default:
                operation.retry(
                    after: now().addingTimeInterval(backoff.delay(for: operation.retryCount + 1)),
                    error: ServerLedgerErrorDescription.string(error)
                )
            }
        case let conflict as ServerLedgerSyncError where conflict == .conflictRequiresReconfirmation:
            operation.markFailed(error: "revision_conflict_requires_reconfirmation")
            requiresReconfirmation = true
        case let syncError as ServerLedgerSyncError where syncError == .snapshotScopeMismatch:
            operation.markFailed(error: "snapshot_scope_mismatch")
        default:
            operation.retry(
                after: now().addingTimeInterval(backoff.delay(for: operation.retryCount + 1)),
                error: ServerLedgerErrorDescription.string(error)
            )
        }
        try store.markPending(operation)
    }

    private func refreshAfterRevisionConflict(
        _ error: Error,
        operation: PendingLedgerOperation,
        generation: Int,
        accountID: String
    ) async {
        guard case let ServerLedgerAPIClientError.revisionConflict(_, _, snapshot) = error,
              snapshot == nil,
              let scope = try? operation.makeMutationScope(),
              case let .serverBacked(_, groupID) = scope else { return }
        do {
            try ensureGeneration(generation, accountID: accountID)
            let serverScope = ServerBackedLedgerScope(accountID: accountID, groupID: groupID)
            let refreshed = try await apiClient.fetchSnapshot(for: serverScope)
            try ensureGeneration(generation, accountID: accountID)
            guard refreshed.accountID == accountID, refreshed.groupID == groupID else { return }
            _ = try store.replaceWithCanonical(snapshot: refreshed)
        } catch {
            // Keep the original conflict as the user-visible failure. A
            // best-effort refresh still prevents an automatic replay while a
            // later foreground cycle can retry the read.
        }
    }

    private func handle(_ error: Error) {
        lastError = ServerLedgerErrorDescription.string(error)
        switch error {
        case ServerLedgerAPIClientError.unauthorized:
            state = .unauthorized
        case ServerLedgerAPIClientError.offline:
            state = .offline
        case ServerLedgerAPIClientError.revisionConflict:
            state = .conflictRequiresReconfirmation
            requiresReconfirmation = true
        case ServerLedgerSyncError.conflictRequiresReconfirmation:
            state = .conflictRequiresReconfirmation
            requiresReconfirmation = true
        case ServerLedgerSyncError.staleRevision:
            state = .idle
        default:
            state = .idle
        }
    }

    private func map(_ error: Error) -> Error {
        switch error {
        case ServerLedgerAPIClientError.unauthorized:
            return ServerLedgerSyncError.unauthorized
        case ServerLedgerAPIClientError.offline:
            return ServerLedgerSyncError.offline
        case ServerLedgerAPIClientError.revisionConflict:
            return ServerLedgerSyncError.conflictRequiresReconfirmation
        case ServerLedgerAPIClientError.staleRevision:
            return ServerLedgerSyncError.staleRevision
        case ServerLedgerAPIClientError.snapshotScopeMismatch:
            return ServerLedgerSyncError.snapshotScopeMismatch
        case let syncError as ServerLedgerSyncError:
            return syncError
        default:
            return error
        }
    }
}

struct ServerLedgerBackoff: Equatable, Sendable {
    let baseDelay: TimeInterval
    let maximumDelay: TimeInterval

    init(baseDelay: TimeInterval = 1, maximumDelay: TimeInterval = 300) {
        self.baseDelay = max(0, baseDelay)
        self.maximumDelay = max(self.baseDelay, maximumDelay)
    }

    func delay(for retryCount: Int) -> TimeInterval {
        guard retryCount > 0 else { return baseDelay }
        let exponent = min(retryCount - 1, 16)
        let multiplier = TimeInterval(1 << exponent)
        return min(maximumDelay, baseDelay * multiplier)
    }
}

private enum ServerLedgerErrorDescription {
    static func string(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: type(of: error))
    }
}
