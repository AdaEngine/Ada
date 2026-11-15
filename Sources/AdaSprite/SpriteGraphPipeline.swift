import AdaAssets
@_spi(Internal) import AdaRender
import AdaUtils
import Foundation

public enum SpriteGraphPipeline {
    static func make(material: ShaderGraphMaterial, base: RenderPipeline, instanced: Bool, device: RenderDevice) throws -> RenderPipeline {
        guard material.program.target == .sprite else {
            throw ShaderGraphDiagnostic(code: .typeMismatch, nodeID: "Sprite")
        }
        let variant = instanced ? "sprite-instanced" : "sprite-expanded"
        let name = instanced ? "sprite_instanced" : "sprite"
        #if SAGA_WEBGPU
            // Web exports load the baked fragment for this template and graph.
            return try material.weslPipeline(base: base.descriptor, device: device, variant: variant, templateName: name) { "" }
        #else
            // Other WESL profiles link the templates at runtime.
            if ShaderModule.supportsBundledWESL {
                return try material.weslPipeline(
                    base: base.descriptor, device: device, variant: variant,
                    packageRoot: Bundle.adaModule.resourceURL?.appendingPathComponent("Assets", isDirectory: true),
                    templateName: name
                ) {
                    try weslTemplate(instanced: instanced)
                }
            }
                throw ShaderGraphDiagnostic(code: .invalidReference, nodeID: name)
        #endif
    }

    /// Where the sprite templates' `package::` imports resolve.
    public static var weslPackageRoot: URL {
        Bundle.adaModule.resourceURL?.appendingPathComponent("Assets", isDirectory: true) ?? URL(fileURLWithPath: "/")
    }

    /// The WESL sprite template; its `// ADA_GRAPH_SOURCE_MARKER` line receives the graph's WGSL.
    public static func weslTemplate(instanced: Bool) throws -> String {
        let path = instanced ? "Assets/sprite_instanced.wesl" : "Assets/sprite.wesl"
        guard let url = Bundle.adaModule.resourceURL?.appendingPathComponent(path),
            let data = FileSystem.current.readFile(at: url),
            let source = String(bytes: data, encoding: .utf8) else {
            throw ShaderGraphDiagnostic(code: .invalidReference, nodeID: path)
        }
        return source
    }

}
