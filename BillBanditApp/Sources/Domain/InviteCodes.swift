import Foundation

enum InviteCodeError: Error, Equatable {
    case invalidCharacter
    case tooShort
    case badChecksum
}

struct InviteCode: Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case friend = "F"
        case trip = "T"
    }

    static let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")

    var kind: Kind
    var rawValue: String

    static func generate(kind: Kind, bytes: [UInt8]) -> InviteCode {
        var body = kind.rawValue
        for byte in bytes {
            body.append(alphabet[Int(byte) % alphabet.count])
        }
        let checksum = checksumCharacters(for: body)
        return InviteCode(kind: kind, rawValue: chunked(body + checksum))
    }

    static func parse(_ input: String) throws -> InviteCode {
        let normalized = input
            .uppercased()
            .filter { !$0.isWhitespace && $0 != "-" }

        guard normalized.count >= 5 else {
            throw InviteCodeError.tooShort
        }
        guard normalized.allSatisfy({ alphabet.contains($0) }) else {
            throw InviteCodeError.invalidCharacter
        }
        guard let kind = Kind(rawValue: String(normalized.prefix(1))) else {
            throw InviteCodeError.invalidCharacter
        }

        let bodyEnd = normalized.index(normalized.endIndex, offsetBy: -2)
        let body = String(normalized[..<bodyEnd])
        let checksum = String(normalized[bodyEnd...])
        guard checksum == checksumCharacters(for: body) else {
            throw InviteCodeError.badChecksum
        }

        return InviteCode(kind: kind, rawValue: chunked(normalized))
    }

    private static func checksumCharacters(for body: String) -> String {
        var hash = 2_166_136_261
        for scalar in body.unicodeScalars {
            hash ^= Int(scalar.value)
            hash = (hash &* 16_777_619) & 0x7fffffff
        }
        let base = alphabet.count
        return String([alphabet[(hash / base) % base], alphabet[hash % base]])
    }

    private static func chunked(_ value: String) -> String {
        value.enumerated().reduce(into: "") { result, pair in
            if pair.offset > 0, pair.offset.isMultiple(of: 4) {
                result.append("-")
            }
            result.append(pair.element)
        }
    }
}

enum InviteLinkResolver {
    static func makeLink(code: InviteCode, baseURL: URL = URL(string: "https://billbandit.app/invite")!) -> InviteLink {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "code", value: code.rawValue)]
        return InviteLink(url: components.url!, code: code)
    }

    static func resolve(_ url: URL) throws -> InviteCode {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            throw InviteCodeError.tooShort
        }
        return try InviteCode.parse(code)
    }
}

