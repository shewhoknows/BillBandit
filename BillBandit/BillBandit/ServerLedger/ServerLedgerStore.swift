import Foundation
import SwiftData

extension Notification.Name {
    /// Posted on the main actor when a queued change becomes failed and has
    /// not been shown to the person. userInfo["operationID"]: UUID.
    static let serverLedgerOperationFailed = Notification.Name("BillBandit.serverLedgerOperationFailed")
    /// Posted when `clear(accountID:)` removed an account's queue and cache.
    static let serverLedgerAccountCleared = Notification.Name("BillBandit.serverLedgerAccountCleared")
}

enum ServerLedgerStoreError: Error, Equatable, Sendable {
    case operationIDCollision
    case accountScopeRequired
    case snapshotScopeMismatch
    case operationNotFound
}

/// Account-scoped persistence for server snapshots and queued mutations.
///
/// Production callers share the app's local cache/queue model context, while
/// tests may supply an isolated context. Every public operation still requires
/// an API account identity so an account switch cannot expose another
/// account's rows.
@MainActor
final class ServerLedgerStore {
    let context: ModelContext
    private var drainingAccountIDs = Set<String>()
    /// Bumped by every `clear(accountID:)`. All `ServerLedgerSync` instances
    /// share this store, so a drain or refresh that started before a sign-out
    /// or account switch sees the change even when its own instance was never
    /// told about it, and stops before it sends or caches anything.
    private var accountEpochs: [String: Int] = [:]
    private var allAccountsEpoch = 0

    init(context: ModelContext) {
        self.context = context
    }

    func cachedSnapshot(for scope: ServerBackedLedgerScope) throws -> ServerLedgerSnapshot? {
        try requireAccount(scope.accountID)
        let accountID = scope.accountID
        let groupID = scope.groupID
        let descriptor = FetchDescriptor<CachedLedgerSnapshot>(
            predicate: #Predicate { row in
                row.accountID == accountID && row.serverGroupID == groupID
            }
        )
        guard let row = try context.fetch(descriptor).first else { return nil }
        return try row.decodedSnapshot()
    }

    func cachedSnapshot(for accountID: String, groupID: String) throws -> ServerLedgerSnapshot? {
        try cachedSnapshot(for: ServerBackedLedgerScope(accountID: accountID, groupID: groupID))
    }

    func cachedSnapshot(for scope: LedgerScope) throws -> ServerLedgerSnapshot? {
        try cachedSnapshot(for: ServerBackedLedgerScope(scope))
    }

    func cachedSnapshots(for accountID: String) throws -> [ServerLedgerSnapshot] {
        try requireAccount(accountID)
        let descriptor = FetchDescriptor<CachedLedgerSnapshot>(
            predicate: #Predicate { row in row.accountID == accountID }
        )
        return try context.fetch(descriptor)
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { try $0.decodedSnapshot() }
    }

    /// Insert or advance a cache row. Older server revisions never overwrite
    /// newer local data, while an equal revision is allowed to replace an
    /// optimistic payload with the canonical server representation.
    @discardableResult
    func cache(snapshot: ServerLedgerSnapshot) throws -> ServerLedgerSnapshot {
        try validate(snapshot: snapshot)
        let accountID = snapshot.accountID
        let groupID = snapshot.groupID
        let descriptor = FetchDescriptor<CachedLedgerSnapshot>(
            predicate: #Predicate { row in
                row.accountID == accountID && row.serverGroupID == groupID
            }
        )

        if let existing = try context.fetch(descriptor).first {
            guard snapshot.revision >= existing.revision else {
                return try existing.decodedSnapshot()
            }
            existing.update(from: snapshot)
        } else {
            context.insert(CachedLedgerSnapshot(snapshot: snapshot))
        }

        try context.save()
        return snapshot
    }

    /// Explicit name for the canonical replacement step after an optimistic
    /// local write. It shares the same revision fence as ordinary cache writes.
    @discardableResult
    func replaceWithCanonical(snapshot: ServerLedgerSnapshot) throws -> ServerLedgerSnapshot {
        try cache(snapshot: snapshot)
    }

    @discardableResult
    func save(snapshot: ServerLedgerSnapshot) throws -> ServerLedgerSnapshot {
        try cache(snapshot: snapshot)
    }

    /// Insert an operation once. A retry or duplicate enqueue with the same
    /// operation ID returns the durable row only when its request is identical.
    @discardableResult
    func enqueue(
        _ request: ServerLedgerMutationRequest,
        basedOnRevision: Int64? = nil
    ) throws -> PendingLedgerOperation {
        try requireAccount(request.accountID)
        guard request.scope.accountID == request.accountID else {
            throw ServerLedgerStoreError.accountScopeRequired
        }

        let operationID = request.operationID
        let descriptor = FetchDescriptor<PendingLedgerOperation>(
            predicate: #Predicate { row in row.operationID == operationID }
        )

        if let existing = try context.fetch(descriptor).first {
            guard existing.accountID == request.accountID,
                  existing.expectedRevision == request.expectedRevision,
                  existing.requestPayload == request.requestPayload,
                  (try? existing.makeMutationScope()) == request.scope else {
                throw ServerLedgerStoreError.operationIDCollision
            }
            return existing
        }

        let operation = PendingLedgerOperation(
            operationID: request.operationID,
            scope: request.scope,
            expectedRevision: request.expectedRevision,
            basedOnRevision: basedOnRevision,
            requestPayload: request.requestPayload
        )
        context.insert(operation)
        try context.save()
        return operation
    }

    @discardableResult
    func enqueue(
        _ request: ServerLedgerMutationRequest,
        optimisticSnapshot: ServerLedgerSnapshot?,
        basedOnRevision: Int64? = nil
    ) throws -> PendingLedgerOperation {
        if let optimisticSnapshot {
            guard optimisticSnapshot.accountID == request.accountID else {
                throw ServerLedgerStoreError.snapshotScopeMismatch
            }
            guard optimisticSnapshot.groupID == request.scope.serverGroupID else {
                throw ServerLedgerStoreError.snapshotScopeMismatch
            }
            _ = try cache(snapshot: optimisticSnapshot)
        }
        return try enqueue(request, basedOnRevision: basedOnRevision)
    }

    @discardableResult
    func enqueue(
        scope: LedgerScope,
        operationID: UUID = UUID(),
        expectedRevision: Int64,
        requestPayload: Data,
        optimisticSnapshot: ServerLedgerSnapshot? = nil
    ) throws -> PendingLedgerOperation {
        let mutationScope = try LocalOnlyPolicy.validateServerMutation(for: scope)
        return try enqueue(
            ServerLedgerMutationRequest(
                operationID: operationID,
                scope: mutationScope,
                expectedRevision: expectedRevision,
                requestPayload: requestPayload
            ),
            optimisticSnapshot: optimisticSnapshot
        )
    }

    func pendingOperations(
        for accountID: String,
        includingCompleted: Bool = false
    ) throws -> [PendingLedgerOperation] {
        try pendingOperations(
            for: accountID,
            includingCompleted: includingCompleted,
            includingFailed: true,
            dueAt: nil
        )
    }

    func pendingOperations(
        for accountID: String,
        includingCompleted: Bool,
        includingFailed: Bool,
        dueAt: Date?
    ) throws -> [PendingLedgerOperation] {
        try requireAccount(accountID)
        let descriptor = FetchDescriptor<PendingLedgerOperation>(
            predicate: #Predicate { row in row.accountID == accountID }
        )
        let operations = try context.fetch(descriptor)
            .sorted { left, right in
                if left.createdAt == right.createdAt {
                    return left.operationID.uuidString < right.operationID.uuidString
                }
                return left.createdAt < right.createdAt
            }

        return operations.filter { operation in
            if !includingCompleted, operation.retryState == .succeeded { return false }
            if !includingFailed, operation.retryState == .failed { return false }
            if let dueAt, let nextRetryAt = operation.nextRetryAt, nextRetryAt > dueAt {
                return false
            }
            return true
        }
    }

    /// The rows one drain may send now, in send order: waiting rows that are
    /// due, except that a group stops at its first row still in backoff.
    func drainableOperations(for accountID: String, dueAt: Date) throws -> [PendingLedgerOperation] {
        ServerLedgerQueueOrder.drainable(
            try pendingOperations(for: accountID, includingCompleted: false, includingFailed: false, dueAt: nil),
            dueAt: dueAt
        )
    }

    /// See `ServerLedgerQueueOrder.reservationIsIntact`.
    func reservationIsIntact(_ operation: PendingLedgerOperation, kind: String) throws -> Bool {
        let key = ServerLedgerQueueOrder.scopeKey(operation)
        let scopeRows = try pendingOperations(for: operation.accountID, includingCompleted: true)
            .filter { ServerLedgerQueueOrder.scopeKey($0) == key }
        return ServerLedgerQueueOrder.reservationIsIntact(operation, kind: kind, scopeRows: scopeRows)
    }

    func pendingOperations(
        for scope: ServerLedgerMutationScope,
        includingCompleted: Bool = false
    ) throws -> [PendingLedgerOperation] {
        try pendingOperations(for: scope.accountID, includingCompleted: includingCompleted)
            .filter { operation in
                guard let operationScope = try? operation.makeMutationScope() else { return false }
                return operationScope == scope
            }
    }

    /// Removes both cache and queue rows for exactly one API account. This is
    /// the sign-out/account-switch boundary; no legacy SwiftData entities are
    /// touched.
    func clear(accountID: String) throws {
        try requireAccount(accountID)
        accountEpochs[accountID, default: 0] &+= 1
        let cacheAccountID = accountID
        let cacheDescriptor = FetchDescriptor<CachedLedgerSnapshot>(
            predicate: #Predicate { row in row.accountID == cacheAccountID }
        )
        for row in try context.fetch(cacheDescriptor) {
            context.delete(row)
        }

        let queueAccountID = accountID
        let queueDescriptor = FetchDescriptor<PendingLedgerOperation>(
            predicate: #Predicate { row in row.accountID == queueAccountID }
        )
        for row in try context.fetch(queueDescriptor) {
            context.delete(row)
        }
        try context.save()
        NotificationCenter.default.post(
            name: .serverLedgerAccountCleared,
            object: nil,
            userInfo: ["accountID": accountID]
        )
    }

    /// Changes of this account that are not on the server yet (waiting or
    /// sending). Sign-out deletes them, so the person is asked first.
    func unsentOperationCount(for accountID: String) -> Int {
        ((try? pendingOperations(for: accountID, includingCompleted: false)) ?? [])
            .filter { $0.retryState.isWaiting }
            .count
    }

    /// Consecutive offline creates reserve consecutive group revisions.
    /// A peer change still causes a visible server conflict; no edit is rebased.
    func nextQueuedExpenseRevision(scope: ServerLedgerMutationScope,
                                   canonicalRevision: Int64,
                                   operationID: UUID) throws -> Int64 {
        let accountRows = try pendingOperations(for: scope.accountID, includingCompleted: true)
        let rows = accountRows.filter { (try? $0.makeMutationScope()) == scope }
        if let existing = rows.first(where: { $0.operationID == operationID }) {
            return existing.expectedRevision
        }
        let waiting = rows.filter { $0.retryState != .succeeded && $0.retryState != .failed }
        guard let last = waiting.map(\.expectedRevision).max(), last >= canonicalRevision else {
            return canonicalRevision
        }
        let next = last.addingReportingOverflow(1)
        guard !next.overflow else { throw ServerLedgerSyncError.conflictRequiresReconfirmation }
        return next.partialValue
    }

    /// Token for "this account's rows have not been cleared since".
    func accountEpoch(_ accountID: String) -> Int {
        accountEpochs[accountID, default: 0] &+ allAccountsEpoch
    }

    /// Called when rows are deleted outside `clear(accountID:)`, such as by
    /// `LocalAccountDataCleanup` after account deletion.
    func invalidateAllAccounts() {
        allAccountsEpoch &+= 1
    }

    func markPending(_ operation: PendingLedgerOperation) throws {
        guard operation.accountID.isEmpty == false else {
            throw ServerLedgerStoreError.accountScopeRequired
        }
        try context.save()
        if operation.retryState == .failed, operation.failureAcknowledgedAt == nil {
            // AppFailureCenter tells the person unless the screen that sent
            // the change already does.
            NotificationCenter.default.post(
                name: .serverLedgerOperationFailed,
                object: nil,
                userInfo: ["operationID": operation.operationID]
            )
        }
    }

    /// Failed rows of this account that nobody has shown to the person yet.
    func unacknowledgedFailures(for accountID: String) throws -> [PendingLedgerOperation] {
        try pendingOperations(for: accountID, includingCompleted: false)
            .filter { $0.retryState == .failed && $0.failureAcknowledgedAt == nil }
    }

    /// Records that the person has been told about this failed row, so no
    /// other screen tells them again.
    func acknowledgeFailure(operationID: UUID) throws {
        let id = operationID
        let descriptor = FetchDescriptor<PendingLedgerOperation>(
            predicate: #Predicate { row in row.operationID == id }
        )
        guard let row = try context.fetch(descriptor).first,
              row.retryState == .failed,
              row.failureAcknowledgedAt == nil else { return }
        row.failureAcknowledgedAt = .now
        try context.save()
    }

    func persist() throws {
        try context.save()
    }

    /// Prevents two runtime owners from submitting the same durable queue at
    /// the same time. The store is MainActor-isolated, so this check covers
    /// all `ServerLedgerSync` instances that share the production store.
    func beginDrain(accountID rawAccountID: String) -> Bool {
        let accountID = rawAccountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard accountID.isEmpty == false, drainingAccountIDs.insert(accountID).inserted else {
            return false
        }
        return true
    }

    func endDrain(accountID rawAccountID: String) {
        let accountID = rawAccountID.trimmingCharacters(in: .whitespacesAndNewlines)
        drainingAccountIDs.remove(accountID)
    }

    private func requireAccount(_ accountID: String) throws {
        guard accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw ServerLedgerStoreError.accountScopeRequired
        }
    }

    private func validate(snapshot: ServerLedgerSnapshot) throws {
        try requireAccount(snapshot.accountID)
        guard snapshot.groupID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw ServerLedgerStoreError.snapshotScopeMismatch
        }
    }
}
