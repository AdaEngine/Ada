import AdaRender
import AdaUtils
import Foundation

public enum SpriteGraphPipeline {
    static func make(material: ShaderGraphMaterial, base: RenderPipeline, instanced: Bool, device: RenderDevice) throws -> RenderPipeline {
        guard material.program.target == .sprite else {
            throw ShaderGraphDiagnostic(code: .typeMismatch, nodeID: "Sprite")
        }
        let variant = instanced ? "sprite-instanced" : "sprite-expanded"
        let name = instanced ? "sprite_instanced" : "sprite"
        #if WASM
            // A WebAssembly build links no shaders: it uses the fragment AdaShaderGraphBaker linked from the WESL template.
            return try material.weslPipeline(base: base.descriptor, device: device, variant: variant, templateName: name) { "" }
        #else
            // The native renderer links the WESL templates at runtime.
            if ShaderModule.supportsBundledWESL {
                return try material.weslPipeline(
                    base: base.descriptor, device: device, variant: variant,
                    packageRoot: Bundle.adaModule.resourceURL?.appendingPathComponent("Assets", isDirectory: true),
                    templateName: name
                ) {
                    try weslTemplate(instanced: instanced)
                }
            }
            return try material.pipeline(base: base.descriptor, device: device, variant: variant) {
                try fragmentTemplate(instanced: instanced)
            }
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

    /// The production sprite fragment used by offline graph export.
    public static func fragmentTemplate(instanced: Bool) throws -> String {
        let path = instanced ? "Assets/sprite_instanced.glsl" : "Assets/sprite.glsl"
        guard let url = Bundle.adaModule.resourceURL?.appendingPathComponent(path),
            let fragment = try ShaderSource(from: url).getSource(for: .fragment) else {
            throw ShaderGraphDiagnostic(code: .invalidReference, nodeID: path)
        }
        return fragment
    }
}
