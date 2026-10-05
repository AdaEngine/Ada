//
//  PrepareEnvironment3DTexturesSystem.swift
//  AdaEngine
//

import AdaECS
import AdaRender
import Math

/// Allocates the geometry buffers required by skybox and SSR compositing.
@PlainSystem(
    dependencies: [.after("AdaRender.ConfigurateRenderViewTargetSystem")]
)
public struct PrepareEnvironment3DTexturesSystem {
    @Query<Entity, Camera, CameraRenderGraph, Ref<RenderViewTarget>, ExtractedCameraSource>
    private var cameras

    @Res<ExtractedEnvironment3D> private var environments

    public init(world _: World) {}

    public func update(context _: UpdateContext) {
        cameras.forEach { _, camera, renderGraph, target, source in
            guard
                renderGraph.subgraphLabel == .main3D,
                camera.isActive,
                let mainTexture = target.mainTexture
            else {
                target.rendering3DUsesEnvironmentTargets = false
                return
            }

            let size = mainTexture.size
            let scale = mainTexture.scaleFactor
            let depthFormat: PixelFormat = camera.temporalUpscaling != nil && target.depthTexture?.pixelFormat == .depth_32f ? .depth_32f : .depth_32f_stencil8
            if target.depthTexture?.size != size || target.depthTexture?.pixelFormat != depthFormat {
                target.depthTexture = RenderTexture(
                    size: size,
                    scaleFactor: scale,
                    format: depthFormat,
                    debugLabel: "3D Camera Depth Texture"
                )
            }
            if target.sceneColor3DTexture?.size != size {
                target.sceneColor3DTexture = RenderTexture(
                    size: size,
                    scaleFactor: scale,
                    format: .rgba_16f,
                    debugLabel: "3D Scene Color"
                )
            }
            if target.normalRoughness3DTexture?.size != size {
                target.normalRoughness3DTexture = RenderTexture(
                    size: size,
                    scaleFactor: scale,
                    format: .rgba_16f,
                    debugLabel: "3D View Normal and Roughness"
                )
            }
            if target.viewPositionMetallic3DTexture?.size != size {
                target.viewPositionMetallic3DTexture = RenderTexture(
                    size: size,
                    scaleFactor: scale,
                    format: .rgba_16f,
                    debugLabel: "3D View Position and Metallic"
                )
            }
            if target.indirectLighting3DTexture?.size != size {
                target.indirectLighting3DTexture = RenderTexture(size: size, scaleFactor: scale, format: .rgba_16f, debugLabel: "3D Opaque Indirect Light")
            }
            let environment = environments.environments[source.entityId] ?? Environment3D()
            if environment.ambientOcclusion.isEnabled {
                let halfSize = SizeInt(width: max(1, (size.width + 1) / 2), height: max(1, (size.height + 1) / 2))
                if target.ambientOcclusion3DRawTexture?.size != halfSize {
                    target.ambientOcclusion3DRawTexture = RenderTexture(size: halfSize, scaleFactor: scale, format: .bgra8, debugLabel: "3D SSAO Raw")
                    target.ambientOcclusion3DTexture = RenderTexture(size: halfSize, scaleFactor: scale, format: .bgra8, debugLabel: "3D SSAO Bilateral")
                }
            }
            if environment.antiAliasing != .none, target.antiAliasing3DInputTexture?.size != size {
                target.antiAliasing3DInputTexture = RenderTexture(size: size, scaleFactor: scale, format: .bgra8, debugLabel: "3D Pre AA Color")
            }
            target.rendering3DUsesEnvironmentTargets = true
        }
    }
}
