import Foundation

/// The value sent to the future server mutation endpoint.
///
/// A request carries the durable operation ID and expected revision together;
/// retries therefore use the same idempotency key and conflict fence.
struct ServerLedgerMutationRequest: Codable, Equatable, Sendable {
    let operationID: UUID
    let scope: ServerLedgerMutationScope
    let expectedRevision: Int64
    let requestPayload: Data

    init(operationID: UUID = UUID(),
         scope: ServerLedgerMutationScope,
         expectedRevision: Int64,
         requestPayload: Data) {
        self.operationID = operationID
        self.scope = scope
        self.expectedRevision = expectedRevision
        self.requestPayload = requestPayload
    }

    var accountID: String { scope.accountID }
    var payload: Data { requestPayload }
    var idempotencyKey: String { operationID.uuidString }
}

enum ServerLedgerAPIClientError: Error, Equatable, Sendable {
    case notImplemented
}

/// Transport boundary for the server-authoritative ledger.
///
/// Local-only scopes cannot reach this protocol: snapshots require a
/// server-backed scope and mutations require `ServerLedgerMutationScope`.
protocol ServerLedgerAPIClient: Sendable {
    func fetchSnapshot(for scope: ServerBackedLedgerScope) async throws -> ServerLedgerSnapshot
    func submit(_ request: ServerLedgerMutationRequest) async throws -> ServerLedgerSnapshot
}

/// Compile-safe placeholder until the transport contract is implemented.
struct UnconfiguredServerLedgerAPIClient: ServerLedgerAPIClient {
    init() {}

    func fetchSnapshot(for scope: ServerBackedLedgerScope) async throws -> ServerLedgerSnapshot {
        throw ServerLedgerAPIClientError.notImplemented
    }

    func submit(_ request: ServerLedgerMutationRequest) async throws -> ServerLedgerSnapshot {
        throw ServerLedgerAPIClientError.notImplemented
    }
}
