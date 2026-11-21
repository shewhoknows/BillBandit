import Foundation

/// Maps server/API ledger codes and internal status strings to copy safe for UI.
enum ServerLedgerUserFacingCopy {
    static let sharedBalancesTitle = "Balances"
    static let loadingBalance = "Loading balance…"
    static let balanceUnavailable = "Balance unavailable"
    static let loadingSharedBalances = "Loading balances…"
    static let sharedBalancesUnavailable = "Couldn't load balances"
    static let sharedBalancesRetryHint = "Couldn't load balances · pull to refresh"
    static let offlineCachedBalances = "Showing saved balances · offline"
    static let staleBalances = "Balances may be outdated · pull to refresh"
    static let noSharedGroups = "No groups yet"
    static let signInForSharedBalances = "Sign in to view balances"

    static func message(forAPIErrorCode code: String) -> String? {
        switch code.uppercased() {
        case "LEDGER_READ_UNAVAILABLE":
            return sharedBalancesRetryHint
        case "MONEY_MIGRATION_REQUIRED":
            return "This group is being upgraded. Balances will return soon."
        case "REVISION_CONFLICT":
            return "Balances changed on the server. Refresh and try again."
        case "IDEMPOTENCY_KEY_REUSED":
            return "That action was already sent. Refresh to see the latest balances."
        case "FORBIDDEN":
            return "You don't have access to this group."
        case "GROUP NOT FOUND":
            return "This group is no longer available."
        case "INTERNAL SERVER ERROR":
            return "Something went wrong loading balances. Try again."
        default:
            return nil
        }
    }

    static func friendlyMessage(_ raw: String?) -> String? {
        guard let rawMessage = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              rawMessage.isEmpty == false else {
            return nil
        }
        if let mapped = message(forAPIErrorCode: rawMessage) {
            return mapped
        }
        if rawMessage.uppercased() == rawMessage, rawMessage.contains("_") {
            return sharedBalancesRetryHint
        }
        return rawMessage
    }

    static func friendlyErrorMessage(_ error: Error) -> String {
        if let apiError = error as? ServerLedgerAPIClientError {
            return apiError.errorDescription ?? sharedBalancesUnavailable
        }
        if let syncError = error as? ServerLedgerSyncError {
            return syncError.errorDescription ?? sharedBalancesUnavailable
        }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           let friendly = friendlyMessage(description) {
            return friendly
        }
        return sharedBalancesUnavailable
    }
}

/// Words for a queued change that the server refused for good. Used by the
/// app-wide failure notice and by the group screen's pending list. Never
/// shows machine codes.
enum LedgerFailureCopy {
    /// Why it failed, from `PendingLedgerOperation.lastError`.
    static func reason(for lastError: String?) -> String {
        switch lastError {
        case "revision_conflict_requires_reconfirmation":
            return "Someone changed this group before your change reached the server."
        case "idempotency_key_reused":
            return "The server already has a different change with the same ID."
        case "snapshot_scope_mismatch":
            return "The server answered for a different group or account."
        case let value?:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let looksLikeCode = trimmed.isEmpty
                || (trimmed.contains("_") && !trimmed.contains(" "))
            return looksLikeCode ? "The server refused it." : trimmed
        case nil:
            return "The server refused it."
        }
    }

    /// Title and message for one failed row.
    static func notice(for operation: PendingLedgerOperation) -> (title: String, message: String) {
        let request = try? operation.makeRequest()
        let kind = request?.kind.lowercased() ?? ""
        var name: String?
        if let payload = request?.bodyPayload,
           let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
           let description = object["description"] as? String {
            let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { name = trimmed }
        }
        let quoted = name.map { " \u{201C}\($0)\u{201D}" } ?? ""
        let title: String
        switch kind {
        case "expense.create": title = "Expense\(quoted) not saved"
        case "expense.edit": title = "Change to\(quoted.isEmpty ? " an expense" : quoted) not saved"
        case "expense.delete": title = "Expense\(quoted) not deleted"
        case "settlement.create": title = "Payment not recorded"
        case "settlement.reverse": title = "Payment not reversed"
        case "settings.update": title = "Setting not changed"
        case let value where value.hasPrefix("membership."): title = "Member change not saved"
        case let value where value.hasPrefix("group."): title = "Group change not saved"
        default: title = "A change was not saved"
        }
        let message = "\(reason(for: operation.lastError)) Open the group, check it, and try again if you still need to."
        return (title, message)
    }
}
