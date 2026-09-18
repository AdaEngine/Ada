import Foundation
import Testing

@testable import AdaEditor

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("Editor agent image tools")
struct EditorAgentImageToolTests {
    @Test("image generation configuration decodes defaults and explicit values")
    func projectConfiguration() throws {
        let defaults = try ProjectSystem.loadProject(from: Data(#"{"schemaVersion":3}"#.utf8))
        #expect(defaults.ai.imageGeneration == AdaProjectImageGeneration())

        let configured = try ProjectSystem.loadProject(
            from: Data(
                """
                {
                  "schemaVersion": 3,
                  "ai": {
                    "imageGeneration": {
                      "enabled": true,
                      "provider": "openai",
                      "model": "gpt-image-2",
                      "size": "1536x1024",
                      "quality": "high",
                      "background": "opaque",
                      "outputFormat": "webp"
                    }
                  }
                }
                """
                .utf8
            )
        )

        #expect(configured.ai.imageGeneration.enabled)
        #expect(configured.ai.imageGeneration.size == "1536x1024")
        #expect(configured.ai.imageGeneration.quality == "high")
        #expect(configured.ai.imageGeneration.outputFormat == "webp")
    }

    @Test("OpenAI generation writes a validated project asset")
    func generateImage() async throws {
        let fixture = try makeFixture(named: "Generate")
        defer { try? FileManager.default.removeItem(at: fixture.projectURL) }
        let png = validPNGData
        let client = RecordingImageHTTPClient(responses: [.success(png)])
        let service = EditorAgentImageToolService(
            project: fixture.project,
            projectURL: fixture.projectURL,
            credentials: FixedImageCredentials(apiKey: "test-key"),
            httpClient: client,
            endpointBaseURL: URL(string: "https://openai.test/v1") ?? fixture.projectURL
        )

        let result = try await service.generate(prompt: "A blue crystal", destinationPath: "Textures/crystal")

        #expect(result.relativePath == "Assets/Textures/crystal.png")
        #expect(result.assetReference == "@res://Textures/crystal.png")
        #expect(result.mimeType == "image/png")
        #expect(try Data(contentsOf: fixture.projectURL.appendingPathComponent(result.relativePath)) == png)
        let request = try #require(await client.recordedRequests().first)
        #expect(request.url?.path == "/v1/images/generations")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["model"] as? String == "gpt-image-2")
        #expect(object["quality"] as? String == "medium")
        #expect(object["background"] as? String == "transparent")
    }

    @Test("OpenAI editing uploads the source image and does not overwrite by default")
    func editImageAndRejectOverwrite() async throws {
        let fixture = try makeFixture(named: "Edit")
        defer { try? FileManager.default.removeItem(at: fixture.projectURL) }
        let sourceURL = fixture.projectURL.appendingPathComponent("Assets/source.png")
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try validPNGData.write(to: sourceURL)
        let client = RecordingImageHTTPClient(responses: [.success(validPNGData)])
        let service = EditorAgentImageToolService(
            project: fixture.project,
            projectURL: fixture.projectURL,
            credentials: FixedImageCredentials(apiKey: "test-key"),
            httpClient: client,
            endpointBaseURL: URL(string: "https://openai.test/v1") ?? fixture.projectURL
        )

        let result = try await service.edit(
            prompt: "Add a gold outline",
            sourcePath: "Assets/source.png",
            destinationPath: "Textures/outlined.png"
        )
        #expect(result.assetReference == "@res://Textures/outlined.png")
        let request = try #require(await client.recordedRequests().first)
        #expect(request.url?.path == "/v1/images/edits")
        let body = try #require(String(bytes: try #require(request.httpBody), encoding: .utf8))
        #expect(body.contains("name=\"image\"; filename=\"source.png\""))
        #expect(body.contains("Add a gold outline"))

        await #expect(throws: EditorAgentImageToolError.destinationExists("Assets/Textures/outlined.png")) {
            try await service.generate(prompt: "Replacement", destinationPath: "Textures/outlined.png")
        }
        #expect(await client.recordedRequests().count == 1)
    }

    @Test("provider errors and invalid image bytes are surfaced without files")
    func rejectsProviderFailureAndInvalidData() async throws {
        let fixture = try makeFixture(named: "Errors")
        defer { try? FileManager.default.removeItem(at: fixture.projectURL) }
        let client = RecordingImageHTTPClient(responses: [
            .failure(statusCode: 400, message: "bad prompt"),
            .success(Data("not an image".utf8)),
        ])
        let service = EditorAgentImageToolService(
            project: fixture.project,
            projectURL: fixture.projectURL,
            credentials: FixedImageCredentials(apiKey: "test-key"),
            httpClient: client,
            endpointBaseURL: URL(string: "https://openai.test/v1") ?? fixture.projectURL
        )

        await #expect(throws: EditorAgentImageToolError.requestFailed(statusCode: 400, message: "bad prompt")) {
            try await service.generate(prompt: "Bad", destinationPath: "bad.png")
        }
        await #expect(throws: EditorAgentImageToolError.invalidImageFormat("png")) {
            try await service.generate(prompt: "Invalid", destinationPath: "invalid.png")
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.projectURL.appendingPathComponent("Assets/invalid.png").path))
    }

    private var validPNGData: Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x00])
    }

    private func makeFixture(named name: String) throws -> (projectURL: URL, project: AdaProject) {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorAgentImageToolTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let project = AdaProject(
            schemaVersion: ProjectSystem.currentSchemaVersion,
            paths: AdaProjectPaths(assets: "Assets"),
            ai: AdaProjectAI(imageGeneration: AdaProjectImageGeneration(enabled: true))
        )
        return (projectURL, project)
    }
}

private struct FixedImageCredentials: EditorImageCredentialProviding {
    var key: String

    init(apiKey: String) {
        self.key = apiKey
    }

    func apiKey() -> String {
        key
    }
}

private actor RecordingImageHTTPClient: EditorImageGenerationHTTPClient {
    enum Response: Sendable {
        case success(Data)
        case failure(statusCode: Int, message: String)
    }

    private var responses: [Response]
    private var requests: [URLRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses.removeFirst()
        let statusCode: Int
        let data: Data
        switch response {
        case let .success(imageData):
            statusCode = 200
            data = Data("{\"data\":[{\"b64_json\":\"\(imageData.base64EncodedString())\"}]}".utf8)
        case let .failure(code, message):
            statusCode = code
            data = Data("{\"error\":{\"message\":\"\(message)\"}}".utf8)
        }
        guard
            let response = HTTPURLResponse(
                url: request.url ?? URL(fileURLWithPath: "/"),
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )
        else {
            throw EditorAgentImageToolError.invalidHTTPResponse
        }
        return (data, response)
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}
