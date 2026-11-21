import Foundation
import SwiftData

/// Life of one durable queue row. See docs/state-machines/ios-ledger-sync.md.
///
///     pending ──send──▶ inFlight ──2xx──────────▶ succeeded
///        │                 │  ├──409/4xx─────────▶ failed
///        │                 │  └──offline/5xx/401─▶ retrying ──send──▶ inFlight
///        │                 └──app killed: stays inFlight, replayed with the same ID
///        └──(pending or retrying) reservation broken ─▶ failed
///
/// `succeeded` and `failed` are final. Sign-out deletes rows in any state.
enum PendingLedgerOperationState: String, Codable, CaseIterable, Sendable {
    case pending
    case inFlight
    case retrying
    case succeeded
    case failed

    /// A waiting row may still be sent (with its original operation ID).
    var isWaiting: Bool {
        switch self {
        case .pending, .inFlight, .retrying: return true
        case .succeeded, .failed: return false
        }
    }

    var isTerminal: Bool { !isWaiting }

    /// The only transitions the queue performs. `inFlight -> inFlight` is the
    /// replay of a row whose app was killed while its request was out.
    func canTransition(to next: PendingLedgerOperationState) -> Bool {
        switch (self, next) {
        case (.pending, .inFlight), (.retrying, .inFlight), (.inFlight, .inFlight),
             (.inFlight, .succeeded), (.inFlight, .failed), (.inFlight, .retrying),
             (.pending, .failed), (.retrying, .failed):
            return true
        default:
            return false
        }
    }
}

/// A durable, account-scoped server mutation waiting for transport.
@Model
final class PendingLedgerOperation {
    @Attribute(.unique) var operationID: UUID
    var accountID: String
    var scopeKindRaw: String
    var serverGroupID: String?
    var localGroupID: UUID?
    var expectedRevision: Int64
    /// The server revision the person saw when they made this change. When
    /// `expectedRevision` is higher, the row was reserved on top of this
    /// device's own earlier queued rows (see `ServerLedgerQueueOrder`).
    /// Optional so existing stores migrate without a mapping model.
    var basedOnRevision: Int64?
    var requestPayload: Data
    var retryStateRaw: String
    var retryCount: Int
    var nextRetryAt: Date?
    var lastError: String?
    /// When the person was told that this row failed (an alert, a banner or
    /// the settle-up screen). nil for a failed row means nobody has told them
    /// yet; AppFailureCenter shows those. Optional so existing stores migrate
    /// without a mapping model.
    var failureAcknowledgedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(operationID: UUID = UUID(),
         scope: ServerLedgerMutationScope,
         expectedRevision: Int64,
         basedOnRevision: Int64? = nil,
         requestPayload: Data,
         retryState: PendingLedgerOperationState = .pending,
         retryCount: Int = 0,
         nextRetryAt: Date? = nil,
         lastError: String? = nil,
         createdAt: Date = .now,
         updatedAt: Date? = nil) {
        self.operationID = operationID
        self.accountID = scope.accountID
        switch scope {
        case let .serverBacked(_, groupID):
            self.scopeKindRaw = LedgerScopeKind.serverBacked.rawValue
            self.serverGroupID = groupID
            self.localGroupID = nil
        case let .pendingServer(_, localGroupID):
            self.scopeKindRaw = LedgerScopeKind.pendingServer.rawValue
            self.serverGroupID = nil
            self.localGroupID = localGroupID
        }
        self.expectedRevision = expectedRevision
        self.basedOnRevision = basedOnRevision
        self.requestPayload = requestPayload
        self.retryStateRaw = retryState.rawValue
        self.retryCount = retryCount
        self.nextRetryAt = nextRetryAt
        self.lastError = lastError
        self.failureAcknowledgedAt = nil
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    var retryState: PendingLedgerOperationState {
        get { PendingLedgerOperationState(rawValue: retryStateRaw) ?? .pending }
        set {
            retryStateRaw = newValue.rawValue
            updatedAt = .now
        }
    }

    var state: PendingLedgerOperationState {
        get { retryState }
        set { retryState = newValue }
    }

    var scope: LedgerScope {
        switch LedgerScopeKind(rawValue: scopeKindRaw) {
        case .serverBacked:
            return .serverBacked(accountID: accountID, groupID: serverGroupID ?? "")
        case .pendingServer:
            return .pendingServer(accountID: accountID, localGroupID: localGroupID ?? UUID())
        case .localOnly, .none:
            // A local-only operation cannot be created by this model's public
            // initializer. This fallback keeps corrupted legacy rows from
            // becoming a server mutation.
            return .localOnly(accountID: accountID, localGroupID: localGroupID ?? UUID())
        }
    }

    func makeMutationScope() throws -> ServerLedgerMutationScope {
        switch LedgerScopeKind(rawValue: scopeKindRaw) {
        case .serverBacked:
            guard let serverGroupID else {
                throw LedgerScopeError.requiresServerBackedScope
            }
            return .serverBacked(accountID: accountID, groupID: serverGroupID)
        case .pendingServer:
            guard let localGroupID else {
                throw LedgerScopeError.requiresPendingServerScope
            }
            return .pendingServer(accountID: accountID, localGroupID: localGroupID)
        case .localOnly, .none:
            throw LedgerScopeError.localOnlyCannotProduceServerMutation
        }
    }

    func makeRequest() throws -> ServerLedgerMutationRequest {
        ServerLedgerMutationRequest(
            operationID: operationID,
            scope: try makeMutationScope(),
            expectedRevision: expectedRevision,
            requestPayload: requestPayload
        )
    }

    /// Marking an operation for retry mutates the durable row in place. It
    /// never creates a replacement row or a new idempotency key.
    @discardableResult
    func retry(after date: Date? = nil, error: String? = nil) -> UUID {
        checkTransition(to: .retrying)
        retryCount += 1
        retryStateRaw = PendingLedgerOperationState.retrying.rawValue
        nextRetryAt = date
        lastError = error
        updatedAt = .now
        return operationID
    }

    func markInFlight() {
        checkTransition(to: .inFlight)
        retryStateRaw = PendingLedgerOperationState.inFlight.rawValue
        updatedAt = .now
    }

    func markSucceeded() {
        checkTransition(to: .succeeded)
        retryStateRaw = PendingLedgerOperationState.succeeded.rawValue
        nextRetryAt = nil
        lastError = nil
        updatedAt = .now
    }

    func markFailed(error: String) {
        checkTransition(to: .failed)
        retryStateRaw = PendingLedgerOperationState.failed.rawValue
        nextRetryAt = nil
        lastError = error
        updatedAt = .now
    }

    /// Debug builds stop on a transition outside the table above. Release
    /// builds keep the previous behaviour.
    private func checkTransition(to next: PendingLedgerOperationState) {
        assert(
            retryState.canTransition(to: next),
            "PendingLedgerOperation \(operationID): \(retryState) -> \(next) is not allowed"
        )
    }
}

/// Which waiting rows a drain may send, and in what order.
///
/// Rows of one ledger scope (one group) are sent strictly in creation order.
/// A later row never overtakes an earlier row that is still waiting for its
/// backoff: the later row's `expectedRevision` may count on the earlier row
/// being applied first, so sending it early makes the server reject it.
@MainActor
enum ServerLedgerQueueOrder {
    /// `rows` must already be in creation order.
    static func drainable(_ rows: [PendingLedgerOperation], dueAt: Date) -> [PendingLedgerOperation] {
        var blockedScopes = Set<String>()
        var result: [PendingLedgerOperation] = []
        for row in rows where row.retryState.isWaiting {
            let key = scopeKey(row)
            if blockedScopes.contains(key) { continue }
            if let nextRetryAt = row.nextRetryAt, nextRetryAt > dueAt {
                blockedScopes.insert(key)
                continue
            }
            result.append(row)
        }
        return result
    }

    /// A row reserved on top of this device's own queued rows (its
    /// `expectedRevision` is above the revision the person saw) may only be
    /// sent when every revision in between came from one of those rows. If one
    /// of them failed, a peer may own a revision in that range and an edit
    /// would overwrite a change the person never saw. Creates cannot overwrite
    /// anything, so they keep their old behaviour.
    static func reservationIsIntact(
        _ row: PendingLedgerOperation,
        kind: String,
        scopeRows: [PendingLedgerOperation]
    ) -> Bool {
        guard kind != "expense.create",
              let basedOn = row.basedOnRevision,
              basedOn < row.expectedRevision else { return true }
        let ownRevisions = Set(
            scopeRows
                .filter { $0.operationID != row.operationID && $0.retryState == .succeeded }
                .map(\.expectedRevision)
        )
        return (basedOn..<row.expectedRevision).allSatisfy { ownRevisions.contains($0) }
    }

    static func scopeKey(_ row: PendingLedgerOperation) -> String {
        "\(row.accountID)|\(row.scopeKindRaw)|\(row.serverGroupID ?? "")|\(row.localGroupID?.uuidString ?? "")"
    }
}
