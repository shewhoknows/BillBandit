import Foundation
import CryptoKit
import OSLog
import Security

private enum UsernameIdentityLog {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.billbandit.app",
        category: "mobile-identity"
    )

    static func transportFailure(path: String, error: Error) {
        let nsError = error as NSError
        logger.error(
            "Identity request transport failure path=\(path, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
        )
    }

    static func response(path: String, statusCode: Int) {
        logger.info(
            "Identity request response path=\(path, privacy: .public) status=\(statusCode, privacy: .public)"
        )
    }
}

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

/// Decides whether onboarding needs an atomic username claim. A verified
/// server handle belongs to an existing account and must be reused; only a
/// newly authenticated account may claim the requested handle.
enum UsernameOnboardingHandlePolicy {
    static func existingHandle(remoteUsername: String?,
                                isForcedPreview: Bool) -> String? {
        if isForcedPreview { return nil }
        guard case .verified(let username) =
                UsernameAccountReconciliationPolicy.decision(remoteUsername: remoteUsername)
        else { return nil }
        return username
    }
}

enum UsernameIdentityService {
    struct RemoteUser: Decodable, Sendable {
        let id: String
        let username: String?
        let name: String?
        let preferredName: String?
        let image: String?
    }

    fileprivate struct AuthenticatedSessionBinding: Codable, Sendable {
        let accountID: String
        let username: String?
        let name: String?
        let preferredName: String?
        let image: String?
        let tokenDigest: String
        let tokenExpiresAt: Date?
        let verifiedAt: Date

        var remoteUser: RemoteUser {
            RemoteUser(
                id: accountID,
                username: username,
                name: name,
                preferredName: preferredName,
                image: image
            )
        }

        func matches(token: String, now: Date) -> Bool {
            guard accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  tokenDigest == Self.digest(token) else {
                return false
            }
            if let tokenExpiresAt, tokenExpiresAt <= now {
                return false
            }
            return true
        }

        fileprivate static func digest(_ token: String) -> String {
            SHA256.hash(data: Data(token.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        }
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
        let nonce: String?
        let name: String?
        let email: String?
    }

    private struct UsernameRequest: Encodable { let username: String }
    private struct AvatarRequest: Encodable { let avatar: String }
    private struct AuthenticationResponse: Decodable {
        let token: String
        let user: RemoteUser
    }
    private struct UserResponse: Decodable { let user: RemoteUser }
    private struct AccountDeletionResponse: Decodable { let deleted: Bool }
    private struct ErrorResponse: Decodable { let error: String? }

    // Same REST base as the BillBandit API (Debug → local API via API_BASE_URL).
    private static var baseURL: URL { SettlementAPIConfiguration.baseURL }

    static var hasStoredSession: Bool { MobileTokenStore.read() != nil }

    static func authenticateWithApple(identityToken: Data,
                                      authorizationCode: Data?,
                                      nonce: String?,
                                      name: String?, email: String?) async throws -> RemoteUser {
        guard let tokenString = String(data: identityToken, encoding: .utf8),
              !tokenString.isEmpty else {
            throw ServiceError.invalidAppleCredential
        }
        let previousBindingAccountID = SessionBindingStore.read()?.accountID
        let body = AppleRequest(
            identityToken: tokenString,
            authorizationCode: authorizationCode.flatMap { String(data: $0, encoding: .utf8) },
            nonce: nonce,
            name: name,
            email: email
        )
        let response: AuthenticationResponse = try await perform(
            path: "/api/mobile/auth/apple", method: "POST", body: body, bearerToken: nil
        )
        try persistVerifiedSession(token: response.token, user: response.user)
        try await MainActor.run {
            guard MobileTokenStore.read() == response.token else {
                throw ServiceError.missingSession
            }
            let previousRuntimeAccountID = T15CanonicalLedgerRuntime.shared.sync.activeAccountID
                ?? ServerLedgerAccountLifecycle.shared.activeAccountID
            if (previousBindingAccountID ?? previousRuntimeAccountID) != response.user.id {
                T15CanonicalLedgerRuntime.shared.accountDidSignOut()
            }
            FriendInvitationService.shared.resetLocalState()
            try ServerLedgerAccountLifecycle.shared.activate(accountID: response.user.id)
            ServerSocialSyncService.shared.accountDidAuthenticate(response.user)
        }
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
        let user = try await verifyAndPersistSession(token: token)
        try await MainActor.run {
            guard MobileTokenStore.read() == token else {
                throw ServiceError.missingSession
            }
            ServerSocialSyncService.shared.accountDidAuthenticate(user)
            try ServerLedgerAccountLifecycle.shared.activate(accountID: user.id)
        }
        return user
    }

    /// Resolves the account for ledger enqueue and lifecycle work. A binding
    /// created by a successful `/auth/me` response can restore this identity
    /// offline. Profile and social callers continue to use `currentUser()`
    /// for an online authoritative refresh.
    static func authenticatedUserForLedger() async throws -> RemoteUser {
        guard let token = MobileTokenStore.read() else { throw ServiceError.missingSession }
        if let binding = SessionBindingStore.read(),
           binding.matches(token: token, now: .now) {
            let cachedUser = binding.remoteUser
            try await MainActor.run {
                guard MobileTokenStore.read() == token else {
                    throw ServiceError.missingSession
                }
                ServerSocialSyncService.shared.accountDidAuthenticate(cachedUser)
                try ServerLedgerAccountLifecycle.shared.activate(accountID: cachedUser.id)
            }
            return cachedUser
        }
        return try await currentUser()
    }

    static func updateAvatar(_ avatar: ProfileAvatar) async throws -> RemoteUser {
        guard let token = MobileTokenStore.read() else { throw ServiceError.missingSession }
        let response: UserResponse = try await perform(
            path: "/api/mobile/auth/me",
            method: "PATCH",
            body: AvatarRequest(avatar: avatar.rawValue),
            bearerToken: token
        )
        try await MainActor.run {
            guard MobileTokenStore.read() == token else {
                throw ServiceError.missingSession
            }
            try SessionBindingStore.write(
                AuthenticatedSessionBinding(
                    accountID: response.user.id,
                    username: response.user.username,
                    name: response.user.name,
                    preferredName: response.user.preferredName,
                    image: response.user.image,
                    tokenDigest: AuthenticatedSessionBinding.digest(token),
                    tokenExpiresAt: tokenExpiration(token),
                    verifiedAt: .now
                )
            )
            ServerSocialSyncService.shared.accountDidAuthenticate(response.user)
        }
        return response.user
    }

    static func signOut() {
        clearSessionAndInvalidateLedger()
    }

    /// Called by the ledger transport when the server rejects the bearer
    /// token. It clears only the session binding and pauses the queue; the
    /// account's durable operations remain available for reauthentication.
    static func serverDidRejectCurrentSession(token: String) {
        guard MobileTokenStore.read() == token else { return }
        invalidateUnauthorizedSession()
    }

    static func deleteAccount() async throws {
        guard let token = MobileTokenStore.read() else { throw ServiceError.missingSession }
        let response: AccountDeletionResponse = try await perform(
            path: "/api/mobile/auth/me", method: "DELETE", bearerToken: token
        )
        guard response.deleted else {
            throw ServiceError.response("BillBandit could not confirm account deletion.")
        }
        clearSessionAndInvalidateLedger()
    }

    private static func verifyAndPersistSession(token: String) async throws -> RemoteUser {
        let response: UserResponse = try await perform(
            path: "/api/mobile/auth/me", method: "GET", bearerToken: token
        )
        guard MobileTokenStore.read() == token else {
            throw ServiceError.missingSession
        }
        try persistVerifiedSession(token: token, user: response.user)
        return response.user
    }

    private static func persistVerifiedSession(token: String, user: RemoteUser) throws {
        guard user.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw ServiceError.response("BillBandit returned no account identity.")
        }
        try MobileTokenStore.write(token)
        try SessionBindingStore.write(
            AuthenticatedSessionBinding(
                accountID: user.id,
                username: user.username,
                name: user.name,
                preferredName: user.preferredName,
                image: user.image,
                tokenDigest: AuthenticatedSessionBinding.digest(token),
                tokenExpiresAt: tokenExpiration(token),
                verifiedAt: .now
            )
        )
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
        guard MobileTokenStore.read() == token else { throw ServiceError.missingSession }
        try persistVerifiedSession(token: token, user: response.user)
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
            UsernameIdentityLog.transportFailure(path: path, error: error)
            throw ServiceError.response("Could not reach BillBandit. Check your connection and try again.")
        }
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.response("BillBandit returned an invalid response.")
        }
        UsernameIdentityLog.response(path: path, statusCode: http.statusCode)
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401,
               let bearerToken,
               MobileTokenStore.read() == bearerToken {
                invalidateUnauthorizedSession()
            }
            let payload = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            let fallback: String
            if http.statusCode == 409 {
                fallback = "That username is already taken."
            } else if path == "/api/mobile/auth/apple" {
                fallback = http.statusCode == 401
                    ? "Apple could not verify this BillBandit build. Try again."
                    : "BillBandit could not complete Apple sign-in. Try again."
            } else if method == "DELETE" {
                fallback = "Could not delete your account. Try again."
            } else {
                fallback = "Could not save your username. Try again."
            }
            throw ServiceError.response(payload?.error ?? fallback)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ServiceError.response("BillBandit returned an unreadable response.")
        }
    }

    private static func clearSessionAndInvalidateLedger() {
        MobileTokenStore.clear()
        SessionBindingStore.clear()
        Task { @MainActor in
            ServerLedgerAccountLifecycle.shared.signOut()
            ServerSocialSyncService.shared.accountDidSignOut()
            ServerLedgerSurfaceStore.shared.accountDidSignOut()
            T15CanonicalLedgerRuntime.shared.accountDidSignOut()
            FriendInvitationService.shared.resetLocalState()
        }
    }

    private static func invalidateUnauthorizedSession() {
        let accountID = SessionBindingStore.read()?.accountID
        MobileTokenStore.clear()
        SessionBindingStore.clear()
        Task { @MainActor in
            ServerLedgerAccountLifecycle.shared.markUnauthorized(accountID: accountID)
            T15CanonicalLedgerRuntime.shared.accountDidLoseAuthorization(accountID: accountID)
        }
    }

    private static func tokenExpiration(_ token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var encoded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let payload = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let expiration = object["exp"] as? NSNumber else {
            return nil
        }
        return Date(timeIntervalSince1970: expiration.doubleValue)
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Installs a token only after the local API confirms it through `/auth/me`.
    /// This seam is restricted to a validated QA keychain namespace and loopback.
    @MainActor
    static func installSimulatorQASession(token: String) async throws -> RemoteUser {
        guard SettlementTokenStore.hasValidatedQATestNamespace,
              let host = baseURL.host?.lowercased(),
              host == "localhost" || host == "127.0.0.1" || host == "::1" else {
            throw ServiceError.response("QA session install requires a validated loopback API.")
        }
        guard !token.isEmpty else { throw ServiceError.missingSession }
        try MobileTokenStore.write(token)
        return try await currentUser()
    }
    #endif
}

private enum MobileTokenStore {
    private static let account = "authenticated-session"

    static func read() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: SettlementTokenStore.keychainService,
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
            kSecAttrService: SettlementTokenStore.keychainService,
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
            kSecAttrService: SettlementTokenStore.keychainService,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private enum SessionBindingStore {
    private static let account = "authenticated-session-binding-v1"

    static func read() -> UsernameIdentityService.AuthenticatedSessionBinding? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: SettlementTokenStore.keychainService,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(
            UsernameIdentityService.AuthenticatedSessionBinding.self,
            from: data
        )
    }

    static func write(_ binding: UsernameIdentityService.AuthenticatedSessionBinding) throws {
        clear()
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: SettlementTokenStore.keychainService,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: try JSONEncoder().encode(binding),
        ]
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw UsernameIdentityService.ServiceError.response(
                "Could not securely save your BillBandit session."
            )
        }
    }

    static func clear() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: SettlementTokenStore.keychainService,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
