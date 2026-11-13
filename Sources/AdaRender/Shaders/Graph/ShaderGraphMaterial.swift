import AdaAssets
import Foundation
import Logging

/// Explicit resource context for document-backed scenes prepared before their
/// asset plugins start. Structured tasks inherit it; material instances retain
/// their resolved root without changing another world's asset configuration.
public enum ShaderGraphResourceScope {
    @TaskLocal public static var rootPath: String?
}

/// Authored reference plus independent parameter overrides. Inline graphs support procedural materials.
public struct ShaderGraphMaterialSource: Codable, Hashable, Sendable {
    public var path: String?
    public var graph: ShaderGraph?
    public var values: [String: [Float]]
    public var textures: [String: String]

    public init(path: String? = nil, graph: ShaderGraph? = nil, values: [String: [Float]] = [:], textures: [String: String] = [:]) {
        self.path = path
        self.graph = graph
        self.values = values
        self.textures = textures
    }

    private enum CodingKeys: CodingKey { case path, graph, values, textures }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        graph = try container.decodeIfPresent(ShaderGraph.self, forKey: .graph)
        values = try container.decodeIfPresent([String: [Float]].self, forKey: .values) ?? [:]
        textures = try container.decodeIfPresent([String: String].self, forKey: .textures) ?? [:]
    }
}

/// Immutable shader code with independently editable, synchronized instance values.
/// `lock` protects authored state and per-device immutable binding snapshots. GPU buffers
/// are replaced rather than overwritten, preserving values used by in-flight commands.
public final class ShaderGraphMaterial: Codable, @unchecked Sendable {
    public let program: ShaderGraphProgram
    /// The authored graph, retained so the WGSL form can be generated for WESL templates.
    let graph: ShaderGraph
    private var cachedWGSLProgram: ShaderGraphProgram?
    let pipelineStorage = ShaderGraphPipelineStorage()
    private let lock = NSLock()
    private var source: ShaderGraphMaterialSource
    private let resourceBasePath: String?
    private let resourceRootPath: String?
    private var loadedTextures: [Int: Texture2D] = [:]
    private var revision: UInt64 = 0
    private var time: Float = 0
    private var automaticTime = true
    private var issue: String?
    private var preparedPipeline = false
    private struct Prepared {
        let device: RenderDevice
        let revision: UInt64
        let resources: RenderResourceSet
    }
    private var bindings: [ObjectIdentifier: Prepared] = [:]

    public var descriptor: ShaderGraphMaterialSource {
        lock.lock()
        defer { lock.unlock() }
        return source
    }

    public var compilationError: String? {
        lock.lock()
        defer { lock.unlock() }
        return issue
    }

    /// True after this instance has successfully prepared at least one GPU pipeline.
    public var hasPreparedPipeline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return preparedPipeline
    }

    func recordPipelinePreparation() {
        lock.lock()
        preparedPipeline = true
        lock.unlock()
    }

    public var valueRevision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return revision
    }

    public func reportCompilationError(_ error: any Error) {
        let message = String(describing: error)
        lock.lock()
        let changed = issue != message
        issue = message
        lock.unlock()
        if changed { Logger(label: "org.adaengine.shader-graph").error("\(message)") }
    }

    /// `resourceRootPath` supplies a physical root for document-backed previews
    /// prepared before an application's scoped asset plugins have started.
    public init(source: ShaderGraphMaterialSource, resourceBasePath: String? = nil, resourceRootPath: String? = ShaderGraphResourceScope.rootPath) throws {
        self.resourceBasePath = resourceBasePath
        self.resourceRootPath = resourceRootPath
        let graph: ShaderGraph
        if let inline = source.graph, source.path == nil {
            graph = inline
        } else if let path = source.path, source.graph == nil {
            #if WASM
                graph = try ShaderGraphRuntimeLibrary.graph(at: path)
            #else
                graph = try AssetsManager.loadFreshSync(ShaderGraphAsset.self, at: Self.resolve(path, root: resourceRootPath)).graph
            #endif
        } else {
            throw ShaderGraphDiagnostic(code: .invalidReference)
        }
        program = try graph.compileGLSL()
        self.graph = graph
        self.source = source
        for (id, value) in source.values { try validate(value, for: id) }
        for id in source.textures.keys where !program.textures.contains(where: { $0.parameterID == id }) {
            throw ShaderGraphDiagnostic(code: .invalidReference, nodeID: id)
        }
        for texture in program.textures {
            let path = texture.parameterID.flatMap { source.textures[$0] } ?? texture.path
            if let path { loadedTextures[texture.binding] = try Self.loadTexture(path, relativeTo: source.path ?? resourceBasePath, root: resourceRootPath) }
        }
    }

    public convenience init(from decoder: any Decoder) throws {
        try self.init(source: ShaderGraphMaterialSource(from: decoder))
    }

    /// Shares immutable code and texture assets while retaining independent values,
    /// clocks and GPU snapshots. Copying never reloads a changed graph file.
    public func makeInstance() -> ShaderGraphMaterial {
        lock.lock()
        defer { lock.unlock() }
        let instance = ShaderGraphMaterial(program: program, graph: graph, source: source, textures: loadedTextures, resourceBasePath: resourceBasePath, resourceRootPath: resourceRootPath)
        instance.time = time
        instance.automaticTime = automaticTime
        return instance
    }

    private init(program: ShaderGraphProgram, graph: ShaderGraph, source: ShaderGraphMaterialSource, textures: [Int: Texture2D], resourceBasePath: String?, resourceRootPath: String?) {
        self.program = program
        self.graph = graph
        self.source = source
        self.loadedTextures = textures
        self.resourceBasePath = resourceBasePath
        self.resourceRootPath = resourceRootPath
    }

    public func encode(to encoder: any Encoder) throws {
        try descriptor.encode(to: encoder)
    }

    /// The same graph as WGSL for WESL templates. Parameter slots and bindings equal ``program``'s, so a material binds
    /// identically whichever form a pipeline compiles.
    func wgslProgram() throws -> ShaderGraphProgram {
        lock.lock()
        if let cachedWGSLProgram {
            lock.unlock()
            return cachedWGSLProgram
        }
        lock.unlock()
        let compiled = try graph.compileWGSL()
        lock.lock()
        cachedWGSLProgram = compiled
        lock.unlock()
        return compiled
    }

    public func value(for id: String) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        return source.values[id] ?? program.parameters.first { $0.id == id }?.defaultValue
    }

    /// Updates numeric uniforms without changing the shader/pipeline identity.
    public func setValue(_ value: [Float], for id: String) throws {
        try validate(value, for: id)
        lock.lock()
        defer { lock.unlock() }
        if source.values[id] != value { source.values[id] = value; revision &+= 1 }
    }

    public func setTexturePath(_ path: String, for id: String) throws {
        guard let texture = program.textures.first(where: { $0.parameterID == id }) else {
            throw ShaderGraphDiagnostic(code: .invalidReference, nodeID: id)
        }
        let loaded = try Self.loadTexture(path, relativeTo: descriptor.path ?? resourceBasePath, root: resourceRootPath)
        lock.lock()
        defer { lock.unlock() }
        source.textures[id] = path
        loadedTextures[texture.binding] = loaded
        revision &+= 1
    }

    public func setTime(_ seconds: Float) {
        guard seconds.isFinite, program.usesTime else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        automaticTime = false
        if time != seconds { time = seconds; revision &+= 1 }
    }

    /// Renderer extraction advances animated graphs once per world frame. Manual
    /// `setTime` takes ownership of the clock, as used by editor preview transport.
    package func updateAutomaticTime(_ seconds: Float) {
        guard program.usesTime, seconds.isFinite else { return }
        lock.lock()
        defer { lock.unlock() }
        if automaticTime, time != seconds { time = seconds; revision &+= 1 }
    }

    /// Called on the renderer's owning context. A revision reuses one immutable snapshot per device.
    public func resourceSet(device: RenderDevice) -> RenderResourceSet {
        prepared(device: device).resources
    }

    /// Binds an atomic texture/uniform/sampler snapshot using the portable descriptor groups.
    public func bind(to encoder: RenderCommandEncoder, device: RenderDevice) {
        let snapshot = prepared(device: device)
        encoder.setResourceSet(snapshot.resources, index: ShaderGraphProgram.resourceSet)
    }

    private func prepared(device: RenderDevice) -> Prepared {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(device)
        if let cached = bindings[key], cached.revision == revision {
            return cached
        }
        var words = [Float](repeating: 0, count: (program.parameters.count + 1) * 4)
        words[0] = time
        words[1] = program.renderSettings.alphaCutoff
        switch program.renderSettings.mode {
        case .opaque: words[2] = 0
        case .mask: words[2] = 1
        case .blend: words[2] = 2
        }
        words[3] = program.renderSettings.doubleSided ? 1 : 0
        for parameter in program.parameters {
            let value = source.values[parameter.id] ?? parameter.defaultValue
            for (index, number) in value.enumerated() { words[parameter.slot * 4 + index] = number }
        }
        let buffer = device.createUniformBuffer(length: words.count * MemoryLayout<Float>.stride, binding: ShaderGraphProgram.uniformBinding)
        buffer.setElements(&words)
        var resources: [RenderResourceSet.Binding] = [
            .init(binding: ShaderGraphProgram.uniformBinding, shaderStages: .fragment, resource: .uniformBuffer(buffer, offset: 0))
        ]
        for texture in program.textures {
            resources.append(.init(binding: texture.binding, shaderStages: .fragment, resource: .texture(loadedTextures[texture.binding] ?? .whiteTexture)))
        }
        if let first = program.textures.first {
            let texture = loadedTextures[first.binding] ?? .whiteTexture
            resources.append(.init(binding: ShaderGraphProgram.samplerBinding, shaderStages: .fragment, resource: .sampler(texture.sampler)))
        }
        let result = Prepared(device: device, revision: revision, resources: .init(bindings: resources))
        bindings[key] = result
        return result
    }

    private func validate(_ value: [Float], for id: String) throws {
        guard let parameter = program.parameters.first(where: { $0.id == id }) else {
            throw ShaderGraphDiagnostic(code: .invalidReference, nodeID: id)
        }
        guard value.count == parameter.type.componentCount, value.allSatisfy(\.isFinite),
            parameter.type != .bool || value == [0] || value == [1] else {
            throw ShaderGraphDiagnostic(code: .invalidLiteral, nodeID: id)
        }
    }

    private static func resolve(_ path: String, root: String?) throws -> String {
        guard let root, path.hasPrefix("@res://") else {
            return path
        }
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL
        let url = base.appendingPathComponent(String(path.dropFirst(7))).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(base.path + "/") else { throw ShaderGraphDiagnostic(code: .invalidReference, nodeID: path) }
        return url.path
    }

    private static func loadTexture(_ path: String, relativeTo graph: String?, root: String?) throws -> Texture2D {
        let resolved: String
        if !path.hasPrefix("@"), !path.hasPrefix("/"), let graph, let slash = graph.lastIndex(of: "/") {
            resolved = String(graph[...slash]) + path
        } else { resolved = path }
        #if WASM
            return try ShaderGraphRuntimeLibrary.texture(at: resolved)
        #else
            return try AssetsManager.loadSync(Texture2D.self, at: resolve(resolved, root: root)).asset
        #endif
    }
}
