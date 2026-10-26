//
//  ScreenSpaceReflectionRenderNode.swift
//  AdaEngine
//

import AdaAssets
import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Math

/// Composites screen-space reflections and the camera skybox into the main target.
public struct ScreenSpaceReflectionRenderNode: RenderNode {
    public static let name: RenderNodeLabel = .screenSpaceReflection

    @Query<Entity, Camera, RenderViewTarget, GlobalViewUniform, ExtractedCameraSource>
    private var query

    @Res<ExtractedEnvironment3D>
    private var environments

    @Res<ExtractedLighting3D>
    private var lighting

    @Res<ScreenSpaceReflectionPipeline>
    private var pipeline

    @ResMut<ScreenSpaceReflectionScratch>
    private var scratch

    @Res<RenderDeviceHandler>
    private var renderDevice

    private let notifiesCompletion: Bool

    @Res<Render3DPerformanceMetrics?> private var metrics
    @Res<ExtractedDebugLines3D> private var overlays
    @Res<Bloom3DViews> private var bloomViews
    @Res<VolumetricFog3DViews> private var volumetricViews
    @Res<AutoExposure3DViews> private var autoExposureViews

    public init(notifiesCompletion: Bool = true) {
        self.notifiesCompletion = notifiesCompletion
    }

    public func update(from world: World) {
        _metrics.update(from: world)
        _overlays.update(from: world)
        _bloomViews.update(from: world)
        _volumetricViews.update(from: world)
        _autoExposureViews.update(from: world)
        query.update(from: world)
        _environments.update(from: world)
        _lighting.update(from: world)
        _pipeline.update(from: world)
        _scratch.update(from: world)
        _renderDevice.update(from: world)
        var activeViews: [Entity.ID] = []
        query.forEach { _, _, _, _, source in activeViews.append(source.entityId) }
        scratch.cache.retainViews(activeViews)
    }

    public func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        guard let view = context.viewEntity else {
            return []
        }

        var submitted: CommandBuffer?
        query.forEach { entity, camera, target, viewUniform, source in
            guard
                entity == view,
                target.rendering3DUsesEnvironmentTargets,
                let sceneColor = target.sceneColor3DTexture,
                let normalRoughness = target.normalRoughness3DTexture,
                let viewPositionMetallic = target.viewPositionMetallic3DTexture,
                let mainTexture = target.mainTexture
            else {
                return
            }

            let environment = environments.environments[source.entityId] ?? Environment3D()
            let compositeTarget = target.temporalUpscalingActive ? (target.temporalInputTexture ?? mainTexture)
                : (environment.antiAliasing == .none ? mainTexture : (target.antiAliasing3DInputTexture ?? mainTexture))
            let jitteredUniform = temporalViewUniform(viewUniform, target: target)
            let gradingLUT = environment.postProcess.colorGrading.activeLUT
            let autoExposureTexture = environment.postProcess.autoExposure.isEnabled ? autoExposureViews.output(view: source.entityId) : nil
            let bloomTexture = environment.postProcess.bloom.isEnabled ? bloomViews.output(view: source.entityId) : nil
            let skybox = environment.skybox
            let reflection = environment.screenSpaceReflection
            let skyIntensity = max(0, skybox.intensity)
            let fog = environment.fog.sanitized
            let fogActive = environment.fog.changesImage
            let shafts = fogActive && environment.fog.volumetricActive ? volumetricViews.output(view: source.entityId) : nil
            let sun = lighting.directionalLight
            let fogSunDirection = sun?.directionToLight.normalized ?? Vector3(0, 1, 0)
            let fogSunRadiance = sun.map { $0.radiance * $0.intensity } ?? .zero
            let uniform = Environment3DUniform(
                projection: jitteredUniform.projectionMatrix,
                inverseProjection: jitteredUniform.projectionMatrix.inverse,
                inverseView: viewUniform.viewMatrix.inverse,
                zenithColor: skybox.zenithColor.asVector,
                horizonColor: skybox.horizonColor.asVector,
                groundColor: skybox.groundColor.asVector,
                clearColor: camera.backgroundColor.asVector,
                reflection: Vector4(
                    reflection.isEnabled ? 1 : 0,
                    max(0, reflection.maxDistance),
                    max(0.001, reflection.stride),
                    max(0.001, reflection.thickness)
                ),
                reflectionQuality: Vector4(
                    Float(min(max(reflection.maxSteps, 1), 64)),
                    max(0, reflection.intensity),
                    min(max(reflection.edgeFade, 0.001), 0.5),
                    0
                ),
                environmentFlags: Vector4(
                    skybox.isEnabled ? 1 : 0,
                    skybox.texture == nil ? 0 : 1,
                    skyIntensity,
                    skybox.starfield.isEnabled ? 1 : 0
                ),
                starfield: Vector4(
                    min(max(skybox.starfield.density, 0), 1),
                    max(skybox.starfield.intensity, 0),
                    max(skybox.starfield.size, 0.1),
                    skybox.starfield.seed
                ),
                ibl: Vector4(
                    environment.imageBasedLighting?.asset.asset == nil ? 0 : 1,
                    max(0, environment.imageBasedLighting?.intensity ?? 1),
                    environment.imageBasedLighting?.rotation ?? 0,
                    environment.skyboxUsesImageBasedLighting && environment.imageBasedLighting?.asset.asset?.radiance != nil ? 1 : 0
                ),
                quality: Vector4(
                    environment.ambientOcclusion.isEnabled ? 1 : 0,
                    finiteRenderValue(environment.ambientOcclusion.radius, fallback: 0.65, range: 0.05...3),
                    target.temporalUpscalingActive ? 1 : 0,
                    0
                ),
                postProcess: Vector4(
                    environment.postProcess.exposureScale,
                    bloomTexture == nil ? 0 : environment.postProcess.bloom.sanitized.intensity,
                    environment.postProcess.toneMapper.shaderMode,
                    gradingLUT?.intensity ?? 0
                ),
                grading: Vector4(
                    environment.postProcess.colorGrading.sanitized.saturation,
                    environment.postProcess.colorGrading.sanitized.contrast,
                    environment.postProcess.vignette.sanitized.intensity,
                    environment.postProcess.vignette.sanitized.radius
                ),
                vignette: Vector4(environment.postProcess.vignette.sanitized.smoothness, autoExposureTexture == nil ? 0 : 1, 0, 0),
                fogColor: Vector4(fog.color.asVector.xyz, fogActive ? fog.density : 0),
                fogShape: Vector4(fog.heightFalloff, fog.baseHeight, fog.startDistance, fog.maximumOpacity),
                fogRange: Vector4(fog.skyInfluence, fog.sunExponent, shafts == nil ? 0 : 1, 0),
                fogSun: Vector4(fogSunDirection, fogActive && shafts == nil ? fog.sunInscattering : 0),
                fogSunColor: Vector4(fogSunRadiance, 0)
            )
            let constants = scratch.cache.write(uniform, view: source.entityId, device: renderDevice.renderDevice)

            let environmentTexture = skybox.texture?.asset ?? Texture2D.whiteTexture
            let commandBuffer = renderContext.commandQueue.makeCommandBuffer()
            commandBuffer.label = "Screen Space Reflection Composite"
            let pass = commandBuffer.beginRenderPass(
                RenderPassDescriptor(
                    label: "Screen Space Reflection Composite",
                    colorAttachments: [
                        .init(
                            texture: compositeTarget,
                            operation: OperationDescriptor(loadAction: .clear, storeAction: .store),
                            clearColor: camera.backgroundColor
                        ),
                    ],
                    depthStencilAttachment: nil
                )
            )
            pass.setViewport(camera.viewport.rect)
            pass.setResourceSet(
                RenderResourceSet(
                    bindings: [
                        .init(binding: 8, shaderStages: .fragment, resource: .texture(target.indirectLighting3DTexture ?? Texture2D.whiteTexture)),
                        .init(binding: 9, shaderStages: .fragment, resource: .texture(target.ambientOcclusion3DTexture ?? Texture2D.whiteTexture)),
                        .init(binding: 11, shaderStages: .fragment, resource: .sampler(pipeline.nearest)),
                        .init(binding: 12, shaderStages: .fragment, resource: .texture(bloomTexture ?? Texture2D.whiteTexture)),
                        .init(binding: 16, shaderStages: .fragment, resource: .texture(shafts ?? Texture2D.whiteTexture)),
                        .init(binding: 13, shaderStages: .fragment, resource: .texture(gradingLUT?.texture ?? Texture2D.whiteTexture)),
                        .init(binding: 14, shaderStages: .fragment, resource: .sampler(pipeline.sampler)),
                        .init(binding: 15, shaderStages: .fragment, resource: .texture(autoExposureTexture ?? Texture2D.whiteTexture)),
                        .init(binding: 0, shaderStages: .fragment, resource: .texture(sceneColor)),
                        .init(binding: 1, shaderStages: .fragment, resource: .texture(normalRoughness)),
                        .init(binding: 2, shaderStages: .fragment, resource: .texture(viewPositionMetallic)),
                        .init(binding: 3, shaderStages: .fragment, resource: .sampler(pipeline.sampler)),
                        .init(binding: 6, shaderStages: .fragment, resource: .texture(environment.imageBasedLighting?.asset.asset?.radiance ?? Texture2D.whiteTexture)),
                        .init(binding: 7, shaderStages: .fragment, resource: .sampler((environment.imageBasedLighting?.asset.asset?.radiance ?? Texture2D.whiteTexture).sampler)),
                        .init(binding: 5, shaderStages: .fragment, resource: .texture(environmentTexture)),
                    ]
                ),
                index: 0
            )
            pass.setFragmentBuffer(constants, offset: 0, slot: 4)
            pass.setRenderPipelineState(target.temporalUpscalingActive ? pipeline.hdrRenderPipeline : pipeline.renderPipeline)
            pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
            pass.endRenderPass()
            if notifiesCompletion, !overlays.hasOverlay, environment.antiAliasing == .none, !environment.laterPassesWriteOutput, let outputTexture = target.outputTexture,
               mainTexture === outputTexture {
                commandBuffer.addCompletedHandler { [outputTexture] in
                    outputTexture.notifyRenderCompleted()
                }
            }
            if let metrics {
                commandBuffer.addCompletedTimingHandler { metrics.record(pass: "composite", seconds: $0) }
            }
            submitted = commandBuffer
        }

        if let submitted {
            if let metrics { await metrics.commit(submitted) } else { submitted.commit() }
        }
        return []
    }
}
