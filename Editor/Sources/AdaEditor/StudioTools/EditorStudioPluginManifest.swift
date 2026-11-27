import Foundation

struct EditorStudioPluginManifest: Decodable, Sendable {
    static let filename = "plugin.json"
    static let assetLibraryID = "studio.external-asset-library"
    static let fileLimit = 64 * 1024

    enum ActionKind: String, Decodable, Sendable { case assetSearch, tool }
    enum View: String, Decodable, Sendable { case externalAssets }

    struct Action: Decodable, Sendable {
        let id: String
        let kind: ActionKind
        let title: Title
        let binding: String
        let effect: String
        let input: EditorCloudValue?
        let output: EditorCloudValue?
        let assetReferenceInput: String?
    }

    struct Title: Decodable, Sendable {
        let en: String
        let ru: String
    }

    let version: Int
    let id: String
    let view: View?
    let actions: [Action]

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= fileLimit else { throw Failure.manifest }
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        try manifest.validate()
        return manifest
    }

    static func readFile(_ url: URL, limit: Int = fileLimit) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= limit else { throw Failure.manifest }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw Failure.manifest }
        return data
    }

    private func validate() throws {
        guard version == 1, Self.acceptsID(id, punctuation: ".-"), actions.count <= 12,
              Set(actions.map(\.id)).count == actions.count, view == nil || id == Self.assetLibraryID else {
            throw Failure.manifest
        }
        for action in actions {
            guard Self.acceptsID(action.id, punctuation: "_"), Self.acceptsID(action.binding, punctuation: "_"),
                  action.effect == "read", [action.title.en, action.title.ru].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 220 }) else {
                throw Failure.manifest
            }
            switch action.kind {
            case .assetSearch:
                guard action.input == nil, action.output == nil, action.assetReferenceInput == nil else { throw Failure.manifest }
            case .tool:
                guard let input = action.input, let output = action.output,
                      input["additionalProperties"].bool == false, output["additionalProperties"].bool == false else { throw Failure.manifest }
                _ = try EditorLocalMCPToolSchema(input)
                _ = try EditorLocalMCPToolSchema(output)
                if let key = action.assetReferenceInput {
                    guard input["properties"][key]["type"].string == "string",
                          input["required"].array.contains(.string(key)) else { throw Failure.manifest }
                }
            }
            if action.binding.hasPrefix("native_") {
                let known = (action.kind == .assetSearch && action.binding == "native_search") ||
                    (action.kind == .tool && action.binding == "native_details" && action.assetReferenceInput == "asset")
                guard view == .externalAssets, known else { throw Failure.manifest }
            }
        }
    }

    private static func acceptsID(_ value: String, punctuation: String) -> Bool {
        let allowed = "abcdefghijklmnopqrstuvwxyz0123456789" + punctuation
        return value.count <= 64 && value.first.map { $0 >= "a" && $0 <= "z" } == true && value.allSatisfy { allowed.contains($0) }
    }

    enum Failure: LocalizedError {
        case manifest, archive, destination, unavailable

        var errorDescription: String? {
            switch self {
            case .manifest: "The Studio plugin manifest is invalid or unsupported."
            case .archive: "The Studio plugin archive is invalid or unsupported."
            case .destination: "A different plugin is already installed in this location."
            case .unavailable: "The Studio plugin action is unavailable."
            }
        }
    }
}
