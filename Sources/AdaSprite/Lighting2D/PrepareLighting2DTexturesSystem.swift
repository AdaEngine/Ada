//
//  PrepareLighting2DTexturesSystem.swift
//  AdaEngine
//

import AdaECS
import AdaRender
import AdaUtils
import Math

/// Allocates or frees 2D lighting intermediate targets on the active camera view.
@PlainSystem(
    dependencies: [.after("AdaRender.ConfigurateRenderViewTargetSystem")]
)
public struct PrepareLighting2DTexturesSystem {
    @Res<ExtractedLighting2D>
    private var extracted

    @Query<Entity, Camera, Ref<RenderViewTarget>>
    private var cameras

    public init(world _: World) {}

    public func update(context _: UpdateContext) {
        cameras.forEach { _, camera, renderViewTarget in
            guard camera.isActive else {
                renderViewTarget.lighting2DUsesDeferredTargets = false
                return
            }
            let needs = extracted.requiresDeferredPipeline
            guard let mainTexture = renderViewTarget.mainTexture else {
                renderViewTarget.lighting2DUsesDeferredTargets = false
                return
            }
            let size = mainTexture.size
            let scale = mainTexture.scaleFactor
            if !needs {
                renderViewTarget.sceneColorTexture = nil
                renderViewTarget.lightAccumTexture = nil
                renderViewTarget.shadowMaskTexture = nil
                renderViewTarget.lighting2DUsesDeferredTargets = false
                return
            }
            if renderViewTarget.sceneColorTexture?.size != size {
                renderViewTarget.sceneColorTexture = RenderTexture(
                    size: size,
                    scaleFactor: scale,
                    format: .bgra8,
                    debugLabel: "2D Lighting Scene Color"
                )
            }
            if renderViewTarget.lightAccumTexture?.size != size {
                renderViewTarget.lightAccumTexture = RenderTexture(
                    size: size,
                    scaleFactor: scale,
                    format: .rgba_16f,
                    debugLabel: "2D Lighting Accum"
                )
            }
            if renderViewTarget.shadowMaskTexture?.size != size {
                renderViewTarget.shadowMaskTexture = RenderTexture(
                    size: size,
                    scaleFactor: scale,
                    format: .bgra8,
                    debugLabel: "2D Lighting Shadow Mask"
                )
            }
            renderViewTarget.lighting2DUsesDeferredTargets = true
        }
    }
}
