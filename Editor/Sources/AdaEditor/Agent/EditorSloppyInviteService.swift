import Foundation

#if canImport(Security)
    import Security
#endif

struct EditorSloppyInviteCredentials: Codable, Sendable {
    let serverURL: URL
    let login: String
    let accessToken: String
    let refreshToken: String
}

struct EditorSloppyAccount: Sendable {
    let serverURL: URL
    let login: String
}

struct EditorSloppyInviteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

actor EditorSloppyInviteService {
    static let shared = EditorSloppyInviteService()
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func registeredAccounts() -> [EditorSloppyAccount] {
        #if canImport(Security)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "org.adaengine.editor.sloppy",
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnData as String: true,
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let records = result as? [Data] else { return [] }
            return records.compactMap { try? JSONDecoder().decode(EditorSloppyInviteCredentials.self, from: $0) }
                .map { EditorSloppyAccount(serverURL: $0.serverURL, login: $0.login) }
        #else
            return []
        #endif
    }

    static func serverURL(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.scheme == "https" || (components.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
        else {
            throw EditorSloppyInviteError(message: "Enter an HTTPS Sloppy Core URL (HTTP is allowed for localhost).")
        }
        return url
    }

    func register(server: String, invite: String, name: String, login: String, password: String) async throws -> EditorSloppyInviteCredentials {
        let url = try Self.serverURL(server)
        let trimmedInvite = invite.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLogin = login.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedInvite.hasPrefix("slp_inv_"), !trimmedName.isEmpty, !trimmedLogin.isEmpty, !password.isEmpty else {
            throw EditorSloppyInviteError(message: "Enter your name, login, password, and a Sloppy user invite beginning with slp_inv_.")
        }
        struct Registration: Encodable {
            let inviteToken: String
            let login: String
            let password: String
            let name: String
        }
        struct Session: Decodable {
            let accessToken: String
            let refreshToken: String
        }
        var request = URLRequest(url: url.appendingPathComponent("v1/auth/register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Registration(inviteToken: trimmedInvite, login: trimmedLogin, password: password, name: trimmedName))
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 201 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw EditorSloppyInviteError(message: "Sloppy rejected the invite registration (HTTP \(status)). Check the server and invite.")
        }
        let result = try JSONDecoder().decode(Session.self, from: data)
        let credentials = EditorSloppyInviteCredentials(serverURL: url, login: trimmedLogin, accessToken: result.accessToken, refreshToken: result.refreshToken)
        try save(credentials)
        return credentials
    }

    private func save(_ credentials: EditorSloppyInviteCredentials) throws {
        #if canImport(Security)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "org.adaengine.editor.sloppy",
                kSecAttrAccount as String: credentials.serverURL.absoluteString + "|" + credentials.login,
            ]
            let data = try JSONEncoder().encode(credentials)
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecSuccess { return }
            guard status == errSecItemNotFound else {
                throw EditorSloppyInviteError(message: "Could not save the Sloppy session in Keychain (\(status)).")
            }
            var create = query
            create[kSecValueData as String] = data
            create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let createStatus = SecItemAdd(create as CFDictionary, nil)
            guard createStatus == errSecSuccess else {
                throw EditorSloppyInviteError(message: "Could not save the Sloppy session in Keychain (\(createStatus)).")
            }
        #else
            throw EditorSloppyInviteError(message: "Keychain storage is unavailable on this platform.")
        #endif
    }
}
