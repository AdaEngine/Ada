//
//  Material.swift
//  AdaEngine
//
//  Created by v.prusakov on 11/3/21.
//

import AdaAssets
import AdaUtils
import Synchronization

// TODO: (Vlad) I think that `MaterialStorage` isn't great solution.

/// A type that describes the material aspects of a mesh, like color and texture.
///
/// In AdaEngine, a material defines the surface properties of a 3D and 2D model. It specifies how AdaEngine renders the entity,
/// including its color and whether it’s shiny or reflective.
/// Some components like `Mesh2D` may have one material that defines the way AdaEngine renders the entire entity,
/// or it may have several that define the look of different parts of the model.
public class Material: Asset, Hashable, @unchecked Sendable {
    public var assetMetaInfo: AssetMetaInfo?

    public let rid = RID()

    public let shaderSource: ShaderSource

    private let linkedShaderModule: ShaderModule?

    /// Builds a complete module for one set of feature defines (for example WESL variants chosen by vertex layout).
    typealias VariantModuleFactory = @Sendable ([ShaderDefine]) throws -> ShaderModule
    private let variantModuleFactory: VariantModuleFactory?
    private let variantModules = Mutex<[[ShaderDefine]: ShaderModule]>([:])

    /// Create a new material from shader source.
    public init(shaderSource: ShaderSource) {
        self.shaderSource = shaderSource
        self.linkedShaderModule = nil
        self.variantModuleFactory = nil
    }

    /// Internal complete-module path. Its identity must not alias an empty legacy source.
    init(shaderSource: ShaderSource, linkedShaderModule: ShaderModule?, variantModuleFactory: VariantModuleFactory? = nil) {
        self.shaderSource = shaderSource
        self.linkedShaderModule = linkedShaderModule
        self.variantModuleFactory = variantModuleFactory
    }

    private var isLinked: Bool { linkedShaderModule != nil || variantModuleFactory != nil }

    public required convenience init(from assetDecoder: AssetDecoder) throws {
        let shaderSource = try ShaderSource(from: assetDecoder)
        self.init(shaderSource: shaderSource)
    }

    public func encodeContents(with encoder: AssetEncoder) throws {
        guard !isLinked else {
            throw AssetError.message("Linked-module materials require their original WESL asset and cannot encode empty shader sources.")
        }
        try self.shaderSource.encodeContents(with: encoder)
    }

    public static func extensions() -> [String] {
        ["mat"]
    }

    /// Set the new value for material.
    public func setValue<T>(_ value: T, for name: String) {
        unsafe MaterialStorage.shared.setValue(value, for: name, in: self)
    }

    /// Get value from material.
    public func getValue<T>(for name: String, type _: T.Type) -> T? {
        return unsafe MaterialStorage.shared.getValue(for: name, in: self)
    }

    /// Set one or more textures for material.
    public func setTexture(_ texture: MaterialTexture, for name: String) {
        unsafe MaterialStorage.shared.setTexture(texture, for: name, in: self)
    }

    /// Get textures from material.
    public func getTexture(for name: String) -> MaterialTexture? {
        return unsafe MaterialStorage.shared.getTexture(for: name, in: self)
    }

    /// Updates material values.
    open func update() {}

    /// Supplies shader stages for a material, including materials loaded directly from runtime sources.
    open func makeShaderModule(defines: [ShaderDefine]) throws -> ShaderModule {
        if let variantModuleFactory {
            let key = defines.sorted { $0.name < $1.name }
            if let cached = variantModules.withLock({ $0[key] }) { return cached }
            let module = try variantModuleFactory(key)
            variantModules.withLock { $0[key] = module }
            return module
        }
        if let linkedShaderModule {
            guard defines.isEmpty else {
                throw AssetError.message("Linked-module materials must select feature variants before construction.")
            }
            return linkedShaderModule
        }
        let compiler = ShaderCompiler(shaderSource: shaderSource)
        for define in defines {
            compiler.setMacro(define.name, value: define.value, for: .vertex)
            compiler.setMacro(define.name, value: define.value, for: .fragment)
        }
        return try compiler.compileShaderModule()
    }

    // MARK: Hashable

    public static func == (lhs: Material, rhs: Material) -> Bool {
        if lhs.isLinked || rhs.isLinked {
            return lhs === rhs
        }
        return lhs.shaderSource == rhs.shaderSource
    }

    public func hash(into hasher: inout Hasher) {
        if isLinked {
            hasher.combine(ObjectIdentifier(self))
        } else {
            hasher.combine(self.shaderSource)
        }
    }

    // MARK: Mesh

    // TODO: (Vlad) I don't like current implementation for materials and shaders and methods below is a reason.

    /// Collection defines for passed vertex descriptor and collection of keys.
    open func collectDefines(for _: VertexDescriptor, keys _: Set<String>) -> [ShaderDefine] {
        fatalErrorMethodNotImplemented()
    }

    /// Create render pipeline descriptor for passed vertex descriptor, keys and compiled shader module.
    open func configureRenderPipeline(
        for _: VertexDescriptor,
        keys _: Set<String>,
        shaderModule _: ShaderModule
    ) -> RenderPipelineDescriptor? {
        fatalErrorMethodNotImplemented()
    }
}
