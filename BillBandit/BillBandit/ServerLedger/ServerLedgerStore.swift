import Foundation
import SwiftData

enum ServerLedgerStoreError: Error, Equatable, Sendable {
    case operationIDCollision
}

/// Account-scoped persistence for server snapshots and queued mutations.
///
/// The store owns the predicates that enforce account isolation. Callers do
/// not fetch the shared cache or queue without supplying an account identity.
@MainActor
final class ServerLedgerStore {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func cachedSnapshot(for scope: ServerBackedLedgerScope) throws -> ServerLedgerSnapshot? {
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

    func cachedSnapshot(for scope: LedgerScope) throws -> ServerLedgerSnapshot? {
        try cachedSnapshot(for: ServerBackedLedgerScope(scope))
    }

    func cachedSnapshots(for accountID: String) throws -> [ServerLedgerSnapshot] {
        let descriptor = FetchDescriptor<CachedLedgerSnapshot>(
            predicate: #Predicate { row in row.accountID == accountID }
        )
        return try context.fetch(descriptor)
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { try $0.decodedSnapshot() }
    }

    /// Insert or advance a cache row. Older server revisions never overwrite
    /// newer local data.
    @discardableResult
    func cache(snapshot: ServerLedgerSnapshot) throws -> ServerLedgerSnapshot {
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

    @discardableResult
    func save(snapshot: ServerLedgerSnapshot) throws -> ServerLedgerSnapshot {
        try cache(snapshot: snapshot)
    }

    /// Insert an operation once. A retry or duplicate enqueue with the same
    /// operation ID returns the durable row rather than creating another row.
    @discardableResult
    func enqueue(_ request: ServerLedgerMutationRequest) throws -> PendingLedgerOperation {
        let operationID = request.operationID
        let descriptor = FetchDescriptor<PendingLedgerOperation>(
            predicate: #Predicate { row in row.operationID == operationID }
        )

        if let existing = try context.fetch(descriptor).first {
            guard existing.accountID == request.accountID else {
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
    func enqueue(scope: LedgerScope,
                 operationID: UUID = UUID(),
                 expectedRevision: Int64,
                 requestPayload: Data) throws -> PendingLedgerOperation {
        let mutationScope = try LocalOnlyPolicy.validateServerMutation(for: scope)
        return try enqueue(
            ServerLedgerMutationRequest(
                operationID: operationID,
                scope: mutationScope,
                expectedRevision: expectedRevision,
                requestPayload: requestPayload
            )
        )
    }

    func pendingOperations(for accountID: String,
                           includingCompleted: Bool = false) throws -> [PendingLedgerOperation] {
        let descriptor = FetchDescriptor<PendingLedgerOperation>(
            predicate: #Predicate { row in row.accountID == accountID }
        )
        let operations = try context.fetch(descriptor)
            .sorted { $0.createdAt < $1.createdAt }
        guard !includingCompleted else { return operations }
        return operations.filter { $0.retryState != .succeeded }
    }

    func pendingOperations(for scope: ServerLedgerMutationScope,
                           includingCompleted: Bool = false) throws -> [PendingLedgerOperation] {
        try pendingOperations(for: scope.accountID, includingCompleted: includingCompleted)
            .filter { operation in
                guard let operationScope = try? operation.makeMutationScope() else { return false }
                return operationScope == scope
            }
    }

    func persist() throws {
        try context.save()
    }
}
