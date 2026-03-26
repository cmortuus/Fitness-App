import Foundation

/// Central API client for all backend communication
actor APIClient {
    static let shared = APIClient()

    private let baseURL = "https://lethal.dev/api"
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            // Try ISO8601 with fractional seconds first
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: str) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: str) { return date }
            // Fallback: simple date
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            if let date = df.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date: \(str)")
        }

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
    }

    // MARK: - Core request method

    func request<T: Decodable>(
        _ method: String,
        path: String,
        body: Encodable? = nil,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> T {
        var components = URLComponents(string: "\(baseURL)\(path)")!
        if let queryItems { components.queryItems = queryItems }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Attach auth token
        if let token = AuthService.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.httpBody = try encoder.encode(AnyEncodable(body))
        }

        let (data, response) = try await session.data(for: request)
        let httpResponse = response as! HTTPURLResponse

        // Handle 401 — try refresh
        if httpResponse.statusCode == 401 {
            if await AuthService.shared.refreshTokens() {
                // Retry with new token
                if let newToken = AuthService.shared.accessToken {
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
        body: Encodable? = nil,
        queryItems: [URLQueryItem]? = nil
    ) async throws {
        var components = URLComponents(string: "\(baseURL)\(path)")!
        if let queryItems { components.queryItems = queryItems }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let token = AuthService.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.httpBody = try encoder.encode(AnyEncodable(body))
        }

        let (_, response) = try await session.data(for: request)
        let httpResponse = response as! HTTPURLResponse

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(httpResponse.statusCode, nil)
        }
    }

    // MARK: - Convenience

    func get<T: Decodable>(_ path: String, query: [URLQueryItem]? = nil) async throws -> T {
        try await request("GET", path: path, queryItems: query)
    }

    func post<T: Decodable>(_ path: String, body: Encodable? = nil) async throws -> T {
        try await request("POST", path: path, body: body)
    }

    func patch<T: Decodable>(_ path: String, body: Encodable? = nil) async throws -> T {
        try await request("PATCH", path: path, body: body)
    }

    func delete(_ path: String) async throws {
        try await requestVoid("DELETE", path: path)
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

// MARK: - Type erasure for Encodable

struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void

    init(_ wrapped: Encodable) {
        _encode = wrapped.encode
    }

    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}
