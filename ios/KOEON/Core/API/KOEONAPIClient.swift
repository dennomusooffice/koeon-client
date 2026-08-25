import Foundation

enum APIClientError: LocalizedError, Sendable {
    case invalidResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Backend returned an invalid response."
        case let .http(status, message): "Backend HTTP \(status): \(message)"
        }
    }
}

protocol KOEONAPIClientProtocol: Sendable {
    func fixture() async throws -> FixtureResponse
    func enroll(_ request: EnrollmentRequest) async throws -> EnrollmentResponse
    func me() async throws -> MeResponse
    func join(_ request: JoinRequest) async throws -> JoinResponse
    func resume(_ request: ResumeRequest) async throws -> JoinResponse
    func leave(sessionId: String) async throws
    func acquireFloor(sessionId: String) async throws -> FloorResponse
    func renewFloor(sessionId: String, leaseId: String) async throws -> FloorResponse
    func releaseFloor(sessionId: String, leaseId: String) async throws -> FloorReleaseResponse
    func floorStatus(sessionId: String) async throws -> FloorResponse
    func registerPttToken(sessionId: String, channelId: String, token: String) async throws
    func unregisterPttToken(sessionId: String) async throws
    func logout() async throws
}

final class KOEONAPIClient: KOEONAPIClientProtocol, @unchecked Sendable {
    static let publicSafeBaseURL = URL(string: "https://example.invalid")!
    static let bundleConfigurationKey = "KOEONAPIBaseURL"

    static func configuredBaseURL(bundle: Bundle = .main) -> URL {
        resolveBaseURL(configuredValue: bundle.object(
            forInfoDictionaryKey: bundleConfigurationKey
        ) as? String)
    }

    static func resolveBaseURL(configuredValue: String?) -> URL {
        guard let value = configuredValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let url = components.url else {
            return publicSafeBaseURL
        }
        components.scheme = "https"
        return components.url ?? url
    }

    static func requestURL(baseURL: URL, path: String) -> URL {
        baseURL.appending(path: path)
    }

    private let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let credentialStore: any DeviceCredentialStoring

    init(
        baseURL: URL = KOEONAPIClient.configuredBaseURL(),
        session: URLSession = .shared,
        credentialStore: any DeviceCredentialStoring = KeychainDeviceCredentialStore()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.credentialStore = credentialStore
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.withFractionalSeconds.date(from: value)
                ?? ISO8601DateFormatter.standard.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid ISO-8601 date"
            )
        }
    }

    func fixture() async throws -> FixtureResponse {
        try await send(path: "/api/fixture", method: "GET", body: Optional<Data>.none)
    }

    func enroll(_ request: EnrollmentRequest) async throws -> EnrollmentResponse {
        try await send(path: "/api/auth/enroll", method: "POST", body: try encoder.encode(request), authenticated: false)
    }

    func me() async throws -> MeResponse {
        try await send(path: "/api/me", method: "GET", body: Optional<Data>.none)
    }

    func join(_ request: JoinRequest) async throws -> JoinResponse {
        try await send(path: "/api/join", method: "POST", body: try encoder.encode(request))
    }

    func resume(_ request: ResumeRequest) async throws -> JoinResponse {
        try await send(path: "/api/ptt/resume", method: "POST", body: try encoder.encode(request))
    }

    func leave(sessionId: String) async throws {
        let _: EmptyResponse = try await send(
            path: "/api/leave",
            method: "POST",
            body: try encoder.encode(SessionRequest(sessionId: sessionId))
        )
    }

    func acquireFloor(sessionId: String) async throws -> FloorResponse {
        try await send(
            path: "/api/floor/acquire",
            method: "POST",
            body: try encoder.encode(SessionRequest(sessionId: sessionId))
        )
    }

    func renewFloor(sessionId: String, leaseId: String) async throws -> FloorResponse {
        try await send(
            path: "/api/floor/renew",
            method: "POST",
            body: try encoder.encode(LeaseRequest(sessionId: sessionId, leaseId: leaseId))
        )
    }

    func releaseFloor(sessionId: String, leaseId: String) async throws -> FloorReleaseResponse {
        try await send(
            path: "/api/floor/release",
            method: "POST",
            body: try encoder.encode(LeaseRequest(sessionId: sessionId, leaseId: leaseId))
        )
    }

    func floorStatus(sessionId: String) async throws -> FloorResponse {
        var components = URLComponents(
            url: Self.requestURL(baseURL: baseURL, path: "/api/floor/status"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "sessionId", value: sessionId)]
        return try await send(url: components.url!, method: "GET", body: Optional<Data>.none)
    }

    func registerPttToken(sessionId: String, channelId: String, token: String) async throws {
        let _: EmptyResponse = try await send(
            path: "/api/device/ptt-token",
            method: "POST",
            body: try encoder.encode(PttTokenRegistrationRequest(
                sessionId: sessionId,
                channelId: channelId,
                token: token
            ))
        )
    }

    func unregisterPttToken(sessionId: String) async throws {
        let _: EmptyResponse = try await send(
            path: "/api/device/ptt-token",
            method: "DELETE",
            body: try encoder.encode(PttTokenUnregisterRequest(sessionId: sessionId))
        )
    }

    func logout() async throws {
        let _: EmptyResponse = try await send(
            path: "/api/auth/logout",
            method: "POST",
            body: Data("{}".utf8)
        )
    }

    private func send<Response: Decodable>(
        path: String,
        method: String,
        body: Data?,
        authenticated: Bool = true
    ) async throws -> Response {
        try await send(
            url: Self.requestURL(baseURL: baseURL, path: path),
            method: method,
            body: body,
            authenticated: authenticated
        )
    }

    private func send<Response: Decodable>(
        url: URL,
        method: String,
        body: Data?,
        authenticated: Bool = true
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        if authenticated, let credential = credentialStore.read() {
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
        guard (200 ... 299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8).map { String($0.prefix(240)) } ?? "No response body"
            throw APIClientError.http(http.statusCode, message)
        }
        if Response.self == EmptyResponse.self, data.isEmpty {
            return EmptyResponse() as! Response
        }
        return try decoder.decode(Response.self, from: data)
    }
}

private struct EmptyResponse: Codable {
    init() {}
}

private extension ISO8601DateFormatter {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let standard = ISO8601DateFormatter()
}
