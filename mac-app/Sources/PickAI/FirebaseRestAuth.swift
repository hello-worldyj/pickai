import Foundation
import Security

/// Talks to Firebase's Identity Toolkit REST API directly instead of using the FirebaseAuth
/// SDK. The SDK itself requires a `keychain-access-groups` entitlement for session
/// persistence — a "restricted" entitlement that macOS's AMFI refuses to honor without a
/// real Apple Developer provisioning profile, which this self-signed local build doesn't
/// have. The REST API issues the exact same kind of ID token either way (the backend
/// verifies it the same way regardless of how it was obtained), so this sidesteps the
/// SDK's keychain requirement entirely rather than needing paid Apple Developer signing.
enum FirebaseRestAuth {
    private static let apiKey = "AIzaSyAvmy-Zrwm5izK3CJvK5hB6OngEC9RgynI"

    private static let keychainService = "com.pickai.app.firebaseauth"
    private static let keychainAccount = "refreshToken"

    private struct SignInResponse: Decodable {
        let idToken: String
        let refreshToken: String
        let expiresIn: String
        let email: String
    }

    private struct RefreshResponse: Decodable {
        let id_token: String
        let refresh_token: String
        let expires_in: String
    }

    private struct RestError: Decodable {
        struct Inner: Decodable { let message: String }
        let error: Inner
    }

    enum AuthError: Error {
        case invalidCredentials
        case other(String)
    }

    private static var cachedIDToken: String?
    private static var cachedIDTokenExpiry: Date?
    private(set) static var currentUserEmail: String?

    static var isSignedIn: Bool {
        loadRefreshToken() != nil
    }

    static func signIn(email: String, password: String) async throws {
        let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "email": email, "password": password, "returnSecureToken": "true",
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            if let restError = try? JSONDecoder().decode(RestError.self, from: data) {
                throw AuthError.other(restError.error.message)
            }
            throw AuthError.invalidCredentials
        }

        let decoded = try JSONDecoder().decode(SignInResponse.self, from: data)
        saveRefreshToken(decoded.refreshToken)
        currentUserEmail = decoded.email
        cachedIDToken = decoded.idToken
        cachedIDTokenExpiry = Date().addingTimeInterval((Double(decoded.expiresIn) ?? 3600) - 60)
    }

    static func signOut() {
        deleteRefreshToken()
        cachedIDToken = nil
        cachedIDTokenExpiry = nil
        currentUserEmail = nil
    }

    /// Returns a fresh ID token, refreshing via the stored refresh token if the cached one
    /// has expired (or this is a fresh launch with nothing cached in memory yet).
    static func currentIDToken() async throws -> String? {
        if let cachedIDToken, let cachedIDTokenExpiry, cachedIDTokenExpiry > Date() {
            return cachedIDToken
        }
        guard let refreshToken = loadRefreshToken() else { return nil }

        let url = URL(string: "https://securetoken.googleapis.com/v1/token?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "grant_type=refresh_token&refresh_token=\(refreshToken)".data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            // A rejected refresh token means the session is genuinely over (revoked/expired) —
            // clear it so the app falls back to the login screen instead of retrying forever.
            signOut()
            return nil
        }

        let decoded = try JSONDecoder().decode(RefreshResponse.self, from: data)
        saveRefreshToken(decoded.refresh_token)
        cachedIDToken = decoded.id_token
        cachedIDTokenExpiry = Date().addingTimeInterval((Double(decoded.expires_in) ?? 3600) - 60)
        return decoded.id_token
    }

    // MARK: - Plain Keychain storage (no access group — works without any entitlement,
    // unlike the SDK's internal storage).

    private static func saveRefreshToken(_ token: String) {
        deleteRefreshToken()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: Data(token.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func loadRefreshToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteRefreshToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
