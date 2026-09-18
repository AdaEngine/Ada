import Foundation
import Testing

@testable import AdaEditor

@Suite("Cloud website sign-in")
@MainActor
struct EditorCloudSignInTests {
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
