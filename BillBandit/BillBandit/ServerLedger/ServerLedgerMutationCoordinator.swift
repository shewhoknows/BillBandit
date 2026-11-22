import Foundation

/// Creates durable server mutations while keeping local-only scopes outside
/// the queue's type boundary. These helpers perform no SwiftData writes to
/// legacy Group, Expense, or Settlement entities.
@MainActor
final class ServerLedgerMutationCoordinator {
    private let store: ServerLedgerStore
    private(set) var activeAccountID: String?

    init(store: ServerLedgerStore, activeAccountID: String? = nil) {
        self.store = store
        self.activeAccountID = activeAccountID
    }

    func activate(accountID: String) throws {
        let trimmed = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw ServerLedgerStoreError.accountScopeRequired
        }
        if let previous = activeAccountID, previous != trimmed {
            try store.clear(accountID: previous)
        }
        activeAccountID = trimmed
    }

    func signOut(accountID: String? = nil) throws {
        let account = accountID ?? activeAccountID
        if let account {
            try store.clear(accountID: account)
        }
        if accountID == nil || accountID == activeAccountID {
            activeAccountID = nil
        }
    }

    @discardableResult
    func enqueue(
        _ request: ServerLedgerMutationRequest,
        optimisticSnapshot: ServerLedgerSnapshot? = nil,
        basedOnRevision: Int64? = nil
    ) throws -> PendingLedgerOperation {
        try ensureActiveAccount(request.accountID)
        return try store.enqueue(
            request,
            optimisticSnapshot: optimisticSnapshot,
            basedOnRevision: basedOnRevision
        )
    }

    @discardableResult
    func enqueue(
        operationID: UUID = UUID(),
        scope: ServerLedgerMutationScope,
        expectedRevision: Int64,
        requestPayload: Data,
        optimisticSnapshot: ServerLedgerSnapshot? = nil
    ) throws -> PendingLedgerOperation {
        try enqueue(
            ServerLedgerMutationRequest(
                operationID: operationID,
                scope: scope,
                expectedRevision: expectedRevision,
                requestPayload: requestPayload
            ),
            optimisticSnapshot: optimisticSnapshot
        )
    }

    /// Convenience boundary for callers that still hold an arbitrary scope.
    /// Local-only input is rejected before a request or queue row exists.
    @discardableResult
    func enqueue(
        operationID: UUID = UUID(),
        scope: LedgerScope,
        expectedRevision: Int64,
        requestPayload: Data,
        optimisticSnapshot: ServerLedgerSnapshot? = nil
    ) throws -> PendingLedgerOperation {
        let mutationScope = try LocalOnlyPolicy.validateServerMutation(for: scope)
        return try enqueue(
            operationID: operationID,
            scope: mutationScope,
            expectedRevision: expectedRevision,
            requestPayload: requestPayload,
            optimisticSnapshot: optimisticSnapshot
        )
    }

    /// Generic route-aware entry point used by offline group, expense, and
    /// settlement actions. The operation ID is created here, before any retry
    /// or network attempt, and the queue stores the route metadata with the
    /// body so a later process can reconstruct the same request.
    ///
    /// `expectedRevision` is the revision the person saw. When this device
    /// still has earlier rows waiting for the same group, the row expects the
    /// revision after them (as creates always did), so the person's own queued
    /// change does not make their next edit conflict. The drain sends such a
    /// row only while that chain is intact (`ServerLedgerQueueOrder`).
    @discardableResult
    func enqueueServerMutation(
        operationID: UUID = UUID(),
        scope: ServerLedgerMutationScope,
        expectedRevision: Int64,
        kind: String,
        method: String = "POST",
        path: String,
        body: Data,
        optimisticSnapshot: ServerLedgerSnapshot? = nil
    ) throws -> PendingLedgerOperation {
        try ensureActiveAccount(scope.accountID)
        // Idempotent: a create the caller already reserved keeps its value,
        // and a known operation ID keeps its stored revision.
        let queuedRevision = try store.nextQueuedExpenseRevision(
            scope: scope,
            canonicalRevision: expectedRevision,
            operationID: operationID
        )
        return try enqueue(
            ServerLedgerMutationRequest(
                operationID: operationID,
                scope: scope,
                expectedRevision: queuedRevision,
                kind: kind,
                method: method,
                path: path,
                body: body
            ),
            optimisticSnapshot: optimisticSnapshot,
            basedOnRevision: expectedRevision
        )
    }

    @discardableResult
    func enqueueExpenseAction(
        operationID: UUID = UUID(),
        scope: ServerLedgerMutationScope,
        expectedRevision: Int64,
        kind: String = "expense.create",
        method: String = "POST",
        path: String = "/api/mobile/expenses",
        body: Data,
        optimisticSnapshot: ServerLedgerSnapshot? = nil
    ) throws -> PendingLedgerOperation {
        try enqueueServerMutation(
            operationID: operationID,
            scope: scope,
            expectedRevision: expectedRevision,
            kind: kind,
            method: method,
            path: path,
            body: body,
            optimisticSnapshot: optimisticSnapshot
        )
    }

    private func ensureActiveAccount(_ accountID: String) throws {
        guard accountID.isEmpty == false else {
            throw ServerLedgerStoreError.accountScopeRequired
        }
        if let activeAccountID {
            guard activeAccountID == accountID else {
                throw ServerLedgerStoreError.accountScopeRequired
            }
        } else {
            activeAccountID = accountID
        }
    }
}
