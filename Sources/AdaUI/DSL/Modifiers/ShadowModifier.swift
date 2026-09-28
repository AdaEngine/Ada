import AdaAssets
import AdaRender
import AdaUtils
import Foundation
import Math

/// Shape used to cast a soft shadow around a view's bounds.
public enum ShadowShape: Sendable {
    case rectangle
    case roundedRectangle(cornerRadius: Float)
    case capsule

    fileprivate func cornerRadius(for size: Size) -> Float {
        switch self {
        case .rectangle:
            return 0
        case let .roundedRectangle(cornerRadius):
            return min(max(cornerRadius.isFinite ? cornerRadius : 0, 0), min(size.width, size.height) * 0.5)
        case .capsule:
            return min(size.width, size.height) * 0.5
        }
    }
}

extension View {
    /// Draws a soft outer shadow around the selected bounds shape.
    public func shadow(
        color: Color = .black.opacity(0.25),
        radius: Float = 8,
        x: Float = 0,
        y: Float = 4,
        shape: ShadowShape = .rectangle
    ) -> some View {
        background {
            ShadowBackground(color: color, radius: radius, x: x, y: y, shape: shape)
                .allowsHitTesting(false)
        }
    }
}

private struct ShadowBackground: View {
    let color: Color
    let radius: Float
    let x: Float
    let y: Float
    let shape: ShadowShape

    @State private var material: CustomMaterial<UIShadowMaterial> = CustomMaterial(UIShadowMaterial())

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else {
                return
            }

            let blur = radius.isFinite ? min(max(radius, 0), 64) : 8
            let offsetX = x.isFinite ? min(max(x, -128), 128) : 0
            let offsetY = y.isFinite ? min(max(y, -128), 128) : 0
            let inset = ceil(blur * 3 + max(abs(offsetX), abs(offsetY)) + 2)
            material.parameters = UIShadowParameters(
                color: color,
                geometry: Vector4(size.width, size.height, inset, shape.cornerRadius(for: size)),
                style: Vector4(offsetX, offsetY, blur, context.opacity)
            )
            context.drawShaderEffect(
                Rect(x: -inset, y: -inset, width: size.width + inset * 2, height: size.height + inset * 2),
                material: material
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct UIShadowParameters {
    var color: Color
    var geometry: Vector4
    var style: Vector4
}

struct UIShadowMaterial: UIShaderMaterial {
    @Uniform(binding: 0, propertyName: "UIShadowMaterial") var parameters: UIShadowParameters

    init() {
        parameters = UIShadowParameters(
            color: .clear,
            geometry: Vector4(1, 1, 2, 0),
            style: Vector4(0, 0, 8, 1)
        )
    }

    static func fragmentShader() throws -> AssetHandle<ShaderSource> {
        let relativePath = "Shaders/ui_shadow.glsl"
        #if WASM
            guard let resourceURL = Bundle.module.resourceURL else {
                throw UIShadowResourceError.missingShader
            }
            return AssetHandle(try ShaderSource(from: resourceURL.appendingPathComponent(relativePath)))
        #else
            let bundleName = "AdaEngine_AdaUI.bundle"
            for root in [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap({ $0 }) {
                let shaderURL = root.appendingPathComponent(bundleName).appendingPathComponent(relativePath)
                if FileManager.default.fileExists(atPath: shaderURL.path) {
                    return AssetHandle(try ShaderSource(from: shaderURL))
                }
            }
            guard let resourceURL = Bundle.module.resourceURL else {
                throw UIShadowResourceError.missingShader
            }
            return AssetHandle(try ShaderSource(from: resourceURL.appendingPathComponent(relativePath)))
        #endif
    }

    static func configurePipeline(
        keys _: Set<String>,
        vertex: Shader,
        fragment: Shader,
        vertexDescriptor: VertexDescriptor
    ) throws -> RenderPipelineDescriptor {
        var descriptor = RenderPipelineDescriptor(vertex: vertex)
        descriptor.debugName = "UI Shadow"
        descriptor.fragment = fragment
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.backfaceCulling = true
        descriptor.colorAttachments = [
            RenderPipelineColorAttachmentDescriptor(
                format: .bgra8,
                isBlendingEnabled: true,
                sourceRGBBlendFactor: .one
            )
        ]
        return descriptor
    }
}

private enum UIShadowResourceError: LocalizedError {
    case missingShader

    var errorDescription: String? {
        "UI shadow shader resource is missing."
    }
}
