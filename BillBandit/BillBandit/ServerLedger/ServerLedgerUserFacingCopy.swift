import Foundation

/// Maps server/API ledger codes and internal status strings to copy safe for UI.
enum ServerLedgerUserFacingCopy {
    static let sharedBalancesTitle = "Shared balances"
    static let onDevice = "On this device"
    static let sharedGroup = "Shared group"
    static let loadingBalance = "Loading balance…"
    static let balanceUnavailable = "Balance unavailable"
    static let loadingSharedBalances = "Loading shared balances…"
    static let sharedBalancesUnavailable = "Couldn't load shared balances"
    static let sharedBalancesRetryHint = "Couldn't load shared balances · pull to refresh"
    static let offlineCachedBalances = "Showing saved balances · offline"
    static let staleBalances = "Balances may be outdated · pull to refresh"
    static let noSharedGroups = "No shared groups yet"
    static let signInForSharedBalances = "Sign in to view shared balances"

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
            return "You don't have access to this shared group."
        case "GROUP NOT FOUND":
            return "This shared group is no longer available."
        case "INTERNAL SERVER ERROR":
            return "Something went wrong loading shared balances. Try again."
        default:
            return nil
        }
    }

    static func friendlyMessage(_ raw: String?) -> String? {
        guard var rawMessage = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
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

    static func groupSourceLabel(isLocalOnly: Bool, isLoading: Bool) -> String {
        if isLocalOnly { return onDevice }
        if isLoading { return loadingBalance }
        return sharedGroup
    }
}
