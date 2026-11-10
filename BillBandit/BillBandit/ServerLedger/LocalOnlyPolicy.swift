import Foundation

/// The explicit policy boundary for private, device-only ledgers.
///
/// Shared settlement is available only after a group has a canonical server
/// scope. The policy also exposes the only safe conversion to a mutation scope
/// so callers do not accidentally turn a local-only group into a server write.
struct LocalOnlyPolicy: Equatable, Sendable {
    let scope: LedgerScope

    init(scope: LedgerScope) {
        self.scope = scope
    }

    var isLocalOnly: Bool { scope.isLocalOnly }
    var canEnterSharedSettlement: Bool { scope.canEnterSharedSettlement }

    func serverMutationScope() throws -> ServerLedgerMutationScope {
        guard let mutationScope = scope.serverMutationScope else {
            throw LocalOnlyPolicyError.serverMutationNotPermitted
        }
        return mutationScope
    }

    static func canEnterSharedSettlement(_ scope: LedgerScope) -> Bool {
        scope.canEnterSharedSettlement
    }

    static func serverMutationScope(for scope: LedgerScope) -> ServerLedgerMutationScope? {
        scope.serverMutationScope
    }

    static func validateServerMutation(for scope: LedgerScope) throws -> ServerLedgerMutationScope {
        try LocalOnlyPolicy(scope: scope).serverMutationScope()
    }
}

enum LocalOnlyPolicyError: Error, Equatable, Sendable {
    case serverMutationNotPermitted
    case sharedSettlementNotPermitted
}
