import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

protocol EditorImageGenerationHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct EditorImageHTTPClient: EditorImageGenerationHTTPClient {
    var session: URLSession = .shared

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw EditorAgentImageToolError.invalidHTTPResponse
        }
        return (data, response)
    }
}

struct EditorGeneratedImageAsset: Equatable, Sendable {
    var relativePath: String
    var assetReference: String
    var mimeType: String
    var data: Data
}

enum EditorAgentImageToolError: Error, Equatable, LocalizedError, Sendable {
    case disabled
    case unsupportedProvider(String)
    case invalidDestination(String)
    case invalidSource(String)
    case destinationExists(String)
    case invalidHTTPResponse
    case requestFailed(statusCode: Int, message: String)
    case missingImageData
    case invalidBase64Image
    case invalidImageFormat(String)

    var errorDescription: String? {
        switch self {
        case .disabled:
            "Image generation is disabled for this project."
        case let .unsupportedProvider(provider):
            "Unsupported image generation provider: \(provider)"
        case let .invalidDestination(path):
            "Invalid generated image destination: \(path)"
        case let .invalidSource(path):
            "Invalid source image path: \(path)"
        case let .destinationExists(path):
            "Generated image destination already exists: \(path)"
        case .invalidHTTPResponse:
            "Image provider returned a non-HTTP response."
        case let .requestFailed(statusCode, message):
            "Image provider request failed (HTTP \(statusCode)): \(message)"
        case .missingImageData:
            "Image provider response did not contain image data."
        case .invalidBase64Image:
            "Image provider returned invalid base64 image data."
        case let .invalidImageFormat(format):
            "Image provider returned data that is not a valid \(format) image."
        }
    }
}

actor EditorAgentImageToolService {
    private struct OpenAIImageResponse: Decodable {
        struct Item: Decodable {
            var base64JSON: String?

            private enum CodingKeys: String, CodingKey {
                case base64JSON = "b64_json"
            }
        }

        var data: [Item]?
    }

    private struct OpenAIErrorResponse: Decodable {
        struct APIError: Decodable {
            var message: String
        }

        var error: APIError
    }

    private let project: AdaProject
    private let projectURL: URL
    private let credentials: any EditorImageCredentialProviding
    private let httpClient: any EditorImageGenerationHTTPClient
    private let endpointBaseURL: URL
    private let fileManager: FileManager

    init(
        project: AdaProject,
        projectURL: URL,
        credentials: any EditorImageCredentialProviding = EditorOpenAIImageCredentialStore(),
        httpClient: any EditorImageGenerationHTTPClient = EditorImageHTTPClient(),
        endpointBaseURL: URL = URL(string: "https://api.openai.com/v1") ?? URL(fileURLWithPath: "/"),
        fileManager: FileManager = .default
    ) {
        self.project = project
        self.projectURL = projectURL.standardizedFileURL
        self.credentials = credentials
        self.httpClient = httpClient
        self.endpointBaseURL = endpointBaseURL
        self.fileManager = fileManager
    }

    func generate(prompt: String, destinationPath: String, allowsOverwrite: Bool = false) async throws -> EditorGeneratedImageAsset {
        try validateConfiguration()
        let configuration = project.ai.imageGeneration
        let apiKey = try await credentials.apiKey()
        let body: [String: Any] = [
            "model": configuration.model,
            "prompt": prompt,
            "n": 1,
            "size": configuration.size,
            "quality": configuration.quality,
            "background": configuration.background,
            "output_format": configuration.outputFormat,
        ]
        var request = URLRequest(url: endpointBaseURL.appendingPathComponent("images/generations"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return try await perform(request, destinationPath: destinationPath, allowsOverwrite: allowsOverwrite)
    }

    func edit(
        prompt: String,
        sourcePath: String,
        destinationPath: String,
        allowsOverwrite: Bool = false
    ) async throws -> EditorGeneratedImageAsset {
        try validateConfiguration()
        let configuration = project.ai.imageGeneration
        let sourceURL = try resolvedSourceURL(sourcePath)
        let sourceData = try Data(contentsOf: sourceURL)
        let apiKey = try await credentials.apiKey()
        let boundary = "AdaEditor-\(UUID().uuidString)"
        var request = URLRequest(url: endpointBaseURL.appendingPathComponent("images/edits"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            fields: [
                "model": configuration.model,
                "prompt": prompt,
                "size": configuration.size,
                "quality": configuration.quality,
                "background": configuration.background,
                "output_format": configuration.outputFormat,
            ],
            imageData: sourceData,
            fileName: sourceURL.lastPathComponent,
            mimeType: Self.mimeType(forExtension: sourceURL.pathExtension)
        )
        return try await perform(request, destinationPath: destinationPath, allowsOverwrite: allowsOverwrite)
    }

    private func perform(
        _ request: URLRequest,
        destinationPath: String,
        allowsOverwrite: Bool
    ) async throws -> EditorGeneratedImageAsset {
        let configuration = project.ai.imageGeneration
        let destination = try resolvedDestinationURL(destinationPath, outputFormat: configuration.outputFormat)
        if fileManager.fileExists(atPath: destination.url.path), !allowsOverwrite {
            throw EditorAgentImageToolError.destinationExists(destination.relativePath)
        }

        let (responseData, response) = try await httpClient.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            let message =
                (try? JSONDecoder().decode(OpenAIErrorResponse.self, from: responseData).error.message)
                ?? String(bytes: responseData, encoding: .utf8)
                ?? "Unknown provider error"
            throw EditorAgentImageToolError.requestFailed(statusCode: response.statusCode, message: message)
        }
        guard let encoded = try JSONDecoder().decode(OpenAIImageResponse.self, from: responseData).data?.first?.base64JSON else {
            throw EditorAgentImageToolError.missingImageData
        }
        guard let imageData = Data(base64Encoded: encoded) else {
            throw EditorAgentImageToolError.invalidBase64Image
        }
        try Self.validate(imageData, outputFormat: configuration.outputFormat)
        try fileManager.createDirectory(at: destination.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try imageData.write(to: destination.url, options: [.atomic])

        return EditorGeneratedImageAsset(
            relativePath: destination.relativePath,
            assetReference: "@res://\(destination.assetPath)",
            mimeType: Self.mimeType(forExtension: configuration.outputFormat),
            data: imageData
        )
    }

    private func validateConfiguration() throws {
        let configuration = project.ai.imageGeneration
        guard configuration.enabled else {
            throw EditorAgentImageToolError.disabled
        }
        guard configuration.provider.lowercased() == "openai" else {
            throw EditorAgentImageToolError.unsupportedProvider(configuration.provider)
        }
    }

    private func resolvedSourceURL(_ sourcePath: String) throws -> URL {
        guard !sourcePath.hasPrefix("/") else {
            throw EditorAgentImageToolError.invalidSource(sourcePath)
        }
        let candidate = projectURL.appendingPathComponent(sourcePath).standardizedFileURL
        let projectPath = projectURL.resolvingSymlinksInPath().path
        let candidatePath = candidate.resolvingSymlinksInPath().path
        guard candidatePath.hasPrefix(projectPath + "/"), fileManager.fileExists(atPath: candidate.path) else {
            throw EditorAgentImageToolError.invalidSource(sourcePath)
        }
        return candidate
    }

    private func resolvedDestinationURL(
        _ destinationPath: String,
        outputFormat: String
    ) throws -> (url: URL, relativePath: String, assetPath: String) {
        let trimmed = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.split(separator: "/").contains("..") else {
            throw EditorAgentImageToolError.invalidDestination(destinationPath)
        }
        let format = outputFormat.lowercased()
        let assetPath = URL(fileURLWithPath: trimmed).pathExtension.isEmpty ? "\(trimmed).\(format)" : trimmed
        guard URL(fileURLWithPath: assetPath).pathExtension.lowercased() == format else {
            throw EditorAgentImageToolError.invalidDestination(destinationPath)
        }
        let assetsRoot = project.paths.assets ?? "Assets"
        let relativePath = URL(fileURLWithPath: assetsRoot, isDirectory: true).appendingPathComponent(assetPath).relativePath
        let url = projectURL.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(projectURL.path + "/") else {
            throw EditorAgentImageToolError.invalidDestination(destinationPath)
        }
        return (url, relativePath, assetPath)
    }

    private static func validate(_ data: Data, outputFormat: String) throws {
        let bytes = [UInt8](data.prefix(12))
        let valid: Bool =
            switch outputFormat.lowercased() {
            case "png": bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            case "jpeg",
                "jpg":
                bytes.starts(with: [0xFF, 0xD8])
            case "webp": bytes.count >= 12 && Array(bytes[0..<4]) == Array("RIFF".utf8) && Array(bytes[8..<12]) == Array("WEBP".utf8)
            default: false
            }
        guard valid else {
            throw EditorAgentImageToolError.invalidImageFormat(outputFormat)
        }
    }

    private static func mimeType(forExtension fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "jpg",
            "jpeg":
            "image/jpeg"
        case "webp": "image/webp"
        default: "image/png"
        }
    }

    private static func multipartBody(
        boundary: String,
        fields: [String: String],
        imageData: Data,
        fileName: String,
        mimeType: String
    ) -> Data {
        var data = Data()
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(fileName)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        data.append(imageData)
        data.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return data
    }
}
