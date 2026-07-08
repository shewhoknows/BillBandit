import Foundation
import Security

protocol TokenStore: Sendable {
    func token() async throws -> String?
    func saveToken(_ token: String) async throws
    func clearToken() async throws
}

enum KeychainTokenStoreError: Error, Sendable {
    case unexpectedStatus(OSStatus)
    case invalidData
}

actor KeychainTokenStore: TokenStore {
    private let service: String
    private let account: String

    init(service: String = Bundle.main.bundleIdentifier ?? "BillBandit", account: String = "mobile-jwt") {
        self.service = service
        self.account = account
    }

    func token() async throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainTokenStoreError.unexpectedStatus(status)
        }
        guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw KeychainTokenStoreError.invalidData
        }
        return token
    }

    func saveToken(_ token: String) async throws {
        let data = Data(token.utf8)
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseQuery() as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainTokenStoreError.unexpectedStatus(updateStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw KeychainTokenStoreError.unexpectedStatus(status)
        }
    }

    func clearToken() async throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainTokenStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

actor InMemoryTokenStore: TokenStore {
    private var storedToken: String?

    init(token: String? = nil) {
        self.storedToken = token
    }

    func token() async throws -> String? {
        storedToken
    }

    func saveToken(_ token: String) async throws {
        storedToken = token
    }

    func clearToken() async throws {
        storedToken = nil
    }
}

