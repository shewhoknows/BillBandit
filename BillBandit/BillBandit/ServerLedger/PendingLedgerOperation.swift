import Foundation
import SwiftData

enum PendingLedgerOperationState: String, Codable, CaseIterable, Sendable {
    case pending
    case inFlight
    case retrying
    case succeeded
    case failed
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
    var requestPayload: Data
    var retryStateRaw: String
    var retryCount: Int
    var nextRetryAt: Date?
    var lastError: String?
    var createdAt: Date
    var updatedAt: Date

    init(operationID: UUID = UUID(),
         scope: ServerLedgerMutationScope,
         expectedRevision: Int64,
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
        self.requestPayload = requestPayload
        self.retryStateRaw = retryState.rawValue
        self.retryCount = retryCount
        self.nextRetryAt = nextRetryAt
        self.lastError = lastError
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

    var stateRaw: String {
        get { retryStateRaw }
        set { retryStateRaw = newValue }
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
        retryCount += 1
        retryStateRaw = PendingLedgerOperationState.retrying.rawValue
        nextRetryAt = date
        lastError = error
        updatedAt = .now
        return operationID
    }

    func markInFlight() {
        retryStateRaw = PendingLedgerOperationState.inFlight.rawValue
        updatedAt = .now
    }

    func markSucceeded() {
        retryStateRaw = PendingLedgerOperationState.succeeded.rawValue
        nextRetryAt = nil
        lastError = nil
        updatedAt = .now
    }

    func markFailed(error: String) {
        retryStateRaw = PendingLedgerOperationState.failed.rawValue
        nextRetryAt = nil
        lastError = error
        updatedAt = .now
    }
}

typealias PendingLedgerRetryState = PendingLedgerOperationState
