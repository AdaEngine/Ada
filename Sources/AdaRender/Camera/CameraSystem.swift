//
//  CameraSystem.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/7/22.
//

import AdaAssets
@_spi(Internal) import AdaECS
import AdaTransform
import AdaUtils
import Math

// FIXME: Currently we render on window directly
// TODO: Move window info to ECS system

/// System for updating cameras data on scene.
@PlainSystem
public struct CameraSystem: Sendable {
    @Query<Entity, Ref<Camera>, GlobalTransform>
    private var query

    @Res
    private var primaryWindow: PrimaryWindowId?

    public init(world _: World) {}

    @MainActor
    public func update(context _: UpdateContext) {
        self.query.forEach { entity, camera, globalTransform in
            let viewMatrix = globalTransform.matrix.inverse
            camera.viewMatrix = viewMatrix
            self.updateViewportSizeIfNeeded(for: camera)
            self.updateProjectionMatrix(for: camera)
            self.updateFrustum(for: camera)

            entity.components += GlobalViewUniform(
                projectionMatrix: camera.computedData.projectionMatrix,
                viewProjectionMatrix: camera.computedData.projectionMatrix * viewMatrix,
                viewMatrix: camera.viewMatrix
            )
        }
    }

    @MainActor
    private func updateViewportSizeIfNeeded(
        for camera: Ref<Camera>
    ) {
        var needsUpdateProjection = false

        switch camera.renderTarget {
        case let .window(windowRef):
            guard let primaryWindow else {
                return
            }
            camera.renderTarget = .window(windowRef)

            let resolvedWindowId = windowRef.getWindowId(from: primaryWindow)
            guard
                let renderWindow = unsafe RenderEngine.shared
                    .getRenderWindow(for: resolvedWindowId)
            else {
                return
            }

            camera.computedData.targetScaleFactor = renderWindow.scaleFactor
            if camera.viewport.rect.size != renderWindow.physicalSize {
                camera.viewport.rect.size = renderWindow.physicalSize
                needsUpdateProjection = true
            }
            if camera.logicalViewport.rect.size.toSizeInt() != renderWindow.logicalSize {
                camera.logicalViewport.rect.size = renderWindow.logicalSize.toSize()
                needsUpdateProjection = true
            }

        case let .texture(textureHandle):
            let texture = textureHandle.asset.unwrap(message: "Camera render-target texture is not loaded.")
            let size = Size(width: Float(texture.width), height: Float(texture.height))

            if camera.viewport.rect.size != size {
                camera.viewport.rect.size = size
                needsUpdateProjection = true
            }

            if camera.logicalViewport.rect.size != size {
                camera.logicalViewport.rect.size = (size.asVector2 / texture.scaleFactor).asSize
                needsUpdateProjection = true
            }

            camera.computedData.targetScaleFactor = texture.scaleFactor
        }

        if needsUpdateProjection {
            let viewportSize = camera.logicalViewport.rect.size
            camera.projection.updateView(
                width: viewportSize.width,
                height: viewportSize.height
            )
        }
    }

    private func updateFrustum(for camera: Ref<Camera>) {
        camera.computedData.frustum = camera.projection
            .makeFrustum(from: camera.viewMatrix)
    }

    private func updateProjectionMatrix(for camera: Ref<Camera>) {
        camera.computedData.projectionMatrix = camera.projection.makeClipView()
    }
}
