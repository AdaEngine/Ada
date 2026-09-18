import Foundation

#if canImport(Security)
    import Security
#endif

protocol EditorImageCredentialProviding: Sendable {
    func apiKey() async throws -> String
}

enum EditorImageCredentialError: Error, LocalizedError, Sendable {
    case missingAPIKey
    case keychainFailure(Int32)
    case unsupportedPlatform

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "OpenAI API key is not configured. Add it in Agent Settings or set OPENAI_API_KEY."
        case let .keychainFailure(status):
            "Keychain operation failed with status \(status)."
        case .unsupportedPlatform:
            "Secure credential storage is unavailable on this platform."
        }
    }
}

actor EditorOpenAIImageCredentialStore: EditorImageCredentialProviding {
    static let service = "org.adaengine.editor.openai-images"
    static let account = "default"

    func apiKey() throws -> String {
        if let stored = try read(), !stored.isEmpty {
            return stored
        }
        if let environmentKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !environmentKey.isEmpty {
            return environmentKey
        }
        throw EditorImageCredentialError.missingAPIKey
    }

    func save(_ apiKey: String) throws {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            try delete()
            return
        }

        #if canImport(Security)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: Self.account,
            ]
            let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if updateStatus == errSecSuccess {
                return
            }
            guard updateStatus == errSecItemNotFound else {
                throw EditorImageCredentialError.keychainFailure(updateStatus)
            }
            var createQuery = query
            createQuery[kSecValueData as String] = Data(value.utf8)
            let createStatus = SecItemAdd(createQuery as CFDictionary, nil)
            guard createStatus == errSecSuccess else {
                throw EditorImageCredentialError.keychainFailure(createStatus)
            }
        #else
            throw EditorImageCredentialError.unsupportedPlatform
        #endif
    }

    func delete() throws {
        #if canImport(Security)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: Self.account,
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw EditorImageCredentialError.keychainFailure(status)
            }
        #else
            throw EditorImageCredentialError.unsupportedPlatform
        #endif
    }

    private func read() throws -> String? {
        #if canImport(Security)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: Self.account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound {
                return nil
            }
            guard status == errSecSuccess, let data = result as? Data else {
                throw EditorImageCredentialError.keychainFailure(status)
            }
            return String(bytes: data, encoding: .utf8)
        #else
            return nil
        #endif
    }
}
