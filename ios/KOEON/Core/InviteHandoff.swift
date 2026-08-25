import Foundation

enum InviteHandoffError: Error, Equatable {
    case invalidInput
}

enum InviteInputParser {
    private static let trustedScheme = "https"
    private static let trustedHost = "example.invalid"
    private static let trustedPath = "/join"

    static func parse(_ value: String) throws -> String {
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if isToken(input) { return input }
        guard let components = URLComponents(string: input),
              components.scheme == trustedScheme,
              components.host == trustedHost,
              components.port == nil,
              components.path == trustedPath,
              components.query == nil,
              components.user == nil,
              components.password == nil,
              let fragment = components.fragment,
              isToken(fragment)
        else { throw InviteHandoffError.invalidInput }
        return fragment
    }

    private static func isToken(_ value: String) -> Bool {
        value.count == 43 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0.value == 95 || $0.value == 45
        }
    }
}

enum EnrollmentCredential: Equatable {
    case token(String)
    case code(String)

    var token: String? { if case let .token(value) = self { value } else { nil } }
    var code: String? { if case let .code(value) = self { value } else { nil } }
}

enum EnrollmentInputParser {
    private static let alphabet = CharacterSet(charactersIn: "0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func parse(_ value: String) throws -> EnrollmentCredential {
        let normalized = value.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        if normalized.count == 10,
           normalized.unicodeScalars.allSatisfy({ alphabet.contains($0) }) {
            return .code(normalized)
        }
        return .token(try InviteInputParser.parse(value))
    }
}

/// Stateless by design: the raw token never becomes application or persisted state.
enum InviteDeepLinkRouter {
    static func route(_ url: URL) -> String? {
        try? InviteInputParser.parse(url.absoluteString)
    }
}
