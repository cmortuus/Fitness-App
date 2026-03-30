import Foundation

/// Central API client for all backend communication
final class APIClient: Sendable {
    static let shared = APIClient()

    private let baseURL: String = {
        if let url = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String, !url.isEmpty {
            return url
        }
        return "https://lethal.dev/api"
    }()
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        // Route to the dev container via nginx cookie
        let cookie = HTTPCookie(properties: [
            .domain: "lethal.dev",
            .path: "/",
            .name: "gymtracker_branch",
            .value: "dev",
        ])!
        config.httpCookieStorage?.setCookie(cookie)
        session = URLSession(configuration: config)

        decoder = JSONDecoder()
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
    }

    // MARK: - Core request method

    func request<T: Decodable>(
        _ method: String,
        path: String,
        body: (any Encodable)? = nil,
        queryItems: [URLQueryItem]? = nil,
        skipAuth: Bool = false
    ) async throws -> T {
        guard var components = URLComponents(string: "\(baseURL)\(path)") else {
            throw APIError.httpError(0, "Invalid URL: \(path)")
        }
        if let queryItems { components.queryItems = queryItems }
        guard let url = components.url else {
            throw APIError.httpError(0, "Invalid URL components")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Attach auth token (access MainActor property)
        if !skipAuth {
            let token = await AuthService.shared.accessToken
            if let token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        }

        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: encodeToDictionary(body))
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.httpError(0, "Invalid response")
        }

        // Handle 401 — try refresh (but NOT for auth endpoints to prevent infinite loop)
        if httpResponse.statusCode == 401 && !skipAuth && !path.hasPrefix("/auth/") {
            let refreshed = await AuthService.shared.refreshTokens()
            if refreshed {
                let newToken = await AuthService.shared.accessToken
                if let newToken {
                    request.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                }
                let (retryData, retryResponse) = try await session.data(for: request)
                guard let retryHTTP = retryResponse as? HTTPURLResponse else {
                    throw APIError.httpError(0, "Invalid response")
                }
                guard (200...299).contains(retryHTTP.statusCode) else {
                    throw APIError.httpError(retryHTTP.statusCode, String(data: retryData, encoding: .utf8))
                }
                return try decoder.decode(T.self, from: retryData)
            } else {
                throw APIError.unauthorized
            }
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(httpResponse.statusCode, String(data: data, encoding: .utf8))
        }

        return try decoder.decode(T.self, from: data)
    }

    /// For requests that return no body (204, etc.)
    func requestVoid(
        _ method: String,
        path: String,
        body: (any Encodable)? = nil,
        queryItems: [URLQueryItem]? = nil
    ) async throws {
        guard var components = URLComponents(string: "\(baseURL)\(path)") else {
            throw APIError.httpError(0, "Invalid URL: \(path)")
        }
        if let queryItems { components.queryItems = queryItems }
        guard let url = components.url else {
            throw APIError.httpError(0, "Invalid URL components")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let token = await AuthService.shared.accessToken
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: encodeToDictionary(body))
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.httpError(0, "Invalid response")
        }

        // Handle 401 — try refresh (skip for auth endpoints to prevent infinite loop)
        if httpResponse.statusCode == 401 && !path.hasPrefix("/auth/") {
            if await AuthService.shared.refreshTokens() {
                if let newToken = await AuthService.shared.accessToken {
                    request.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                }
                let (_, retryResponse) = try await session.data(for: request)
                guard let retryHttp = retryResponse as? HTTPURLResponse else {
                    throw APIError.httpError(0, "Invalid response")
                }
                guard (200...299).contains(retryHttp.statusCode) else {
                    throw APIError.httpError(retryHttp.statusCode, nil)
                }
                return
            }
            await AuthService.shared.logout()
            throw APIError.unauthorized
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw APIError.httpError(httpResponse.statusCode, body)
        }
    }

    // MARK: - Convenience

    func get<T: Decodable>(_ path: String, query: [URLQueryItem]? = nil) async throws -> T {
        try await request("GET", path: path, queryItems: query)
    }

    func post<T: Decodable>(_ path: String, body: (any Encodable)? = nil, queryItems: [URLQueryItem]? = nil) async throws -> T {
        try await request("POST", path: path, body: body, queryItems: queryItems)
    }

    func put<T: Decodable>(_ path: String, body: (any Encodable)? = nil) async throws -> T {
        try await request("PUT", path: path, body: body)
    }

    func patch<T: Decodable>(_ path: String, body: (any Encodable)? = nil) async throws -> T {
        try await request("PATCH", path: path, body: body)
    }

    func delete(_ path: String) async throws {
        try await requestVoid("DELETE", path: path)
    }

    // MARK: - Encoding helper

    /// Encode any Encodable to a JSON-compatible dictionary using JSONEncoder
    private func encodeToDictionary(_ value: any Encodable) throws -> Any {
        let data = try encoder.encode(EncodableWrapper(value))
        return try JSONSerialization.jsonObject(with: data)
    }
}

// MARK: - Error types

enum APIError: LocalizedError {
    case unauthorized
    case httpError(Int, String?)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Session expired. Please log in again."
        case .httpError(let code, let body):
            return Self.friendlyMessage(code: code, body: body)
        case .decodingError:
            return "Something went wrong loading data. Please try again."
        }
    }

    /// Parse FastAPI/Pydantic validation errors into human-readable messages
    private static func friendlyMessage(code: Int, body: String?) -> String {
        guard let body, let data = body.data(using: .utf8) else {
            return friendlyStatus(code)
        }

        // Try parsing Pydantic validation error: {"detail": [{"msg": "...", "loc": [...]}]}
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Array of validation errors
            if let details = json["detail"] as? [[String: Any]] {
                let messages = details.compactMap { detail -> String? in
                    guard let msg = detail["msg"] as? String else { return nil }
                    // Clean up Pydantic messages
                    let clean = msg
                        .replacingOccurrences(of: "Input should be ", with: "Must be ")
                        .replacingOccurrences(of: "Value error, ", with: "")
                    // Get field name from loc array
                    if let loc = detail["loc"] as? [Any], let field = loc.last as? String {
                        let label = field.replacingOccurrences(of: "_", with: " ").capitalized
                        return "\(label): \(clean)"
                    }
                    return clean
                }
                if !messages.isEmpty { return messages.joined(separator: "\n") }
            }
            // Simple detail string: {"detail": "Not found"}
            if let detail = json["detail"] as? String {
                return detail
            }
        }

        return friendlyStatus(code)
    }

    private static func friendlyStatus(_ code: Int) -> String {
        switch code {
        case 400: return "Invalid request. Please check your input."
        case 401: return "Session expired. Please log in again."
        case 403: return "You don't have permission for this action."
        case 404: return "Not found."
        case 409: return "This item already exists."
        case 422: return "Please check your input and try again."
        case 429: return "Too many requests. Please wait a moment."
        case 500...599: return "Server error. Please try again later."
        default: return "Something went wrong. Please try again."
        }
    }
}

// MARK: - Type erasure for Encodable (Sendable-safe)

private struct EncodableWrapper: Encodable, @unchecked Sendable {
    private let wrapped: any Encodable

    init(_ wrapped: any Encodable) {
        self.wrapped = wrapped
    }

    func encode(to encoder: Encoder) throws {
        try wrapped.encode(to: encoder)
    }
}
