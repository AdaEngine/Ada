import AdaStudioCore
import Crypto
import Foundation

struct EditorKimodoManifest: Decodable, Sendable {
    let extensionID: String
    let platform: String
    let version: String
    let minimumStudioVersion: String
    let protocolVersion: Int
    let files: [String: String]

    static let payload: Set<String> = [
        "LICENSE", "UV-LICENSE-APACHE", "UV-LICENSE-MIT", "antlr4_python3_runtime-4.9.3-py3-none-any.whl",
        "kimodo-1.0.0-cp311-cp311-linux_x86_64.whl", "launch.sh", "pyproject.toml", "uv", "uv.lock", "worker.py"
    ]
    static let metadata: Set<String> = ["manifest.json", "manifest.sig"]
    static let maximumBytes = 128 * 1024 * 1024

    static func verify(_ contents: [String: Data], keys: [Data], studioVersion: String) throws -> Self {
        guard Set(contents.keys) == payload.union(metadata), let manifestBytes = contents["manifest.json"],
              manifestBytes.count <= 4096, let signature = contents["manifest.sig"], signature.count == 64,
              keys.contains(where: { key in
                  (try? Curve25519.Signing.PublicKey(rawRepresentation: key).isValidSignature(signature, for: manifestBytes)) == true
              }) else { throw EditorKimodoError.invalidPackage }
        let manifest = try JSONDecoder().decode(Self.self, from: manifestBytes)
        guard manifest.extensionID == "org.adaengine.kimodo", manifest.platform == "windows-x64", manifest.protocolVersion == 1,
              Set(manifest.files.keys) == payload, versionParts(manifest.version) != nil,
              let minimum = versionParts(manifest.minimumStudioVersion),
              let installed = installedVersionParts(studioVersion),
              !installed.lexicographicallyPrecedes(minimum) else { throw EditorKimodoError.incompatiblePackage }
        for (name, hash) in manifest.files {
            guard let data = contents[name], !data.isEmpty, digest(data) == hash else { throw EditorKimodoError.invalidPackage }
        }
        return manifest
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func versionParts(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ (1...9).contains($0.utf8.count) && $0.utf8.allSatisfy { (48...57).contains($0) } }) else {
            return nil
        }
        return parts.compactMap { Int($0) }
    }

    private static func installedVersionParts(_ tag: String) -> [Int]? {
        if tag.hasPrefix("editor-v") {
            let parts = tag.dropFirst("editor-v".count).split(separator: "-", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.count <= 2, parts.dropFirst().allSatisfy({ $0.count == 8 && Int($0) != nil }) else {
                return nil
            }
            return versionParts(String(parts[0]))
        }
        return versionParts(tag.hasPrefix("v") ? String(tag.dropFirst()) : tag)
    }

    /// Packages can contain only the first-party manifest, signature and known payload names.
    static func open(_ file: URL) throws -> [String: Data] {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard let archive = try handle.read(upToCount: maximumBytes + 1), archive.count <= maximumBytes else { throw EditorKimodoError.invalidPackage }
        let allowedNames = payload.union(metadata)
        guard let entries = try? StudioArchive.decode(
            archive,
            maximumBytes: maximumBytes,
            maximumFileBytes: maximumBytes,
            maximumFiles: allowedNames.count,
            permits: allowedNames.contains
        ) else {
            throw EditorKimodoError.invalidPackage
        }
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0.data) })
    }
}

enum EditorKimodoError: LocalizedError, Sendable {
    case invalidPackage, incompatiblePackage, notInstalled, wslUnavailable, cudaUnavailable, modelAccessRequired, generationFailed, invalidResult, descriptionTooLong

    var errorDescription: String? {
        switch self {
        case .invalidPackage: "The Kimodo package failed verification. Download a new copy from the publisher."
        case .incompatiblePackage: "This Kimodo package requires a compatible Windows release of Ada Studio."
        case .notInstalled: "Download a compatible Kimodo package and install it from the File menu."
        case .wslUnavailable: "Install Ubuntu on WSL 2, then try again."
        case .cudaUnavailable: "Kimodo could not find an NVIDIA GPU in Ubuntu. Check the Windows NVIDIA driver and WSL 2."
        case .modelAccessRequired: "Authorize the Llama 3 model on Hugging Face and sign in from Ubuntu, then try again."
        case .generationFailed: "Kimodo could not generate the animation. Check the model setup and retry."
        case .invalidResult: "Kimodo returned an invalid animation."
        case .descriptionTooLong: "Shorten the motion description and try again."
        }
    }
}
