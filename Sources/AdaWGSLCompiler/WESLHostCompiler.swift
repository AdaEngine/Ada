#if !os(WASI)
import Foundation
import SAGACompiler
import SAGAShaderIR
import SAGAValidation

/// Links local WESL source files in-process and validates the generated WGSL.
public enum WESLHostCompiler {
    public struct Artifact: Codable, Sendable {
        public let wgsl: String
        public let sources: [String]
        public let entryPoints: [EntryPoint]
    }

    public struct EntryPoint: Codable, Sendable {
        public let name: String
        public let stage: String
    }

    public static func compile(
        packageRoot: URL,
        module: String,
        features: [String: Bool] = [:],
        dependencies: [String: URL] = [:]
    ) throws -> Artifact {
        guard dependencies["package"] == nil else {
            throw WESLLinker.Failure("The name package is reserved for the current WESL package")
        }
        var roots = dependencies.mapValues { $0.resolvingSymlinksInPath().standardizedFileURL }
        roots["package"] = packageRoot.resolvingSymlinksInPath().standardizedFileURL
        var linker = WESLLinker(roots: roots, features: features)
        let linked = try linker.link(module)
        let validated = try IndependentShaderCompiler().parseAndValidate(.wgsl(linked.wgsl))
        let entries = validated.module.entryPoints.map { EntryPoint(name: $0.name, stage: $0.stage.rawValue) }
        return Artifact(wgsl: linked.wgsl, sources: linked.sources, entryPoints: entries)
    }

    /// Links a file relative to an explicit shader package root.
    public static func compile(
        sourceFile: URL,
        packageRoot: URL,
        features: [String: Bool] = [:],
        dependencies: [String: URL] = [:]
    ) throws -> Artifact {
        let file = sourceFile.resolvingSymlinksInPath().standardizedFileURL
        let root = packageRoot.resolvingSymlinksInPath().standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard file.path.hasPrefix(prefix) else {
            throw WESLLinker.Failure("The WESL input must be under its package root.")
        }
        let relative = file.deletingPathExtension().path.dropFirst(prefix.count)
        let components = relative.split(separator: "/").map(String.init)
        let module = components == ["package"] ? "package" : (["package"] + components).joined(separator: "::")
        return try compile(packageRoot: root, module: module, features: features, dependencies: dependencies)
    }
}
#endif
