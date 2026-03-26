import Foundation
import Security

/// Handles authentication — login, signup, token storage, and refresh
@MainActor
class AuthService: ObservableObject {
    static let shared = AuthService()

    @Published var isAuthenticated = false
    @Published var currentUser: User?

    private(set) var accessToken: String?
    private var refreshToken: String?

    private let accessTokenKey = "dev.lethal.gymtracker.access_token"
    private let refreshTokenKey = "dev.lethal.gymtracker.refresh_token"

    private init() {
        // Load tokens from Keychain
        accessToken = KeychainHelper.load(key: accessTokenKey)
        refreshToken = KeychainHelper.load(key: refreshTokenKey)
        isAuthenticated = accessToken != nil
    }

    // MARK: - Login

    func login(username: String, password: String) async throws {
        struct LoginRequest: Encodable {
            let username: String
            let password: String
        }

        struct LoginResponse: Decodable {
            let access_token: String
            let refresh_token: String
            let user: User
        }

        let response: LoginResponse = try await APIClient.shared.post(
            "/auth/login",
            body: LoginRequest(username: username, password: password)
        )

        saveTokens(access: response.access_token, refresh: response.refresh_token)
        currentUser = response.user
        isAuthenticated = true
    }

    // MARK: - Signup

    func signup(username: String, password: String) async throws {
        struct SignupRequest: Encodable {
            let username: String
            let password: String
        }

        struct SignupResponse: Decodable {
            let access_token: String
            let refresh_token: String
            let user: User
        }

        let response: SignupResponse = try await APIClient.shared.post(
            "/auth/signup",
            body: SignupRequest(username: username, password: password)
        )

        saveTokens(access: response.access_token, refresh: response.refresh_token)
        currentUser = response.user
        isAuthenticated = true
    }

    // MARK: - Refresh

    func refreshTokens() async -> Bool {
        guard let refresh = refreshToken else { return false }

        struct RefreshRequest: Encodable {
            let refresh_token: String
        }

        struct RefreshResponse: Decodable {
            let access_token: String
            let refresh_token: String
        }

        do {
            let response: RefreshResponse = try await APIClient.shared.post(
                "/auth/refresh",
                body: RefreshRequest(refresh_token: refresh)
            )
            saveTokens(access: response.access_token, refresh: response.refresh_token)
            return true
        } catch {
            logout()
            return false
        }
    }

    // MARK: - Logout

    func logout() {
        accessToken = nil
        refreshToken = nil
        currentUser = nil
        isAuthenticated = false
        KeychainHelper.delete(key: accessTokenKey)
        KeychainHelper.delete(key: refreshTokenKey)
    }

    // MARK: - Private

    private func saveTokens(access: String, refresh: String) {
        accessToken = access
        refreshToken = refresh
        KeychainHelper.save(key: accessTokenKey, value: access)
        KeychainHelper.save(key: refreshTokenKey, value: refresh)
    }
}

// MARK: - Keychain Helper

enum KeychainHelper {
    static func save(key: String, value: String) {
        let data = value.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary) // Remove old

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
