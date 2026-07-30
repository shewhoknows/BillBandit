import Foundation
import Security

/// Shared REST configuration for BillBandit settlement / mobile auth APIs.
///
/// Production (Release builds): `https://billbandit-api.contenthelper.in`
/// — same Railway hostname before and after FairShare → BillBandit repo cutover.
enum SettlementAPIConfiguration {
    /// Prod API base URL; override in Debug via `API_BASE_URL` or local `apps/api` on :3000.
    private static let productionHost = "https://billbandit-api.contenthelper.in"
    private static let debugLocalHost = "http://127.0.0.1:3000"

    static var baseURL: URL {
        if let configured = configuredInfoValue(forKey: "API_BASE_URL"),
           let url = URL(string: configured) {
            return url
        }
        #if DEBUG
        return URL(string: debugLocalHost)!
        #else
        return URL(string: productionHost)!
        #endif
    }

    static var hasAuthenticatedSession: Bool {
        SettlementTokenStore.read() != nil
    }

    /// Resolves the server group id used by shared Settle Up for a local group.
    static func serverGroupId(for group: Group) -> String? {
        if let launchArg = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix("-sharedSettleUpGroupId=") }) {
            let value = String(launchArg.dropFirst("-sharedSettleUpGroupId=".count))
            if value.isEmpty == false { return value }
        }
        if let stored = group.serverGroupId?.trimmingCharacters(in: .whitespacesAndNewlines),
           stored.isEmpty == false {
            return stored
        }
        return nil
    }

    static func isSharedSettleUpAvailable(for group: Group) -> Bool {
        hasAuthenticatedSession && serverGroupId(for: group) != nil
    }

    /// Signed-in users should get shared Settle Up even before a FairShare group id is linked.
    static var prefersSharedSettleUp: Bool {
        hasAuthenticatedSession
    }

    private static func configuredInfoValue(forKey key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed.hasPrefix("$(") == false else { return nil }
        return trimmed
    }
}

enum SettlementTokenStore {
    static func read() -> String? {
        MobileTokenStore.read()
    }
}

/// Bridges the published app's keychain session store for settlement transport.
private enum MobileTokenStore {
    private static let service = "com.billbandit.app.mobile-api"
    private static let account = "authenticated-session"

    static func read() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
