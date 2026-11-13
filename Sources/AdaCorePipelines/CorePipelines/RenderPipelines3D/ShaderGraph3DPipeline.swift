import AdaRender
import AdaUtils
import Foundation

public enum ShaderGraph3DPipeline {
    /// Shared silhouette rules for directional/local shadow maps and visibility depth.
    public static func bindShadow(
        encoder: RenderCommandEncoder,
        base: RenderPipeline,
        material: Material,
        device: RenderDevice,
        morph: Bool
    ) -> Bool {
        guard let pbr = material as? PBRMaterial, pbr.effectiveAlphaMode == .mask, let graph = pbr.graphMaterial else {
            encoder.setRenderPipelineState(base)
            return true
        }
        do {
            let formats = base.descriptor.colorAttachments.map { String(describing: $0.format) }.joined(separator: ",")
            let pipeline = try make(
                material: graph, base: base, device: device,
                variant: "shadow:\(formats):\(base.descriptor.depthPixelFormat):\(morph)",
                features: morph ? .morph : [], template: surfaceTemplatePath("directional_shadow_3d")
            )
            encoder.setRenderPipelineState(pipeline)
            graph.bind(to: encoder, device: device)
            return true
        } catch {
            graph.reportCompilationError(error)
            return false
        }
    }

    public static func make(
        material: ShaderGraphMaterial,
        base: RenderPipeline,
        device: RenderDevice,
        variant: String,
        features: PBRMaterial.ShaderFeatures = [],
        template: String = Flat3DPipeline.shaderPath
    ) throws -> RenderPipeline {
        guard material.program.target == .pbrSurface else {
            throw ShaderGraphDiagnostic(code: .typeMismatch, nodeID: "PBR")
        }
        let name = URL(fileURLWithPath: template).deletingPathExtension().lastPathComponent
        let macros = features.enablingMacros.map { ShaderDefine.define($0) }
        #if WASM
            // A WebAssembly build links no shaders: it uses the fragment AdaShaderGraphBaker linked from the WESL template.
            return try material.weslPipeline(base: base.descriptor, device: device, variant: variant, defines: macros, templateName: name) {
                ""
            }
        #else
            // WESL templates take the graph as WGSL and link at runtime; GLSL templates keep the GLSL form.
            if template.hasSuffix(".wesl") {
                return try material.weslPipeline(
                    base: base.descriptor, device: device, variant: variant, defines: macros,
                    packageRoot: weslPackageRoot,
                    templateName: name
                ) {
                    try weslTemplate(path: template)
                }
            }
            return try material.pipeline(base: base.descriptor, device: device, variant: variant, defines: macros) {
                try fragmentTemplate(path: template)
            }
        #endif
    }

    /// Where the surface templates' `package::` imports resolve.
    public static var weslPackageRoot: URL {
        Bundle.adaModule.resourceURL?.appendingPathComponent("Shaders", isDirectory: true) ?? URL(fileURLWithPath: "/")
    }

    /// A surface template in the language the active renderer links: WESL where it is supported, GLSL otherwise.
    public static func surfaceTemplatePath(_ name: String) -> String {
        Flat3DPipeline.shaderPath.hasSuffix(".wesl") ? "Shaders/\(name).wesl" : "Shaders/\(name).glsl"
    }

    /// The WESL source of a surface template; its `// ADA_GRAPH_SOURCE_MARKER` line receives the graph's WGSL.
    public static func weslTemplate(path: String = "Shaders/flat3d.wesl") throws -> String {
        guard let url = Bundle.adaModule.resourceURL?.appendingPathComponent(path),
            let data = FileSystem.current.readFile(at: url),
            let source = String(bytes: data, encoding: .utf8) else {
            throw ShaderGraphDiagnostic(code: .invalidReference, nodeID: path)
        }
        return source
    }

    /// The production surface/silhouette fragment used by offline graph export.
    public static func fragmentTemplate(path: String = "Shaders/flat3d.glsl") throws -> String {
        guard let url = Bundle.adaModule.resourceURL?.appendingPathComponent(path),
            let fragment = try ShaderSource(from: url).getSource(for: .fragment) else {
            throw ShaderGraphDiagnostic(code: .invalidReference, nodeID: path)
        }
        return fragment
    }
}
