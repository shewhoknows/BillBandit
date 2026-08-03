import Foundation

/// Creates durable server mutations while keeping local-only scopes outside
/// the queue's type boundary.
@MainActor
final class ServerLedgerMutationCoordinator {
    private let store: ServerLedgerStore

    init(store: ServerLedgerStore) {
        self.store = store
    }

    @discardableResult
    func enqueue(_ request: ServerLedgerMutationRequest) throws -> PendingLedgerOperation {
        try store.enqueue(request)
    }

    @discardableResult
    func enqueue(operationID: UUID = UUID(),
                 scope: ServerLedgerMutationScope,
                 expectedRevision: Int64,
                 requestPayload: Data) throws -> PendingLedgerOperation {
        try enqueue(
            ServerLedgerMutationRequest(
                operationID: operationID,
                scope: scope,
                expectedRevision: expectedRevision,
                requestPayload: requestPayload
            )
        )
    }

    /// Convenience boundary for callers that still hold an arbitrary scope.
    /// Local-only input is rejected before a request or queue row exists.
    @discardableResult
    func enqueue(operationID: UUID = UUID(),
                 scope: LedgerScope,
                 expectedRevision: Int64,
                 requestPayload: Data) throws -> PendingLedgerOperation {
        let mutationScope = try LocalOnlyPolicy.validateServerMutation(for: scope)
        return try enqueue(
            operationID: operationID,
            scope: mutationScope,
            expectedRevision: expectedRevision,
            requestPayload: requestPayload
        )
    }
}
