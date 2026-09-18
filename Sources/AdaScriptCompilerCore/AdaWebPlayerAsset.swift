import Foundation

public struct AdaWebPlayerAsset: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case texture, font, shader, audio, license }
    public var id: String
    public var kind: Kind
    public var path: String

    public init(id: String, kind: Kind, path: String) {
        self.id = id
        self.kind = kind
        self.path = path
    }
}

/// UI material ABI 1: fragment entry `player_fragment`, one sampled texture and a vec4 parameter block.
public struct AdaWebPlayerMaterial: Codable, Equatable, Sendable {
    public var id: String
    public var shader: String
    public var texture: String
    public init(id: String, shader: String, texture: String) {
        self.id = id
        self.shader = shader
        self.texture = texture
    }
}

extension AdaWebPlayerProject {
    public func resourceURL(_ path: String, at directory: URL) throws -> URL {
        guard Self.isResourcePath(path) else {
            throw AdaWebPlayerProjectError.invalid("Invalid resource path: \(path).")
        }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let url = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard
            url.path.hasPrefix(root.path + "/"),
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else {
            throw AdaWebPlayerProjectError.invalid("Missing resource or resource outside project: \(path).")
        }
        return url
    }

    func validateResources() throws {
        let assets = assets ?? []
        let materials = materials ?? []
        guard assets.isEmpty && materials.isEmpty || runtimeAPI >= 2 else {
            throw AdaWebPlayerProjectError.invalid("Project resources require runtime API 2.")
        }
        guard
            Set(assets.map(\.id)).count == assets.count,
            Set(materials.map(\.id)).count == materials.count
        else {
            throw AdaWebPlayerProjectError.invalid("Duplicate resource or material identifier.")
        }
        let paths = sources + assets.map(\.path) + ["project.json"]
        guard Set(paths.map { $0.lowercased() }).count == paths.count else {
            throw AdaWebPlayerProjectError.invalid("Resource paths collide with another resource or project file.")
        }
        for asset in assets {
            guard AdaScriptLibraryManifest.isIdentifier(asset.id), Self.isResourcePath(asset.path) else {
                throw AdaWebPlayerProjectError.invalid("Invalid resource: \(asset.id).")
            }
            let ext = URL(fileURLWithPath: asset.path).pathExtension.lowercased()
            let supported: [String]
            switch asset.kind {
            case .texture: supported = ["png"]
            case .font: supported = ["ttf", "otf"]
            case .shader: supported = ["wgsl"]
            case .audio: supported = ["wav", "mp3", "m4a"]
            case .license: supported = ["txt", "md"]
            }
            guard supported.contains(ext) else {
                throw AdaWebPlayerProjectError.invalid("Unsupported format for \(asset.id): \(ext).")
            }
        }
        for material in materials {
            guard
                AdaScriptLibraryManifest.isIdentifier(material.id),
                assets.contains(where: { $0.id == material.shader && $0.kind == .shader }),
                assets.contains(where: { $0.id == material.texture && $0.kind == .texture })
            else {
                throw AdaWebPlayerProjectError.invalid("Invalid shader or texture reference in material \(material.id).")
            }
        }
    }

    private static func isResourcePath(_ path: String) -> Bool {
        !path.isEmpty && path.count <= 220 && !path.contains("\\") && !path.contains(":")
            && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(" ") }
    }
}
