import Foundation

/// Central API client for all backend communication
final class APIClient: Sendable {
    static let shared = APIClient()

    private let baseURL = "https://lethal.dev/api"
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
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
        queryItems: [URLQueryItem]? = nil
    ) async throws -> T {
        var components = URLComponents(string: "\(baseURL)\(path)")!
        if let queryItems { components.queryItems = queryItems }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Attach auth token (access MainActor property)
        let token = await AuthService.shared.accessToken
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: encodeToDictionary(body))
        }

        let (data, response) = try await session.data(for: request)
        let httpResponse = response as! HTTPURLResponse

        // Handle 401 — try refresh
        if httpResponse.statusCode == 401 {
            let refreshed = await AuthService.shared.refreshTokens()
            if refreshed {
                let newToken = await AuthService.shared.accessToken
                if let newToken {
                    request.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                }
                let (retryData, retryResponse) = try await session.data(for: request)
                let retryHTTP = retryResponse as! HTTPURLResponse
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
        var components = URLComponents(string: "\(baseURL)\(path)")!
        if let queryItems { components.queryItems = queryItems }

        var request = URLRequest(url: components.url!)
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
        let httpResponse = response as! HTTPURLResponse

        // Handle 401 — try refresh
        if httpResponse.statusCode == 401 {
            if await AuthService.shared.refreshTokens() {
                if let newToken = await AuthService.shared.accessToken {
                    request.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                }
                let (_, retryResponse) = try await session.data(for: request)
                let retryHttp = retryResponse as! HTTPURLResponse
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
        case .unauthorized: return "Session expired. Please log in again."
        case .httpError(let code, let body): return "Server error (\(code)): \(body ?? "Unknown")"
        case .decodingError(let error): return "Data error: \(error.localizedDescription)"
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
