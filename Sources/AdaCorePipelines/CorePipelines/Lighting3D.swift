import AdaECS
import AdaRender
import Math

/// A directional light copied from the main world for 3D rendering.
public struct ExtractedDirectionalLight3D: Sendable {
    /// View-independent world-space direction from a shaded surface towards the light.
    public var directionToLight: Vector3
    public var radiance: Vector3
    public var intensity: Float
    public var castsShadows: Bool
    public var shadowDistance: Float
    public var shadowBias: Float
    public var shadowSlopeBias: Float
    public var entity: Entity.ID?

    public init(
        directionToLight: Vector3,
        radiance: Vector3,
        intensity: Float,
        castsShadows: Bool = false,
        shadowDistance: Float = 30,
        shadowBias: Float = 0.0008,
        shadowSlopeBias: Float = 0.003
    ) {
        self.directionToLight = directionToLight
        self.radiance = radiance
        self.intensity = intensity
        self.castsShadows = castsShadows
        self.shadowDistance = shadowDistance
        self.shadowBias = shadowBias
        self.shadowSlopeBias = shadowSlopeBias
    }
}

/// Lighting data copied into the render world every frame.
public struct ExtractedLighting3D: Resource, Sendable {
    public var directionalLight: ExtractedDirectionalLight3D?
    /// All authored active directional lights, with the primary sunlight at index zero.
    public var directionalLights: [ExtractedDirectionalLight3D] = []
    public var localLights: [ExtractedLocalLight3D] = []
    /// Preserve the legacy default sun only when a scene contains no authored lights at all.
    public var hasAuthoredLights = false

    public init(directionalLight: ExtractedDirectionalLight3D? = nil) {
        self.directionalLight = directionalLight
    }
}

/// GPU representation of the primary 3D directional light.
public struct DirectionalLight3DUniform: Sendable {
    /// XYZ is the view-space direction towards the light; W is intensity.
    public var directionIntensity: Vector4
    /// RGB is radiance; W is the temporary ambient fallback strength.
    public var radianceAmbient: Vector4
    /// Matrix that projects world-space positions into the directional shadow map.
    public var shadowViewProjection: Transform3D
    /// X enables shadows, Y is constant bias, Z is slope bias, W is the shadow-map texel size.
    public var shadowParameters: Vector4
    public var shadowViewProjection1: Transform3D
    public var shadowViewProjection2: Transform3D
    public var cascadeSplits: Vector4
    public var shadowAtlas: Vector4

    public init(
        directionIntensity: Vector4,
        radianceAmbient: Vector4,
        shadowViewProjection: Transform3D = .identity,
        shadowParameters: Vector4 = .zero,
        shadowViewProjection1: Transform3D = .identity,
        shadowViewProjection2: Transform3D = .identity,
        cascadeSplits: Vector4 = [1000, 1000, 1000, 1],
        shadowAtlas: Vector4 = [1 / 1024, 1 / 1024, 0.1, 0]
    ) {
        self.directionIntensity = directionIntensity
        self.radianceAmbient = radianceAmbient
        self.shadowViewProjection = shadowViewProjection
        self.shadowParameters = shadowParameters
        self.shadowViewProjection1 = shadowViewProjection1
        self.shadowViewProjection2 = shadowViewProjection2
        self.cascadeSplits = cascadeSplits
        self.shadowAtlas = shadowAtlas
    }
}

/// Reusable GPU buffers for the 3D lighting pass.
public struct Lighting3DGPUScratch: Resource, Sendable {
    public var directionalLight: BufferData<DirectionalLight3DUniform>
    var cache = FrameUniformCache3D<DirectionalLight3DUniform>()

    public init() {
        self.directionalLight = BufferData(label: "Directional Light 3D", elements: [])
    }
}

/// Render-world state for the primary directional-light shadow map.
public struct DirectionalShadow3D: Resource, Sendable {
    public static let resolution = 1024

    public var colorTexture: RenderTexture?
    public var depthTexture: RenderTexture?
    public var viewProjection: Transform3D
    public var isEnabled: Bool
    public var viewProjection1: Transform3D = .identity
    public var viewProjection2: Transform3D = .identity
    public var cascadeSplits: Vector4 = [1000, 1000, 1000, 1]
    public var blendFraction: Float = 0.1

    public init() {
        self.colorTexture = nil
        self.depthTexture = nil
        self.viewProjection = .identity
        self.isEnabled = false
    }
}

/// Uniform data used while rendering the directional shadow map.
public struct DirectionalShadowViewUniform: Sendable {
    public var viewProjection: Transform3D
    public var tileBounds: Vector4

    public init(viewProjection: Transform3D, tileBounds: Vector4 = [0, 0, 1024, 1024]) {
        self.viewProjection = viewProjection
        self.tileBounds = tileBounds
    }
}

/// Reusable GPU storage for the directional shadow pass.
public struct DirectionalShadow3DScratch: Resource, Sendable {
    public var view: BufferData<DirectionalShadowViewUniform>
    var cache = FrameUniformCache3D<DirectionalShadowViewUniform>()

    public init() {
        self.view = BufferData(label: "Directional Shadow View", elements: [])
    }
}
