@testable import AdaEditor
import Foundation
import Testing

struct MobileProviderCatalogTests {
    @Test
    func apiCatalogUsesConfiguredEndpointAndBearerHeader() throws {
        let request = try EditorProviderModelCatalog.apiRequest(baseURL: "https://example.test/v1/", apiKey: "test-key")
        #expect(request.url?.absoluteString == "https://example.test/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let defaultPath = try EditorProviderModelCatalog.apiRequest(baseURL: "https://example.test", apiKey: "test-key")
        #expect(defaultPath.url?.path == "/v1/models")
        #expect(throws: (any Error).self) {
            try EditorProviderModelCatalog.apiRequest(baseURL: "https://user:password@example.test/v1", apiKey: "test-key")
        }
        #expect(throws: (any Error).self) {
            try EditorProviderModelCatalog.apiRequest(baseURL: "http://example.test/v1", apiKey: "test-key")
        }
    }

    @Test
    func codexCatalogUsesAccountAndDecodesSlugs() throws {
        let request = try EditorProviderModelCatalog.codexRequest(accessToken: "test-token", accountID: "test-account")
        #expect(request.url?.host == "chatgpt.com")
        let components = try #require(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        #expect(components.queryItems?.first { $0.name == "client_version" }?.value == "0.158.0")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "test-account")
        let data = Data(#"{"models":[{"slug":"code-model","display_name":"Code model"},{"slug":"hidden-model","visibility":"hide"},{"slug":"code-model"}]}"#.utf8)
        #expect(try EditorProviderModelCatalog.decode(data) == [EditorProviderModel(id: "code-model", title: "Code model")])
    }

    @Test
    func loadsAPIModelsAndReportsAuthorizationFailure() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogStubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let request = try EditorProviderModelCatalog.apiRequest(baseURL: "https://example.test", apiKey: "test-key")
        let models = try await EditorProviderModelCatalog.fetch(request, session: session)
        #expect(models.map(\.id) == ["model-a", "model-b"])
        let denied = try EditorProviderModelCatalog.apiRequest(baseURL: "https://example.test/denied", apiKey: "test-key")
        await #expect(throws: (any Error).self) {
            try await EditorProviderModelCatalog.fetch(denied, session: session)
        }
    }

    @Test
    func emptyOrMalformedCatalogDoesNotInventModels() {
        #expect(throws: (any Error).self) { try EditorProviderModelCatalog.decode(Data(#"{"data":[]}"#.utf8)) }
        #expect(throws: (any Error).self) { try EditorProviderModelCatalog.decode(Data(#"{"message":"failure"}"#.utf8)) }
    }

    @Test
    func currentCodexCatalogPreservesEveryVisibleModel() throws {
        // Catalog shape observed with client_version=0.158.0, including internal hidden entries.
        let data = Data(#"""
        {"models":[
            {"slug":"gpt-6-astra","display_name":"GPT-6-Astra","visibility":"list"},
            {"slug":"gpt-6-sol","display_name":"GPT-6-Sol","visibility":"list"},
            {"slug":"gpt-6-luna","display_name":"GPT-6-Luna","visibility":"list"},
            {"slug":"gpt-reserve","visibility":"hide"},
            {"slug":"gpt-5.6-sol","visibility":"list"},
            {"slug":"gpt-5.6-terra","visibility":"list"},
            {"slug":"gpt-5.6-luna","visibility":"list"},
            {"slug":"gpt-5.5","visibility":"list"},
            {"slug":"codex-auto-review","visibility":"hide"}
        ]}
        """#.utf8)
        let models = try EditorProviderModelCatalog.decode(data)
        #expect(Set(models.map(\.id)) == ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"])
        #expect(EditorProviderModelCatalog.matching(models, query: "gpt").count == 7)
    }

    @Test
    func modelSearchMatchesTitlesAndIDsAndTrimsWhitespace() {
        let models = [EditorProviderModel(id: "code-a", title: "Fast model"), EditorProviderModel(id: "code-b", title: "Reasoning model")]
        #expect(EditorProviderModelCatalog.matching(models, query: "  FAST ").map(\.id) == ["code-a"])
        #expect(EditorProviderModelCatalog.matching(models, query: "CODE-B").map(\.id) == ["code-b"])
        #expect(EditorProviderModelCatalog.matching(models, query: " ") == models)
        #expect(EditorProviderModelCatalog.matching(models, query: "unknown").isEmpty)
    }
}

// Stateless URL loading fixture: each response is determined solely by the request URL.
private final class CatalogStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: url.path.contains("denied") ? 401 : 200, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":[{"id":"model-b"},{"id":"model-a"}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
struct MobileProjectManagementTests {
    @Test
    func renamePersistsIndexAndMetadataWithoutMovingFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileEditorProjectStore(directory: directory)
        let project = MobileEditorProject(id: UUID(), title: "Original", prompt: "Existing prompt", isExample: false)
        try store.save([project])
        let projectURL = directory.appendingPathComponent(project.id.uuidString)
        try FileManager.default.createDirectory(at: projectURL.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        let source = projectURL.appendingPathComponent("Sources/Game.ada")
        try "// preserved".write(to: source, atomically: true, encoding: .utf8)
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "Original", buildSystem: .adaScript), at: projectURL)

        let renamed = try store.rename(id: project.id, to: "  Renamed  ")
        #expect(renamed.first?.title == "Renamed")
        #expect(try store.load().first?.title == "Renamed")
        #expect(try ProjectSystem.loadProject(at: projectURL).project.name == "Renamed")
        #expect(try String(contentsOf: source, encoding: .utf8) == "// preserved")
        #expect(throws: (any Error).self) { try store.rename(id: project.id, to: "  ") }
        #expect(try store.load().first?.title == "Renamed")
    }

    @Test
    func deleteRemovesOnlySelectedProjectAndDoesNotRestoreExample() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileEditorProjectStore(directory: directory)
        let other = MobileEditorProject(id: UUID(), title: "Keep", prompt: nil, isExample: false)
        try store.save([.forest, other])
        let deletedURL = directory.appendingPathComponent(MobileEditorProject.forest.id.uuidString)
        let keptURL = directory.appendingPathComponent(other.id.uuidString)
        try FileManager.default.createDirectory(at: deletedURL.appendingPathComponent(".ada/workspace/agents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: keptURL, withIntermediateDirectories: true)
        #expect(try store.delete(id: MobileEditorProject.forest.id) == [other])
        #expect(!FileManager.default.fileExists(atPath: deletedURL.path))
        #expect(FileManager.default.fileExists(atPath: keptURL.path))
        #expect(try store.load() == [other])
        _ = try store.delete(id: other.id)
        #expect(try store.load().isEmpty)
    }
}
