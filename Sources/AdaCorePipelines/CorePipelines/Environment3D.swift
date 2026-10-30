//
//  Environment3D.swift
//  AdaEngine
//

import AdaAssets
import AdaECS
import AdaRender
import AdaUtils

/// Controls a procedural star field rendered as part of a 3D skybox.
public struct Starfield3D: Codable, Sendable {
    public var isEnabled: Bool
    public var density: Float
    public var intensity: Float
    public var size: Float
    public var seed: Float

    public init(
        isEnabled: Bool = false,
        density: Float = 0.18,
        intensity: Float = 2,
        size: Float = 1,
        seed: Float = 0
    ) {
        self.isEnabled = isEnabled
        self.density = density
        self.intensity = intensity
        self.size = size
        self.seed = seed
    }
}

/// Describes a sky rendered behind a 3D scene.
public struct Skybox3D: Codable, Sendable {
    /// Optional equirectangular (longitude/latitude) environment texture.
    public var texture: AssetHandle<Texture2D>?
    public var zenithColor: Color
    public var horizonColor: Color
    public var groundColor: Color
    public var intensity: Float
    public var isEnabled: Bool
    public var starfield: Starfield3D

    public init(
        texture: AssetHandle<Texture2D>? = nil,
        zenithColor: Color = Color(red: 0.12, green: 0.28, blue: 0.55),
        horizonColor: Color = Color(red: 0.62, green: 0.72, blue: 0.82),
        groundColor: Color = Color(red: 0.08, green: 0.09, blue: 0.11),
        intensity: Float = 1,
        isEnabled: Bool = true,
        starfield: Starfield3D = Starfield3D()
    ) {
        self.texture = texture
        self.zenithColor = zenithColor
        self.horizonColor = horizonColor
        self.groundColor = groundColor
        self.intensity = intensity
        self.isEnabled = isEnabled
        self.starfield = starfield
    }
}

/// Quality and appearance controls for screen-space reflections.
public struct ScreenSpaceReflection: Codable, Sendable {
    public var isEnabled: Bool
    /// Maximum ray length in view-space units.
    public var maxDistance: Float
    /// Distance between ray-marching samples in view-space units.
    public var stride: Float
    /// Depth tolerance used to accept an intersection.
    public var thickness: Float
    /// Maximum number of samples. Values above 64 are clamped by the shader.
    public var maxSteps: Int
    public var intensity: Float
    /// Width of the screen-edge fade in normalized UV coordinates.
    public var edgeFade: Float

    public init(
        isEnabled: Bool = true,
        maxDistance: Float = 35,
        stride: Float = 0.25,
        thickness: Float = 0.18,
        maxSteps: Int = 48,
        intensity: Float = 0.7,
        edgeFade: Float = 0.08
    ) {
        self.isEnabled = isEnabled
        self.maxDistance = maxDistance
        self.stride = stride
        self.thickness = thickness
        self.maxSteps = maxSteps
        self.intensity = intensity
        self.edgeFade = edgeFade
    }
}

/// An offline-baked environment shared by cameras; intensity is linear radiance scaling.
public struct ImageBasedLightingSettings: Codable, Sendable {
    public var asset: AssetHandle<ImageBasedLighting3D>
    public var intensity: Float
    public var rotation: Float

    public init(asset: AssetHandle<ImageBasedLighting3D>, intensity: Float = 1, rotation: Float = 0) {
        self.asset = asset
        self.intensity = intensity
        self.rotation = rotation
    }
}

/// Environment settings consumed by the main 3D render graph.
@Component
public struct Environment3D: Codable, Sendable {
    public var skybox: Skybox3D
    /// Displays IBL radiance as the sky when available. False uses the skybox texture or procedural sky
    /// while preserving the IBL asset and its contribution to material lighting.
    public var skyboxUsesImageBasedLighting: Bool = true
    public var screenSpaceReflection: ScreenSpaceReflection
    public var imageBasedLighting: ImageBasedLightingSettings?
    /// Optional parallax volume for the static IBL capture. Nil retains infinite-distance environment lighting.
    public var localEnvironmentProbe: LocalEnvironmentProbe3D? = nil
    public var screenSpaceGI: ScreenSpaceGI3D = ScreenSpaceGI3D()
    public var contactShadows: ContactShadows3D = ContactShadows3D()
    public var irradianceProbes: IrradianceProbeSettings3D? = nil

    public var shadows: ShadowSettings3D
    public var ambientOcclusion: ScreenSpaceAO3D
    public var antiAliasing: AntiAliasing3D
    public var meshVisibility: MeshVisibilitySettings3D
    public var localShadows: LocalShadowSettings3D = LocalShadowSettings3D()
    /// Developer visualization for this camera. Defaults to normal rendering.
    public var debugView: DebugView3D = DebugView3D.none
    /// Exposure and bloom applied before tone mapping.
    public var postProcess: PostProcess3D = PostProcess3D()
    /// Distance and height fog applied in linear HDR before tone mapping.
    public var fog: Fog3D = Fog3D()
    /// Evaluate only the local lights that reach each screen tile. Disabling it falls back to the flat per-pixel loop.
    public var tiledLocalLights: Bool = true

    public var screenSpaceGIEnabled: Bool {
        get { screenSpaceGI.isEnabled }
        set { screenSpaceGI.isEnabled = newValue }
    }

    /// Flat reflected atmosphere controls preserve the other nested environment settings.
    public var skyZenithColor: Color {
        get { skybox.zenithColor }
        set { skybox.zenithColor = newValue }
    }
    public var skyHorizonColor: Color {
        get { skybox.horizonColor }
        set { skybox.horizonColor = newValue }
    }
    public var skyGroundColor: Color {
        get { skybox.groundColor }
        set { skybox.groundColor = newValue }
    }
    public var skyIntensity: Float {
        get { skybox.intensity }
        set { skybox.intensity = newValue }
    }
    public var starfieldEnabled: Bool {
        get { skybox.starfield.isEnabled }
        set { skybox.starfield.isEnabled = newValue }
    }
    public var starfieldIntensity: Float {
        get { skybox.starfield.intensity }
        set { skybox.starfield.intensity = newValue }
    }
    /// Linear IBL scaling. An absent IBL reads as zero; writing does not create or load one.
    public var imageBasedLightingIntensity: Float {
        get { imageBasedLighting?.intensity ?? 0 }
        set { imageBasedLighting?.intensity = newValue }
    }
    public var fogColor: Color {
        get { fog.color }
        set { fog.color = newValue }
    }

    /// Flat reflected controls for script and inspector access to render quality settings.
    public var shadowsEnabled: Bool {
        get { shadows.isEnabled }
        set { shadows.isEnabled = newValue }
    }
    public var shadowCascadeCount: Int {
        get { shadows.cascadeCount }
        set { shadows.cascadeCount = min(max(newValue, 1), 3) }
    }
    public var ambientOcclusionEnabled: Bool {
        get { ambientOcclusion.isEnabled }
        set { ambientOcclusion.isEnabled = newValue }
    }
    public var fxaaEnabled: Bool {
        get { antiAliasing == .fxaa }
        set { antiAliasing = newValue ? .fxaa : .none }
    }
    public var frustumCullingEnabled: Bool {
        get { meshVisibility.frustumCulling }
        set { meshVisibility.frustumCulling = newValue }
    }
    public var meshLODEnabled: Bool {
        get { meshVisibility.lod }
        set { meshVisibility.lod = newValue }
    }
    /// Enables current-frame Hi-Z occlusion and indirect draws on Metal and WebGPU.
    /// Other backends retain CPU visibility. Disabled by default because the depth prepass has a cost.
    public var gpuOcclusionEnabled: Bool {
        get { meshVisibility.gpuOcclusion }
        set { meshVisibility.gpuOcclusion = newValue }
    }
    public var exposureEV: Float {
        get { postProcess.exposureEV }
        set { postProcess.exposureEV = newValue }
    }
    public var toneMapper: ToneMapper3D {
        get { postProcess.toneMapper }
        set { postProcess.toneMapper = newValue }
    }
    public var vignetteIntensity: Float {
        get { postProcess.vignette.intensity }
        set { postProcess.vignette.intensity = newValue }
    }
    public var saturation: Float {
        get { postProcess.colorGrading.saturation }
        set { postProcess.colorGrading.saturation = newValue }
    }
    public var contrast: Float {
        get { postProcess.colorGrading.contrast }
        set { postProcess.colorGrading.contrast = newValue }
    }
    public var depthOfFieldEnabled: Bool {
        get { postProcess.depthOfField.isEnabled }
        set { postProcess.depthOfField.isEnabled = newValue }
    }
    public var focusDistance: Float {
        get { postProcess.depthOfField.focusDistance }
        set { postProcess.depthOfField.focusDistance = newValue }
    }
    public var depthOfFieldAperture: Float {
        get { postProcess.depthOfField.aperture }
        set { postProcess.depthOfField.aperture = newValue }
    }
    public var depthOfFieldMaximumRadius: Float {
        get { postProcess.depthOfField.maximumBlurRadius }
        set { postProcess.depthOfField.maximumBlurRadius = newValue }
    }
    public var lensEnabled: Bool {
        get { postProcess.lens.isEnabled }
        set { postProcess.lens.isEnabled = newValue }
    }
    public var lensDistortion: Float {
        get { postProcess.lens.distortion }
        set { postProcess.lens.distortion = newValue }
    }
    public var chromaticAberration: Float {
        get { postProcess.lens.chromaticAberration }
        set { postProcess.lens.chromaticAberration = newValue }
    }
    public var edgeSoftness: Float {
        get { postProcess.lens.edgeSoftness }
        set { postProcess.lens.edgeSoftness = newValue }
    }
    public var filmGrain: Float {
        get { postProcess.lens.filmGrain }
        set { postProcess.lens.filmGrain = newValue }
    }
    public var rainLensAmount: Float {
        get { postProcess.lens.rainAmount }
        set { postProcess.lens.rainAmount = newValue }
    }
    public var rainLensTime: Float {
        get { postProcess.lens.rainTime }
        set { postProcess.lens.rainTime = newValue }
    }
    public var motionBlurEnabled: Bool {
        get { postProcess.motionBlur.isEnabled }
        set { postProcess.motionBlur.isEnabled = newValue }
    }
    public var shutterAngle: Float {
        get { postProcess.motionBlur.shutterAngle }
        set { postProcess.motionBlur.shutterAngle = newValue }
    }
    public var motionBlurMaximumVelocity: Float {
        get { postProcess.motionBlur.maximumVelocity }
        set { postProcess.motionBlur.maximumVelocity = newValue }
    }
    public var motionBlurSamples: Int {
        get { postProcess.motionBlur.sampleCount }
        set { postProcess.motionBlur.sampleCount = newValue }
    }
    public var autoExposureEnabled: Bool {
        get { postProcess.autoExposure.isEnabled }
        set { postProcess.autoExposure.isEnabled = newValue }
    }
    public var autoExposureMinimumEV: Float {
        get { postProcess.autoExposure.minimumEV }
        set { postProcess.autoExposure.minimumEV = newValue }
    }
    public var autoExposureMaximumEV: Float {
        get { postProcess.autoExposure.maximumEV }
        set { postProcess.autoExposure.maximumEV = newValue }
    }
    public var autoExposureSpeedUp: Float {
        get { postProcess.autoExposure.speedUp }
        set { postProcess.autoExposure.speedUp = newValue }
    }
    public var autoExposureSpeedDown: Float {
        get { postProcess.autoExposure.speedDown }
        set { postProcess.autoExposure.speedDown = newValue }
    }
    public var bloomEnabled: Bool {
        get { postProcess.bloom.isEnabled }
        set { postProcess.bloom.isEnabled = newValue }
    }
    public var bloomIntensity: Float {
        get { postProcess.bloom.intensity }
        set { postProcess.bloom.intensity = newValue }
    }
    public var bloomThreshold: Float {
        get { postProcess.bloom.threshold }
        set { postProcess.bloom.threshold = newValue }
    }
    public var fogEnabled: Bool {
        get { fog.isEnabled }
        set { fog.isEnabled = newValue }
    }
    public var fogDensity: Float {
        get { fog.density }
        set { fog.density = newValue }
    }
    public var localShadowsEnabled: Bool {
        get { localShadows.isEnabled }
        set { localShadows.isEnabled = newValue }
    }

    public init(
        skybox: Skybox3D = Skybox3D(),
        screenSpaceReflection: ScreenSpaceReflection = ScreenSpaceReflection(),
        imageBasedLighting: ImageBasedLightingSettings? = nil,
        shadows: ShadowSettings3D = ShadowSettings3D(),
        ambientOcclusion: ScreenSpaceAO3D = ScreenSpaceAO3D(),
        antiAliasing: AntiAliasing3D = .none
    ) {
        self.init(
            skybox: skybox,
            screenSpaceReflection: screenSpaceReflection,
            imageBasedLighting: imageBasedLighting,
            shadows: shadows,
            ambientOcclusion: ambientOcclusion,
            antiAliasing: antiAliasing,
            meshVisibility: MeshVisibilitySettings3D()
        )
    }

    public init(
        skybox: Skybox3D = Skybox3D(),
        screenSpaceReflection: ScreenSpaceReflection = ScreenSpaceReflection(),
        imageBasedLighting: ImageBasedLightingSettings? = nil,
        shadows: ShadowSettings3D = ShadowSettings3D(),
        ambientOcclusion: ScreenSpaceAO3D = ScreenSpaceAO3D(),
        antiAliasing: AntiAliasing3D = .none,
        meshVisibility: MeshVisibilitySettings3D
    ) {
        self.skybox = skybox
        self.screenSpaceReflection = screenSpaceReflection
        self.imageBasedLighting = imageBasedLighting
        self.shadows = shadows
        self.ambientOcclusion = ambientOcclusion
        self.antiAliasing = antiAliasing
        self.meshVisibility = meshVisibility
    }

    private enum CodingKeys: CodingKey {
        case skybox, skyboxUsesImageBasedLighting, screenSpaceReflection, imageBasedLighting, shadows,
             ambientOcclusion, antiAliasing, meshVisibility, localShadows, debugView, postProcess, fog, tiledLocalLights, localEnvironmentProbe, screenSpaceGI, contactShadows, irradianceProbes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        skybox = try container.decodeIfPresent(Skybox3D.self, forKey: .skybox) ?? Skybox3D()
        skyboxUsesImageBasedLighting = try container.decodeIfPresent(Bool.self, forKey: .skyboxUsesImageBasedLighting) ?? true
        screenSpaceReflection = try container.decodeIfPresent(ScreenSpaceReflection.self, forKey: .screenSpaceReflection) ?? ScreenSpaceReflection()
        imageBasedLighting = try container.decodeIfPresent(ImageBasedLightingSettings.self, forKey: .imageBasedLighting)
        localEnvironmentProbe = try container.decodeIfPresent(LocalEnvironmentProbe3D.self, forKey: .localEnvironmentProbe)
        screenSpaceGI = try container.decodeIfPresent(ScreenSpaceGI3D.self, forKey: .screenSpaceGI) ?? ScreenSpaceGI3D()
        contactShadows = try container.decodeIfPresent(ContactShadows3D.self, forKey: .contactShadows) ?? ContactShadows3D()
        irradianceProbes = try container.decodeIfPresent(IrradianceProbeSettings3D.self, forKey: .irradianceProbes)
        shadows = try container.decodeIfPresent(ShadowSettings3D.self, forKey: .shadows) ?? ShadowSettings3D()
        ambientOcclusion = try container.decodeIfPresent(ScreenSpaceAO3D.self, forKey: .ambientOcclusion) ?? ScreenSpaceAO3D()
        antiAliasing = try container.decodeIfPresent(AntiAliasing3D.self, forKey: .antiAliasing) ?? .none
        meshVisibility = try container.decodeIfPresent(MeshVisibilitySettings3D.self, forKey: .meshVisibility) ?? MeshVisibilitySettings3D()
        localShadows = try container.decodeIfPresent(LocalShadowSettings3D.self, forKey: .localShadows) ?? LocalShadowSettings3D()
        debugView = try container.decodeIfPresent(DebugView3D.self, forKey: .debugView) ?? DebugView3D.none
        postProcess = try container.decodeIfPresent(PostProcess3D.self, forKey: .postProcess) ?? PostProcess3D()
        fog = try container.decodeIfPresent(Fog3D.self, forKey: .fog) ?? Fog3D()
        tiledLocalLights = try container.decodeIfPresent(Bool.self, forKey: .tiledLocalLights) ?? true
    }
}

extension Environment3D {
    /// Whether a pass after the color writers (a full-screen debug view or depth of field) still writes the
    /// output, so earlier passes must not yet report it as ready to present.
    var laterPassesWriteOutput: Bool {
        debugView.replacesFinalImage || postProcess.depthOfField.changesImage || cameraEffectsWriteOutput
    }

    var cameraEffectsWriteOutput: Bool { postProcess.lens.changesImage || postProcess.motionBlur.changesImage }
}

/// Extracted environments keyed by the source camera entity.
public struct ExtractedEnvironment3D: Resource, Sendable {
    public var environments: [Entity.ID: Environment3D] = [:]

    public init() {}
}

@System
public func ExtractEnvironment3D(
    _ query: Extract<Query<Entity, Environment3D>>,
    _ extracted: ResMut<ExtractedEnvironment3D>
) {
    extracted.environments.removeAll(keepingCapacity: true)
    query.wrappedValue.forEach { entity, environment in
        extracted.environments[entity.id] = environment
    }
}
