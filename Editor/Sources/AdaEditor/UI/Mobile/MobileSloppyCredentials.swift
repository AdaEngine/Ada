#if os(iOS)
import Foundation
import Security
import UIKit

struct MobileSloppyCredentials: Codable, Sendable {
    var apiKey: String
    var model: String
    var apiURL: String

    static let defaultAPIURL = "https://api.openai.com/v1"

    init(apiKey: String = "", model: String = "", apiURL: String = Self.defaultAPIURL) {
        self.apiKey = apiKey
        self.model = model
        self.apiURL = apiURL
    }

    private enum CodingKeys: String, CodingKey { case apiKey, model, apiURL }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        apiKey = try values.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        apiURL = try values.decodeIfPresent(String.self, forKey: .apiURL) ?? Self.defaultAPIURL
    }
}

enum MobileSloppyCredentialStore {
    private static let service = "org.adaengine.editor.sloppy-runtime"
    private static let account = "openai-api"

    static func load() -> MobileSloppyCredentials? {
        guard let data = read(account: account) else { return nil }
        return try? JSONDecoder().decode(MobileSloppyCredentials.self, from: data)
    }

    static func save(_ credentials: MobileSloppyCredentials) throws {
        try write(try JSONEncoder().encode(credentials), account: account)
    }

    private static func read(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func write(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw MobileSloppyCredentialError.keychain(status) }
        var create = query
        create[kSecValueData as String] = data
        create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let createStatus = SecItemAdd(create as CFDictionary, nil)
        guard createStatus == errSecSuccess else { throw MobileSloppyCredentialError.keychain(createStatus) }
    }
}

struct MobileCodexDeviceCode: Sendable {
    let deviceAuthID: String
    let userCode: String
    let verificationURL: URL
    let interval: Int
    let expiresIn: Int
}

struct MobileCodexCredentials: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var accountID: String?

    private enum CodingKeys: String, CodingKey { case accessToken, refreshToken, accountID }
}

enum MobileCodexCredentialStore {
    private static let service = "org.adaengine.editor.codex"
    private static let account = "openai-oauth"

    static func load() -> MobileCodexCredentials? {
        guard let data = read() else { return nil }
        return try? JSONDecoder().decode(MobileCodexCredentials.self, from: data)
    }

    static func save(_ credentials: MobileCodexCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw MobileSloppyCredentialError.keychain(status) }
        var create = query
        create[kSecValueData as String] = data
        create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let createStatus = SecItemAdd(create as CFDictionary, nil)
        guard createStatus == errSecSuccess else { throw MobileSloppyCredentialError.keychain(createStatus) }
    }

    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MobileSloppyCredentialError.keychain(status) }
    }

    private static func read() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}

enum MobileCodexOAuth {
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let deviceCodeURL = "https://auth.openai.com/api/accounts/deviceauth/usercode"
    private static let deviceTokenURL = "https://auth.openai.com/api/accounts/deviceauth/token"
    private static let tokenURL = "https://auth.openai.com/oauth/token"
    private static let redirectURI = "https://auth.openai.com/deviceauth/callback"

    private struct PollResponse: Decodable {
        let authorizationCode: String
        let codeVerifier: String
        enum CodingKeys: String, CodingKey {
            case authorizationCode = "authorization_code"
            case codeVerifier = "code_verifier"
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
        }
    }

    static func start() async throws -> MobileCodexDeviceCode {
        guard let deviceCodeURL = URL(string: deviceCodeURL) else {
            throw MobileSloppyCredentialError.authorization("OpenAI device authorization URL is invalid.")
        }
        var request = URLRequest(url: deviceCodeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": clientID])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw MobileSloppyCredentialError.authorization("OpenAI returned an invalid device authorization response.")
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = response.statusCode == 404
                ? "OpenAI device login is unavailable. Enable device login in ChatGPT security settings and try again."
                : "Could not start Codex sign-in (HTTP \(response.statusCode)). Check the network and try again."
            throw MobileSloppyCredentialError.authorization(message)
        }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MobileSloppyCredentialError.authorization("OpenAI returned an invalid device-code response.")
        }
        guard let deviceAuthID = (result["device_auth_id"] as? String ?? result["deviceAuthId"] as? String), !deviceAuthID.isEmpty,
              let userCode = (result["user_code"] as? String ?? result["userCode"] as? String), !userCode.isEmpty else {
            throw MobileSloppyCredentialError.authorization("OpenAI did not return a device code. Enable device login in ChatGPT security settings and try again.")
        }

        let verificationURLText = (result["verification_url"] as? String)
            ?? (result["verification_uri"] as? String)
            ?? (result["verificationURL"] as? String)
            ?? (result["verificationURI"] as? String)
            ?? "https://auth.openai.com/codex/device"
        guard let verificationURL = URL(string: verificationURLText) else {
            throw MobileSloppyCredentialError.authorization("OpenAI returned an invalid verification URL.")
        }
        return MobileCodexDeviceCode(
            deviceAuthID: deviceAuthID,
            userCode: userCode,
            verificationURL: verificationURL,
            interval: integerValue(result["interval"]) ?? 5,
            expiresIn: integerValue(result["expires_in"] ?? result["expiresIn"]) ?? 600
        )
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    static func poll(_ device: MobileCodexDeviceCode) async throws -> Bool {
        guard let deviceTokenURL = URL(string: deviceTokenURL), let tokenURL = URL(string: tokenURL) else {
            throw MobileSloppyCredentialError.authorization("OpenAI authorization URL is invalid.")
        }
        var request = URLRequest(url: deviceTokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_auth_id": device.deviceAuthID,
            "user_code": device.userCode,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw MobileSloppyCredentialError.authorization("OpenAI returned an invalid device authorization response.")
        }
        if response.statusCode == 403 || response.statusCode == 404 { return false }
        guard (200..<300).contains(response.statusCode) else {
            if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: String], payload["error"] == "authorization_pending" {
                return false
            }
            throw MobileSloppyCredentialError.authorization("Codex sign-in failed (HTTP \(response.statusCode)).")
        }
        let code = try JSONDecoder().decode(PollResponse.self, from: data)
        var tokenRequest = URLRequest(url: tokenURL)
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        tokenRequest.httpBody = formEncoded([
            "grant_type": "authorization_code",
            "code": code.authorizationCode,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": code.codeVerifier,
        ])
        let (tokenData, tokenResponse) = try await URLSession.shared.data(for: tokenRequest)
        guard let tokenResponse = tokenResponse as? HTTPURLResponse, (200..<300).contains(tokenResponse.statusCode) else {
            throw MobileSloppyCredentialError.authorization("Could not complete Codex sign-in.")
        }
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: tokenData)
        try MobileCodexCredentialStore.save(MobileCodexCredentials(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            accountID: accountID(from: tokens.accessToken)
        ))
        return true
    }

    static func refresh(force: Bool) async throws {
        guard let credentials = MobileCodexCredentialStore.load(),
              let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else { return }
        if !force, !tokenNeedsRefresh(credentials.accessToken) { return }
        guard let tokenURL = URL(string: tokenURL) else {
            throw MobileSloppyCredentialError.authorization("OpenAI token URL is invalid.")
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
            "scope": "openid profile email offline_access",
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw MobileSloppyCredentialError.authorization("Codex session expired. Sign in again from Settings.")
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        try MobileCodexCredentialStore.save(MobileCodexCredentials(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken ?? refreshToken,
            accountID: accountID(from: token.accessToken) ?? credentials.accountID
        ))
    }

    private static func tokenNeedsRefresh(_ token: String) -> Bool {
        guard let claims = jwtClaims(token),
              let expiry = claims["exp"] as? TimeInterval else { return false }
        return expiry <= Date().timeIntervalSince1970 + 60
    }

    private static func accountID(from token: String) -> String? {
        guard let claims = jwtClaims(token),
              let auth = claims["https://api.openai.com/auth"] as? [String: Any] else { return nil }
        return auth["chatgpt_account_id"] as? String
    }

    private static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        let encodedPayload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let payload = Data(base64Encoded: encodedPayload.padding(toMultipleOf: 4, with: "=")),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              !claims.isEmpty else { return nil }
        return claims
    }

    private static func formEncoded(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = values.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}

private extension String {
    func padding(toMultipleOf multiple: Int, with character: Character) -> String {
        let remainder = count % multiple
        return remainder == 0 ? self : self + String(repeating: character, count: multiple - remainder)
    }
}

enum MobileSloppyCredentialError: Error, LocalizedError {
    case keychain(OSStatus)
    case authorization(String)

    var errorDescription: String? {
        switch self {
        case .keychain(let status): "Could not save agent credentials (\(status))."
        case .authorization(let message): message
        }
    }
}

@MainActor
enum MobileSloppyAPIKeyPrompt {
    static func present(currentValue: String, completion: @escaping @MainActor (String) -> Void) {
        let alert = UIAlertController(title: "OpenAI API key", message: "The key is stored in the device Keychain.", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "API_KEY"
            field.isSecureTextEntry = true
            field.textContentType = .password
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.text = currentValue
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { _ in
            completion(alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        })
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.keyWindow,
              var presenter = window.rootViewController else { return }
        while let presented = presenter.presentedViewController { presenter = presented }
        presenter.present(alert, animated: true)
    }
}

@MainActor
enum MobileSloppyPromptComposer {
    static func present(initialValue: String, completion: @escaping @MainActor (String) -> Void) {
        let alert = UIAlertController(title: "New request", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Describe your game or next change"
            field.autocapitalizationType = .sentences
            field.autocorrectionType = .yes
            field.text = initialValue
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Use request", style: .default) { _ in
            completion(alert.textFields?.first?.text ?? "")
        })

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.keyWindow,
              var presenter = window.rootViewController else { return }
        while let presented = presenter.presentedViewController { presenter = presented }
        presenter.present(alert, animated: true)
    }
}
#endif
