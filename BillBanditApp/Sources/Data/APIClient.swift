import Foundation

enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

private struct APIErrorBody: Decodable {
    var error: String
}

final class APIClient: Sendable {
    let baseURL: URL
    private let session: URLSession
    private let tokenStore: any TokenStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        baseURL: URL = APIClient.baseURLFromInfoPlist(),
        session: URLSession = .shared,
        tokenStore: any TokenStore = KeychainTokenStore()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenStore = tokenStore
        self.encoder = JSONEncoder.billBanditAPIEncoder()
        self.decoder = JSONDecoder.billBanditAPIDecoder()
    }

    static func baseURLFromInfoPlist(bundle: Bundle = .main) -> URL {
        let value = bundle.object(forInfoDictionaryKey: "API_BASE_URL") as? String
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty, !trimmed.hasPrefix("$("), let url = URL(string: trimmed) {
            return url
        }
        return URL(string: "https://billbandit-api.contenthelper.in")!
    }

    @discardableResult
    func request<Response: Decodable>(
        _ method: HTTPMethod,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: (any Encodable)? = nil,
        authorized: Bool = true,
        responseType: Response.Type = Response.self
    ) async throws -> Response {
        let request = try await makeURLRequest(method, path: path, queryItems: queryItems, body: body, authorized: authorized)
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.network("Response was not HTTP")
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw mapError(statusCode: httpResponse.statusCode, data: data)
            }
            do {
                return try decoder.decode(Response.self, from: data)
            } catch {
                throw APIError.decoding(error.localizedDescription)
            }
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.network(error.localizedDescription)
        }
    }

    func requestVoid(
        _ method: HTTPMethod,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: (any Encodable)? = nil,
        authorized: Bool = true
    ) async throws {
        let _: EmptyResponse = try await request(
            method,
            path: path,
            queryItems: queryItems,
            body: body,
            authorized: authorized,
            responseType: EmptyResponse.self
        )
    }

    private func makeURLRequest(
        _ method: HTTPMethod,
        path: String,
        queryItems: [URLQueryItem],
        body: (any Encodable)?,
        authorized: Bool
    ) async throws -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else {
            throw APIError.network("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try encoder.encode(AnyEncodable(body))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authorized, let token = try await tokenStore.token() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func mapError(statusCode: Int, data: Data) -> APIError {
        let message = (try? decoder.decode(APIErrorBody.self, from: data).error) ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
        switch statusCode {
        case 400, 422:
            return .validation(message)
        case 401:
            return .unauthorized
        case 404:
            return .notFound
        case 409:
            return .conflict(message)
        default:
            return .server(statusCode: statusCode, message: message)
        }
    }
}

struct EmptyResponse: Decodable, Sendable {}

private struct AnyEncodable: Encodable {
    private let encodeClosure: (Encoder) throws -> Void

    init(_ wrapped: any Encodable) {
        self.encodeClosure = wrapped.encode(to:)
    }

    func encode(to encoder: Encoder) throws {
        try encodeClosure(encoder)
    }
}

extension JSONEncoder {
    static func billBanditAPIEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(makeISO8601Formatter(includeFractionalSeconds: true).string(from: date))
        }
        return encoder
    }
}

extension JSONDecoder {
    static func billBanditAPIDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = makeISO8601Formatter(includeFractionalSeconds: true).date(from: string) ?? makeISO8601Formatter(includeFractionalSeconds: false).date(from: string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date: \(string)")
            }
            return date
        }
        return decoder
    }
}

private func makeISO8601Formatter(includeFractionalSeconds: Bool) -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = includeFractionalSeconds ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
    return formatter
}
