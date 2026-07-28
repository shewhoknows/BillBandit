import Foundation
import Security

struct UsernameHandle: Equatable, Sendable {
    enum ValidationError: LocalizedError, Equatable {
        case length
        case firstCharacter
        case characters
        case trailingUnderscore
        case reserved

        var errorDescription: String? {
            switch self {
            case .length: return "Username must be 3-20 characters."
            case .firstCharacter: return "Username must start with a letter."
            case .characters: return "Use only lowercase letters, numbers, and underscores."
            case .trailingUnderscore: return "Username cannot end with an underscore."
            case .reserved: return "That username is reserved."
            }
        }
    }

    private static let reserved: Set<String> = [
        "admin", "billbandit", "help", "moderator", "official", "root",
        "security", "support", "system",
    ]

    let value: String

    init(_ rawValue: String) throws {
        var normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized.first == "@" { normalized.removeFirst() }

        guard (3...20).contains(normalized.count) else {
            throw ValidationError.length
        }
        guard let first = normalized.unicodeScalars.first,
              (97...122).contains(first.value) else {
            throw ValidationError.firstCharacter
        }
        guard normalized.unicodeScalars.allSatisfy({ scalar in
            (97...122).contains(scalar.value) ||
                (48...57).contains(scalar.value) || scalar.value == 95
        }) else {
            throw ValidationError.characters
        }
        guard normalized.last != "_" else {
            throw ValidationError.trailingUnderscore
        }
        guard !Self.reserved.contains(normalized) else {
            throw ValidationError.reserved
        }
        value = normalized
    }
}

enum UsernameAccountReconciliationDecision: Equatable {
    case verified(String)
    case requiresClaim
}

enum UsernameAccountReconciliationPolicy {
    static func decision(remoteUsername: String?) -> UsernameAccountReconciliationDecision {
        guard let remoteUsername,
              let handle = try? UsernameHandle(remoteUsername) else {
            return .requiresClaim
        }
        return .verified(handle.value)
    }
}

enum UsernameIdentityService {
    struct RemoteUser: Decodable, Sendable {
        let id: String
        let username: String?
    }

    enum ServiceError: LocalizedError {
        case invalidAppleCredential
        case missingSession
        case response(String)

        var errorDescription: String? {
            switch self {
            case .invalidAppleCredential:
                return "Apple did not provide a usable identity credential. Try again."
            case .missingSession:
                return "Reconnect your Apple account before saving your username."
            case .response(let message):
                return message
            }
        }
    }

    private struct AppleRequest: Encodable {
        let identityToken: String
        let authorizationCode: String?
        let name: String?
        let email: String?
    }

    private struct UsernameRequest: Encodable { let username: String }
    private struct AuthenticationResponse: Decodable {
        let token: String
        let user: RemoteUser
    }
    private struct UserResponse: Decodable { let user: RemoteUser }
    private struct ErrorResponse: Decodable { let error: String? }

    private static let baseURL = URL(string: "https://billbandit-api.contenthelper.in")!

    static var hasStoredSession: Bool { MobileTokenStore.read() != nil }

    static func authenticateWithApple(identityToken: Data,
                                      authorizationCode: Data?,
                                      name: String?, email: String?) async throws -> RemoteUser {
        guard let tokenString = String(data: identityToken, encoding: .utf8),
              !tokenString.isEmpty else {
            throw ServiceError.invalidAppleCredential
        }
        let body = AppleRequest(
            identityToken: tokenString,
            authorizationCode: authorizationCode.flatMap { String(data: $0, encoding: .utf8) },
            name: name,
            email: email
        )
        let response: AuthenticationResponse = try await perform(
            path: "/api/mobile/auth/apple", method: "POST", body: body, bearerToken: nil
        )
        try MobileTokenStore.write(response.token)
        return response.user
    }

    static func claim(_ handle: UsernameHandle) async throws -> String {
        try await save(handle, method: "POST")
    }

    static func rename(_ handle: UsernameHandle) async throws -> String {
        try await save(handle, method: "PUT")
    }

    static func currentUser() async throws -> RemoteUser {
        guard let token = MobileTokenStore.read() else { throw ServiceError.missingSession }
        let response: UserResponse = try await perform(
            path: "/api/mobile/auth/me", method: "GET", bearerToken: token
        )
        return response.user
    }

    static func signOut() {
        MobileTokenStore.clear()
    }

    private static func save(_ handle: UsernameHandle, method: String) async throws -> String {
        guard let token = MobileTokenStore.read() else { throw ServiceError.missingSession }
        let response: UserResponse = try await perform(
            path: "/api/mobile/auth/username", method: method,
            body: UsernameRequest(username: handle.value), bearerToken: token
        )
        guard let username = response.user.username, !username.isEmpty else {
            throw ServiceError.response("The server did not confirm your username.")
        }
        return username
    }

    private static func perform<Response: Decodable, Body: Encodable>(
        path: String, method: String, body: Body, bearerToken: String?
    ) async throws -> Response {
        try await performRequest(
            path: path,
            method: method,
            bodyData: try JSONEncoder().encode(body),
            bearerToken: bearerToken
        )
    }

    private static func perform<Response: Decodable>(
        path: String, method: String, bearerToken: String?
    ) async throws -> Response {
        try await performRequest(
            path: path, method: method, bodyData: nil, bearerToken: bearerToken
        )
    }

    private static func performRequest<Response: Decodable>(
        path: String, method: String, bodyData: Data?, bearerToken: String?
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if bodyData != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = bodyData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ServiceError.response("Could not reach BillBandit. Check your connection and try again.")
        }
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.response("BillBandit returned an invalid response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { MobileTokenStore.clear() }
            let payload = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            let fallback = http.statusCode == 409
                ? "That username is already taken."
                : "Could not save your username. Try again."
            throw ServiceError.response(payload?.error ?? fallback)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ServiceError.response("BillBandit returned an unreadable response.")
        }
    }
}

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

    static func write(_ token: String) throws {
        clear()
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: Data(token.utf8),
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw UsernameIdentityService.ServiceError.response(
                "Could not securely save your BillBandit session."
            )
        }
    }

    static func clear() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
