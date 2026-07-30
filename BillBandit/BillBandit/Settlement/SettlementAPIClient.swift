import Foundation
import OSLog

enum SettlementAPILog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.billbandit.app"
    private static let apiLogger = Logger(subsystem: subsystem, category: "settlement-api")

    static func api(_ message: String) {
        apiLogger.info("\(message, privacy: .public)")
        #if DEBUG
        let line = "[BillBandit][settlement-api] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        #endif
    }

    static func sanitizedPath(_ rawPath: String) -> String {
        let path = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawPath
        let normalizedPath = path.isEmpty ? "/" : path
        let segments = normalizedPath.split(separator: "/").map { segment -> String in
            let value = String(segment)
            if value.contains("@") { return ":value" }
            if value.count >= 16 { return ":id" }
            if value.allSatisfy(\.isNumber), value.isEmpty == false { return ":id" }
            return value
        }
        return "/" + segments.joined(separator: "/")
    }

    static func sanitizedError(_ error: Error) -> String {
        switch error {
        case SettlementAPIError.invalidURL: return "invalid_url"
        case SettlementAPIError.invalidResponse: return "invalid_response"
        case SettlementAPIError.unauthorized: return "unauthorized"
        case SettlementAPIError.server: return "server_error"
        case SettlementAPIError.structured(let code, _, _): return "structured_\(code)"
        case let urlError as URLError: return "url_error_\(urlError.code.rawValue)"
        case let decodingError as DecodingError: return decodingError.logCode
        case let encodingError as EncodingError: return encodingError.logCode
        default: return String(describing: type(of: error))
        }
    }

    static func bool(_ value: Bool) -> String { value ? "true" : "false" }

    static func redactedID(_ value: String?) -> String {
        guard let value, value.isEmpty == false else { return "none" }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash).prefix(8).description
    }
}

private extension DecodingError {
    var logCode: String {
        switch self {
        case .typeMismatch: return "decoding_type_mismatch"
        case .valueNotFound: return "decoding_value_not_found"
        case .keyNotFound: return "decoding_key_not_found"
        case .dataCorrupted: return "decoding_data_corrupted"
        @unknown default: return "decoding_unknown"
        }
    }
}

private extension EncodingError {
    var logCode: String {
        switch self {
        case .invalidValue: return "encoding_invalid_value"
        @unknown default: return "encoding_unknown"
        }
    }
}

enum SettlementAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case server(String)
    case structured(code: String, status: Int, body: Data?)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid API URL"
        case .invalidResponse: "Invalid server response"
        case .unauthorized: "Your session expired. Please sign in again."
        case .server(let message): message
        case .structured(let code, _, _): code
        }
    }
}

struct SettlementEmptyBody: Encodable {}

final class APIClient: Sendable {
    let baseURL: URL
    private let session: URLSession
    private let tokenProvider: @Sendable () -> String?

    init(baseURL: URL, session: URLSession = .shared, tokenProvider: @escaping @Sendable () -> String?) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
    }

    static func live() -> APIClient {
        APIClient(baseURL: SettlementAPIConfiguration.baseURL) {
            SettlementTokenStore.read()
        }
    }

    func authorizationToken() -> String? { tokenProvider() }

    func get<Response: Decodable>(_ path: String) async throws -> Response {
        try await request(path, method: "GET", body: Optional<SettlementEmptyBody>.none)
    }

    func patch<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        idempotencyKey: String? = nil
    ) async throws -> Response {
        try await request(path, method: "PATCH", body: body, idempotencyKey: idempotencyKey)
    }

    func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        idempotencyKey: String? = nil
    ) async throws -> Response {
        try await request(path, method: "POST", body: body, idempotencyKey: idempotencyKey)
    }

    private func request<Body: Encodable, Response: Decodable>(
        _ path: String,
        method: String,
        body: Body?,
        idempotencyKey: String? = nil
    ) async throws -> Response {
        let sanitizedPath = SettlementAPILog.sanitizedPath(path)
        let startedAt = Date()
        guard let url = URL(string: path, relativeTo: baseURL) else {
            SettlementAPILog.api("event=settlement.request.failure method=\(method) path=\(sanitizedPath) error=invalid_url")
            throw SettlementAPIError.invalidURL
        }

        let encodedBody: Data?
        do {
            encodedBody = try body.map { try JSONEncoder.settlement.encode($0) }
        } catch {
            SettlementAPILog.api("event=settlement.request.failure method=\(method) path=\(sanitizedPath) error=\(SettlementAPILog.sanitizedError(error))")
            throw error
        }

        let hasToken = tokenProvider() != nil
        SettlementAPILog.api(
            "event=settlement.request.start method=\(method) path=\(sanitizedPath) auth=\(SettlementAPILog.bool(hasToken)) body_bytes=\(encodedBody?.count ?? 0)"
        )

        if baseURL.scheme == "mock" {
            do {
                let data = try await MockSettlementAPI.shared.requestData(
                    path: url.path,
                    method: method,
                    body: encodedBody,
                    hasToken: hasToken
                )
                SettlementAPILog.api(
                    "event=settlement.request.finish method=\(method) path=\(sanitizedPath) transport=mock status=200 duration_ms=\(durationMS(since: startedAt)) response_bytes=\(data.count)"
                )
                return try decode(Response.self, from: data, method: method, path: sanitizedPath, startedAt: startedAt)
            } catch {
                SettlementAPILog.api(
                    "event=settlement.request.failure method=\(method) path=\(sanitizedPath) transport=mock duration_ms=\(durationMS(since: startedAt)) error=\(SettlementAPILog.sanitizedError(error))"
                )
                throw error
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = hasToken ? tokenProvider() : nil {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let encodedBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = encodedBody
        }
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            SettlementAPILog.api(
                "event=settlement.request.failure method=\(method) path=\(sanitizedPath) duration_ms=\(durationMS(since: startedAt)) error=\(SettlementAPILog.sanitizedError(error))"
            )
            throw error
        }

        guard let http = response as? HTTPURLResponse else {
            SettlementAPILog.api(
                "event=settlement.request.failure method=\(method) path=\(sanitizedPath) duration_ms=\(durationMS(since: startedAt)) error=invalid_response"
            )
            throw SettlementAPIError.invalidResponse
        }

        SettlementAPILog.api(
            "event=settlement.request.finish method=\(method) path=\(sanitizedPath) status=\(http.statusCode) duration_ms=\(durationMS(since: startedAt)) response_bytes=\(data.count)"
        )

        if http.statusCode == 401 { throw SettlementAPIError.unauthorized }
        if !(200..<300).contains(http.statusCode) {
            if let error = try? JSONDecoder.settlement.decode(SettlementErrorResponse.self, from: data) {
                throw SettlementAPIError.structured(code: error.error, status: http.statusCode, body: data)
            }
            throw SettlementAPIError.server("Request failed with status \(http.statusCode)")
        }
        return try decode(Response.self, from: data, method: method, path: sanitizedPath, startedAt: startedAt)
    }

    private func decode<Response: Decodable>(
        _ responseType: Response.Type,
        from data: Data,
        method: String,
        path: String,
        startedAt: Date
    ) throws -> Response {
        do {
            return try JSONDecoder.settlement.decode(Response.self, from: data)
        } catch {
            SettlementAPILog.api(
                "event=settlement.decode.failure method=\(method) path=\(path) duration_ms=\(durationMS(since: startedAt)) error=\(SettlementAPILog.sanitizedError(error))"
            )
            throw error
        }
    }

    private func durationMS(since startedAt: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
    }
}

private struct SettlementErrorResponse: Decodable {
    let error: String
}

extension APIClient {
    func fetchSettleUp(groupId: String, afterVersion: Int?) async throws -> SettlementSnapshotDTO {
        var path = "/api/groups/\(groupId)/settle-up"
        if let afterVersion, afterVersion > 0 {
            path += "?afterVersion=\(afterVersion)"
        }
        do {
            return try await get(path)
        } catch let SettlementAPIError.structured(code, status, body) where code == "VERSION_AHEAD" && status == 409 {
            if let body,
               let conflict = try? JSONDecoder.settlement.decode(SettleUpVersionAheadResponse.self, from: body),
               let snapshot = conflict.snapshot {
                return snapshot
            }
            throw SettlementClientError.versionConflict
        } catch let error as SettlementAPIError {
            throw error
        }
    }

    func postSettlementMutation(
        path: String,
        body: some Encodable,
        idempotencyKey: String
    ) async throws -> SettlementMutationResponseDTO {
        do {
            return try await post(path, body: body, idempotencyKey: idempotencyKey)
        } catch let SettlementAPIError.structured(code, _, body) where code == "SETTLEMENT_VERSION_CONFLICT" || code == "TRANSFER_MISMATCH" {
            if let body,
               let conflict = try? JSONDecoder.settlement.decode(SettlementConflictResponse.self, from: body),
               let state = conflict.state {
                throw SettlementMutationConflictError(state: state)
            }
            throw SettlementClientError.versionConflict
        } catch let error as SettlementAPIError {
            throw error
        }
    }

    func patchSettlementMutation(
        path: String,
        body: some Encodable,
        idempotencyKey: String
    ) async throws -> SettlementMutationResponseDTO {
        do {
            return try await patch(path, body: body, idempotencyKey: idempotencyKey)
        } catch let SettlementAPIError.structured(code, _, body) where code == "SETTLEMENT_VERSION_CONFLICT" {
            if let body,
               let conflict = try? JSONDecoder.settlement.decode(SettlementConflictResponse.self, from: body),
               let state = conflict.state {
                throw SettlementMutationConflictError(state: state)
            }
            throw SettlementClientError.versionConflict
        } catch let error as SettlementAPIError {
            throw error
        }
    }
}

extension JSONDecoder {
    static let settlement: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        return decoder
    }()
}

extension JSONEncoder {
    static let settlement: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .useDefaultKeys
        return encoder
    }()
}
