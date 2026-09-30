#if os(iOS)
    import Foundation

    struct MobileEditorImageCredentials: EditorImageCredentialProviding {
        func apiKey() async throws -> String {
            do { return try await EditorOpenAIImageCredentialStore().apiKey() } catch EditorImageCredentialError.missingAPIKey {
                if let credentials = await MainActor.run(body: { MobileSloppyCredentialStore.load() }),
                    credentials.provider == .api, URL(string: credentials.apiURL)?.host == "api.openai.com", !credentials.apiKey.isEmpty {
                    return credentials.apiKey
                }
                throw EditorImageCredentialError.missingAPIKey
            }
        }
    }
#endif
