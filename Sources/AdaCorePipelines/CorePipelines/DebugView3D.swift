import AdaECS

/// Developer visualizations of the 3D frame, selected per camera through ``Environment3D/debugView``.
///
/// Most modes replace the final image with data the main pass already writes (normals, view position,
/// roughness/metallic, indirect light) or that SSAO produces. ``albedo``, ``cascades`` and ``lightCount``
/// instead make the main pass write their colors into scene color, which the same fullscreen pass shows.
/// Enabling a view adds one fullscreen pass and `.none` adds nothing. ``wireframe`` draws the main pass with
/// line fill; backends without polygon fill modes (WebGPU) render it solid.
public enum DebugView3D: String, Codable, Sendable, CaseIterable {
    /// Normal rendering.
    case none
    /// View-space normals remapped to `0...1`.
    case normals
    /// Linear view depth, near surfaces dark and far surfaces light.
    case depth
    /// Perceptual roughness as grayscale.
    case roughness
    /// Metallic as grayscale.
    case metallic
    /// Filtered screen-space ambient occlusion. White when SSAO is disabled.
    case ambientOcclusion
    /// Ambient and image-based light the main pass accumulated before reflections, brightened with an
    /// exponential curve so the usually dim values are readable.
    case indirectLighting
    /// Main pass rendered with line fill.
    case wireframe
    /// Base color (texture times factor) before lighting, sRGB encoded.
    case albedo
    /// Directional-shadow cascade each pixel samples: red, green and blue for cascades 0 to 2, dark gray
    /// beyond the shadow distance and mid gray where shadows are off or the mesh does not receive them.
    case cascades
    /// Number of lights reaching each pixel as a blue-to-red ramp (eight or more lights is red).
    case lightCount
    /// Stable colors of the prepared triangle clusters. Unsupported surfaces are gray.
    case meshlets

    /// Shader selector; ``none`` and ``wireframe`` never reach the debug pass.
    var shaderMode: Float {
        switch self {
        case .none, .wireframe: 0
        case .normals: 1
        case .depth: 2
        case .roughness: 3
        case .metallic: 4
        case .ambientOcclusion: 5
        case .indirectLighting: 6
        case .albedo, .cascades, .lightCount, .meshlets: 7
        }
    }

    /// Selector the main pass reads (`u_ShadowAtlas.w`) to write this view's colors into scene color.
    /// Zero keeps normal shading.
    var mainPassMode: Float {
        switch self {
        case .albedo: 1
        case .cascades: 2
        case .lightCount: 3
        case .meshlets: 4
        default: 0
        }
    }

    /// Whether the fullscreen debug pass replaces the final image.
    var replacesFinalImage: Bool {
        switch self {
        case .none, .wireframe: false
        default: true
        }
    }
}
