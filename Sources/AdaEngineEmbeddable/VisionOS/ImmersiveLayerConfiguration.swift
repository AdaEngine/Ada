#if os(visionOS)
    import CompositorServices
    import Metal
    import SwiftUI

    /// Initial immersive configuration: full resolution, dedicated textures, finite clipping range.
    /// Foveation is disabled until Ada's geometry passes support rasterization rate maps.
    @available(visionOS 26.0, *)
    public struct ImmersiveLayerConfiguration: CompositorLayerConfiguration {
        public init() {}

        public func makeConfiguration(
            capabilities: LayerRenderer.Capabilities,
            configuration: inout LayerRenderer.Configuration
        ) {
            configuration.colorFormat = .bgra8Unorm_srgb
            configuration.depthFormat = .depth32Float
            configuration.isFoveationEnabled = false
            configuration.layout = capabilities.supportedLayouts(options: []).contains(.dedicated) ? .dedicated : .layered
            configuration.defaultDepthRange = SIMD2<Float>(100, 0.1)
        }
    }
#endif
