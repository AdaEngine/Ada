//
//  CustomMaterial.swift
//  AdaEngine
//
//  Created by v.prusakov on 4/2/23.
//

import AdaAssets
import AdaUtils
import Foundation

protocol MaterialValueDelegate: AnyObject {
    func updateValue(_ value: Any, for name: String)
    func updateTexture(_ texture: MaterialTexture, for name: String)
}

private enum CustomMaterialError: LocalizedError {
    case missingShaderStage(ShaderStage, material: String)

    var errorDescription: String? {
        switch self {
        case let .missingShaderStage(stage, material):
            return "Missing \(stage.rawValue) shader source for \(material)."
        }
    }
}

/// A material whose Swift properties bind to reflected shader resources.
///
/// Implement ``ReflectedMaterial/shaderModule()`` with a linked WESL module. For materials
/// whose vertex layout selects WESL features, set ``ReflectedMaterial/usesVariantShaderModules``
/// and implement ``ReflectedMaterial/variantShaderModule(defines:)``.
///
/// Match each `@Uniform` property name to the WGSL uniform variable and its binding.
/// For example, ``ColorCanvasMaterial`` binds the color to the canvas shader's uniform.
///
/// ```swift
/// let material = CustomMaterial(ColorCanvasMaterial(color: .red))
/// material.color = .blue
/// ```
@propertyWrapper
@dynamicMemberLookup
public final class CustomMaterial<T: ReflectedMaterial>: Material, MaterialValueDelegate, @unchecked Sendable {
    public var wrappedValue: T {
        get {
            return material
        }

        set {
            self.material = newValue
        }
    }

    public var projectedValue: CustomMaterial<T> {
        return self
    }

    /// User material that can be updated.
    public var material: T

    /// Contains all bindable properties founded in passed ``ReflectedMaterial``.
    private var bindableValues: [_ShaderBindProperty] = []
    private let sourceLoadError: (any Error)?

    public convenience init(wrappedValue: T) {
        self.init(wrappedValue)
    }

    /// Create a new CustomMaterial instance from user ``ReflectedMaterial``.
    public init(_ material: T) {
        self.material = material

        self.sourceLoadError = nil
        super.init(shaderSource: ShaderSource(), linkedShaderModule: nil, variantModuleFactory: { defines in
            if T.usesVariantShaderModules {
                return try T.variantShaderModule(defines: defines)
            }
            guard let module = try T.shaderModule() else {
                throw ShaderCompiler.CompileError.weslRequired(String(reflecting: T.self))
            }
            guard defines.isEmpty else {
                throw AssetError.message("Linked-module materials must select feature variants before construction.")
            }
            return module
        })
        self.reflectMaterial(from: material)
    }

    public required init(from _: AssetDecoder) throws {
        throw AssetError.message("CustomMaterial cannot be decoded as an asset.")
    }

    public subscript<Value>(dynamicMember keyPath: WritableKeyPath<T, Value>) -> Value {
        get {
            return self.material[keyPath: keyPath]
        }

        set {
            self.material[keyPath: keyPath] = newValue
        }
    }

    override public func makeShaderModule(defines: [ShaderDefine]) throws -> ShaderModule {
        if let sourceLoadError { throw sourceLoadError }
        return try super.makeShaderModule(defines: defines)
    }

    // MARK: - Mesh

    override public func collectDefines(for vertexDescriptor: VertexDescriptor, keys: Set<String>) -> [ShaderDefine] {
        return T.configureShaderDefines(keys: keys, vertexDescriptor: vertexDescriptor)
    }

    override public func configureRenderPipeline(
        for vertexDescriptor: VertexDescriptor,
        keys: Set<String>,
        shaderModule: ShaderModule
    ) -> RenderPipelineDescriptor? {
        do {
            guard let vertexShader = shaderModule.getShader(for: .vertex) else {
                assertionFailure("[CustomMaterial] \(CustomMaterialError.missingShaderStage(.vertex, material: String(reflecting: T.self)))")
                return nil
            }

            guard let fragmentShader = shaderModule.getShader(for: .fragment) else {
                assertionFailure("[CustomMaterial] \(CustomMaterialError.missingShaderStage(.fragment, material: String(reflecting: T.self)))")
                return nil
            }

            let pipeline = try T.configurePipeline(
                keys: keys,
                vertex: vertexShader,
                fragment: fragmentShader,
                vertexDescriptor: vertexDescriptor
            )

            return pipeline
        } catch {
            assertionFailure("[CustomMaterial] \(error)")
            return nil
        }
    }

    /// Find and link shader bind properties.
    func reflectMaterial(from material: T) {
        self.bindableValues.removeAll()

        let reflection = Mirror(reflecting: material)

        for child in reflection.children {
            guard let bindProperty = child.value as? _ShaderBindProperty else {
                continue
            }

            if bindProperty.propertyName.isEmpty {
                // Get the propertyName of the property. By syntax, the property name is
                // in the form: "_name". Dropping the "_" -> "name"
                var propertyName = String((child.label ?? "").dropFirst())

                // For shader reflection data in uniforms we can't use lowercased name
                if child.value is _ShaderUniformProperty {
                    propertyName = propertyName.capitalizingFirstLetter()
                }

                bindProperty.propertyName = propertyName
            }

            // For update buffers
            bindProperty.delegate = self

            self.bindableValues.append(bindProperty)
        }
    }

    override public func update() {
        self.bindableValues.forEach {
            $0.update()
        }
    }

    // MARK: Delegate

    func updateValue(_ value: Any, for name: String) {
        self.setValue(value, for: name)
    }

    func updateTexture(_ texture: MaterialTexture, for name: String) {
        self.setTexture(texture, for: name)
    }
}

extension String {
    func capitalizingFirstLetter() -> String {
        return prefix(1).uppercased() + dropFirst()
    }
}
