import Foundation
import SwiftData

enum ServerLedgerStoreError: Error, Equatable, Sendable {
    case operationIDCollision
    case accountScopeRequired
    case snapshotScopeMismatch
    case operationNotFound
}

/// Account-scoped persistence for server snapshots and queued mutations.
///
/// The store is intentionally independent from the legacy app schema. The
/// caller supplies a cache/queue model context, while every public operation
/// still requires an API account identity so an account switch cannot fall
/// through to another account's rows.
@MainActor
final class ServerLedgerStore {
    let context: ModelContext

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
    func enqueue(_ request: ServerLedgerMutationRequest) throws -> PendingLedgerOperation {
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
            requestPayload: request.requestPayload
        )
        context.insert(operation)
        try context.save()
        return operation
    }

    @discardableResult
    func enqueue(
        _ request: ServerLedgerMutationRequest,
        optimisticSnapshot: ServerLedgerSnapshot?
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
        return try enqueue(request)
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
    }

    func clearAccount(accountID: String) throws {
        try clear(accountID: accountID)
    }

    func clearQueue(accountID: String) throws {
        try requireAccount(accountID)
        let queueAccountID = accountID
        let descriptor = FetchDescriptor<PendingLedgerOperation>(
            predicate: #Predicate { row in row.accountID == queueAccountID }
        )
        for row in try context.fetch(descriptor) {
            context.delete(row)
        }
        try context.save()
    }

    func markPending(_ operation: PendingLedgerOperation) throws {
        guard operation.accountID.isEmpty == false else {
            throw ServerLedgerStoreError.accountScopeRequired
        }
        try context.save()
    }

    func persist() throws {
        try context.save()
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
