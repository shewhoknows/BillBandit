import Foundation
import Security

/// Shared REST configuration for BillBandit settlement / mobile auth APIs.
///
/// Production (Release builds): `https://billbandit-api.contenthelper.in`
/// — the same Railway hostname used by the BillBandit production service.
enum SettlementAPIConfiguration {
    /// Prod API base URL; override in Debug via `API_BASE_URL` or local `apps/api` on :3000.
    private static let productionHost = "https://billbandit-api.contenthelper.in"
    private static let debugLocalHost = "http://127.0.0.1:3000"

    static var baseURL: URL {
        #if DEBUG && targetEnvironment(simulator)
        if let qaID = ProcessInfo.processInfo.environment["BILLBANDIT_QA_STORE_ID"],
           qaID.hasPrefix("vietnam-test-"),
           let rawURL = ProcessInfo.processInfo.environment["BILLBANDIT_QA_BASE_URL"],
           let url = URL(string: rawURL),
           url.scheme == "http", ["127.0.0.1", "localhost"].contains(url.host ?? "") {
            return url
        }
        #endif
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

    /// Signed-in users should get shared Settle Up even before a server group id is linked.
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
    private static let baseService = "com.billbandit.app.mobile-api"
    private static let account = "authenticated-session"

    /// The QA namespace is opt-in and only exists for simulator Debug builds.
    /// A malformed store id is quarantined so a harness cannot read or replace
    /// the normal app session by mistake.
    static var keychainService: String {
        #if DEBUG && targetEnvironment(simulator)
        if let raw = ProcessInfo.processInfo.environment["BILLBANDIT_QA_STORE_ID"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidQAStoreID(trimmed) else {
                return "\(baseService).qa.invalid"
            }
            return "\(baseService).qa.\(trimmed)"
        }
        #endif
        return baseService
    }

    #if DEBUG && targetEnvironment(simulator)
    static var hasValidatedQATestNamespace: Bool {
        guard let raw = ProcessInfo.processInfo.environment["BILLBANDIT_QA_STORE_ID"] else {
            return false
        }
        return isValidQAStoreID(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func isValidQAStoreID(_ value: String) -> Bool {
        guard value.hasPrefix("vietnam-test-"), (13...64).contains(value.count) else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 97 && scalar.value <= 122) ||
                (scalar.value >= 48 && scalar.value <= 57) ||
                scalar.value == 45 || scalar.value == 95 || scalar.value == 46
        }
    }
    #endif

    static func read() -> String? {
        MobileTokenStore.read()
    }
}

/// Bridges the published app's keychain session store for settlement transport.
private enum MobileTokenStore {
    static func read() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: SettlementTokenStore.keychainService,
            kSecAttrAccount: "authenticated-session",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
