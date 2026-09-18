//
//  PrepareEnvironment3DTexturesSystem.swift
//  AdaEngine
//

import AdaECS
import AdaRender

/// Allocates the geometry buffers required by skybox and SSR compositing.
@PlainSystem(
    dependencies: [.after("AdaRender.ConfigurateRenderViewTargetSystem")]
)
public struct PrepareEnvironment3DTexturesSystem {
    @Query<Entity, Camera, CameraRenderGraph, Ref<RenderViewTarget>>
    private var cameras

    public init(world _: World) {}

    public func update(context _: UpdateContext) {
        cameras.forEach { _, camera, renderGraph, target in
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
            if target.depthTexture?.size != size {
                target.depthTexture = RenderTexture(
                    size: size,
                    scaleFactor: scale,
                    format: .depth_32f_stencil8,
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
            target.rendering3DUsesEnvironmentTargets = true
        }
    }
}
