import Foundation

enum APIError: Error, Sendable {
    case unauthorized
    case notFound
    case conflict(String)
    case validation(String)
    case network(String)
    case server(statusCode: Int, message: String)
    case decoding(String)
}

extension APIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Unauthorized"
        case .notFound:
            "Not found"
        case .conflict(let message), .validation(let message):
            message
        case .network(let message), .decoding(let message):
            message
        case .server(_, let message):
            message
        }
    }
}

