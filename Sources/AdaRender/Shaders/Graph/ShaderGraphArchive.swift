import AdaAssets
import Foundation

/// Fresh, host-compiled fragment variants packaged with graph documents and
/// texture paths. Runtime values remain on each material instance.
public struct ShaderGraphArchive: Codable, Sendable {
    public struct Fragment: Codable, Sendable {
        public let source: String
        public let defines: [String: String]
        public let entryPoint: String
        public let wgsl: String
        public let reflection: ShaderReflectionData

        public init(source: String, defines: [String: String], entryPoint: String, wgsl: String, reflection: ShaderReflectionData) {
            self.source = source
            self.defines = defines
            self.entryPoint = entryPoint
            self.wgsl = wgsl
            self.reflection = reflection
        }

        /// Identifies the baked fragment by template name and the graph's generated WGSL.
        public static func identity(template: String, graphSource: String) -> String {
            template + "\n" + graphSource
        }
    }

    /// Version 2 fragments are linked from the WESL templates and identified by ``Fragment/identity(template:graphSource:)``.
    /// Version 1 archives were baked from GLSL templates and cannot be used.
    public static let currentVersion = 2

    public var version: Int
    public var graphs: [String: ShaderGraph]
    public var fragments: [Fragment]
    public var texturePaths: [String]

    public init(graphs: [String: ShaderGraph], fragments: [Fragment], texturePaths: [String]) {
        version = Self.currentVersion
        self.graphs = graphs
        self.fragments = fragments
        self.texturePaths = texturePaths
    }
}

public struct ShaderGraphArchiveAsset: Asset {
    public var archive: ShaderGraphArchive
    public var assetMetaInfo: AssetMetaInfo?
    public static func extensions() -> [String] { ["shadergraphlib"] }
    public init(archive: ShaderGraphArchive) { self.archive = archive }
    public init(from decoder: any AssetDecoder) throws { archive = try decoder.decode(ShaderGraphArchive.self) }
    public func encodeContents(with encoder: any AssetEncoder) throws { try encoder.encode(archive) }
}

/// Process-wide immutable shader artifacts can be shared by worlds. The lock
/// protects installation and lookup; authored instance values never enter here.
public final class ShaderGraphRuntimeLibrary: @unchecked Sendable {
    private static let shared = ShaderGraphRuntimeLibrary()
    private let lock = NSLock()
    private var graphs: [String: ShaderGraph] = [:]
    private var fragments: [String: [ShaderGraphArchive.Fragment]] = [:]
    private var textures: [String: Texture2D] = [:]

    public static func install(_ archive: ShaderGraphArchive) throws {
        guard archive.version == ShaderGraphArchive.currentVersion else {
            throw ShaderGraphDiagnostic(
                code: .unsupportedVersion,
                nodeID: "Shader Graph archive version \(archive.version) was baked from GLSL templates; rebuild it with AdaShaderGraphBaker (version \(ShaderGraphArchive.currentVersion))")
        }
        for graph in archive.graphs.values { _ = try graph.lowered() }
        guard archive.fragments.allSatisfy({ !$0.source.isEmpty && !$0.wgsl.isEmpty && !$0.entryPoint.isEmpty }) else {
            throw ShaderGraphDiagnostic(code: .invalidReference)
        }
        shared.lock.lock()
        defer { shared.lock.unlock() }
        shared.graphs.merge(archive.graphs) { _, new in new }
        for fragment in archive.fragments {
            let key = key(source: fragment.source, defines: fragment.defines)
            var bucket = shared.fragments[key, default: []]
            bucket.removeAll { $0.source == fragment.source && $0.defines == fragment.defines }
            bucket.append(fragment)
            shared.fragments[key] = bucket
        }
    }

    /// Call after configuring the render device and resource roots, before
    /// decoding scenes that reference graph materials.
    public static func preload(at path: String) async throws {
        let asset = try await AssetsManager.loadFresh(ShaderGraphArchiveAsset.self, at: path)
        try install(asset.archive)
        for path in asset.archive.texturePaths {
            let handle = try await AssetsManager.load(Texture2D.self, at: path)
            guard let texture = handle.untypedAsset as? Texture2D else { throw ShaderGraphDiagnostic(code: .invalidReference, nodeID: path) }
            registerTexture(texture, at: path)
        }
    }

    /// Assets loaded by the ordinary AdaScript preload path become available to
    /// synchronous graph texture setters on WebAssembly too.
    public static func registerTexture(_ texture: Texture2D, at path: String) {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        shared.textures[path] = texture
    }

    static func graph(at path: String) throws -> ShaderGraph {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        guard let graph = shared.graphs[path] else { throw ShaderGraphDiagnostic(code: .invalidReference, nodeID: path) }
        return graph
    }

    static func texture(at path: String) throws -> Texture2D {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        guard let texture = shared.textures[path] else { throw ShaderGraphDiagnostic(code: .invalidReference, nodeID: path) }
        return texture
    }

    static func fragment(source: String, defines: [ShaderDefine]) -> ShaderGraphArchive.Fragment? {
        let defines = defines.reduce(into: [String: String]()) { $0[$1.name] = $1.value }
        let key = key(source: source, defines: defines)
        shared.lock.lock()
        defer { shared.lock.unlock() }
        // Exact equality also guards against a hash collision or unrelated artifact.
        return shared.fragments[key]?.first { $0.source == source && $0.defines == defines }
    }

    private static func key(source: String, defines: [String: String]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let input = source + defines.keys.sorted().map { "\u{0}\($0)=\(defines[$0] ?? "")" }.joined()
        for byte in input.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
    }
}
