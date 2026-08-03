import Foundation

enum ServerLedgerSyncError: Error, Equatable, Sendable {
    case snapshotScopeMismatch
}

/// Minimal reconciliation shell for the future transport and read-model
/// implementation.
@MainActor
final class ServerLedgerSync {
    private let store: ServerLedgerStore
    private let apiClient: any ServerLedgerAPIClient

    init(store: ServerLedgerStore, apiClient: any ServerLedgerAPIClient) {
        self.store = store
        self.apiClient = apiClient
    }

    @discardableResult
    func refresh(scope: ServerBackedLedgerScope) async throws -> ServerLedgerSnapshot {
        let snapshot = try await apiClient.fetchSnapshot(for: scope)
        guard snapshot.accountID == scope.accountID, snapshot.groupID == scope.groupID else {
            throw ServerLedgerSyncError.snapshotScopeMismatch
        }
        return try store.cache(snapshot: snapshot)
    }

    /// Submit queued operations in creation order. A failed operation remains
    /// in the durable queue with its original operation ID for a later retry.
    @discardableResult
    func drainPendingOperations(for accountID: String) async throws -> [ServerLedgerSnapshot] {
        let operations = try store.pendingOperations(for: accountID)
        var snapshots: [ServerLedgerSnapshot] = []

        for operation in operations {
            operation.markInFlight()
            try store.persist()

            do {
                let snapshot = try await apiClient.submit(try operation.makeRequest())
                _ = try store.cache(snapshot: snapshot)
                operation.markSucceeded()
                try store.persist()
                snapshots.append(snapshot)
            } catch {
                operation.retry(error: String(describing: error))
                try store.persist()
                throw error
            }
        }

        return snapshots
    }
}
