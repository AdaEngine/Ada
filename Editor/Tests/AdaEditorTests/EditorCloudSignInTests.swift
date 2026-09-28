import Foundation
import Testing

@testable import AdaEditor

@Suite("Cloud website sign-in")
@MainActor
struct EditorCloudSignInTests {
    @Test("Ordinary builds connect to production without external configuration")
    func defaultServer() {
        #expect(EditorCloudConfiguration.server(environment: nil, saved: nil, bundled: nil) == "https://cloud.adaengine.org")
        #expect(EditorCloudConfiguration.server(environment: "", saved: "  ", bundled: "$(ADA_CLOUD_API_URL)") == "https://cloud.adaengine.org")
    }

    @Test("Explicit Cloud configuration keeps its precedence and normalizes whitespace")
    func configuredServer() throws {
        let environment = EditorCloudConfiguration.server(
            environment: " https://environment.example/\n", saved: "https://saved.example", bundled: "https://bundle.example"
        )
        #expect(environment == "https://environment.example/")
        let saved = EditorCloudConfiguration.server(environment: " ", saved: "https://saved.example", bundled: "https://bundle.example")
        #expect(saved == "https://saved.example")
        #expect(EditorCloudConfiguration.server(environment: nil, saved: nil, bundled: "https://bundle.example") == "https://bundle.example")
        // Invalid explicit configuration must be rejected by sign-in, not silently replaced with another server.
        let invalid = EditorCloudConfiguration.server(environment: "http://untrusted.example", saved: nil, bundled: nil)
        let invalidURL = try #require(URL(string: invalid))
        #expect(!EditorCloudAccount.isAllowedCloudURL(invalidURL))
    }

    @Test("Only a matching one-time callback is accepted")
    func callbackValidation() throws {
        let code = String(repeating: "a", count: 43)
        let state = String(repeating: "b", count: 43)
        let callback = try #require(URL(string: "adaeditor://cloud/callback?code=\(code)&state=\(state)"))
        #expect(try EditorCloudAccount.exchangeCode(from: callback, expectedState: state) == code)
        for invalid in [
            "https://cloud/callback?code=\(code)&state=\(state)",
            "adaeditor://wrong/callback?code=\(code)&state=\(state)",
            "adaeditor://cloud/wrong?code=\(code)&state=\(state)",
            "adaeditor://cloud/callback?code=\(code)&state=wrong",
            "adaeditor://cloud/callback?code=\(code)&state=\(state)&state=\(state)",
            "adaeditor://cloud/callback?code=\(code)&code=\(code)&state=\(state)",
            "adaeditor://cloud/callback?access_token=secret&state=\(state)",
        ] {
            let url = try #require(URL(string: invalid))
            #expect(throws: (any Error).self) { try EditorCloudAccount.exchangeCode(from: url, expectedState: state) }
        }
    }
}
