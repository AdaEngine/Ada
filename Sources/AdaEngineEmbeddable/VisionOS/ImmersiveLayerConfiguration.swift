#if os(visionOS)
    import CompositorServices
    import Metal
    import SwiftUI

    /// Immersive configuration with system foveation when the device supports it.
    @available(visionOS 26.0, *)
    public struct ImmersiveLayerConfiguration: CompositorLayerConfiguration {
        public var enablesFoveation: Bool

        /// Set to false to compare full-resolution rendering on a physical device.
        public init(enablesFoveation: Bool = true) {
            self.enablesFoveation = enablesFoveation
        }

        public func makeConfiguration(
            capabilities: LayerRenderer.Capabilities,
            configuration: inout LayerRenderer.Configuration
        ) {
            configuration.colorFormat = .bgra8Unorm_srgb
            configuration.depthFormat = .depth32Float
            configuration.isFoveationEnabled = enablesFoveation && capabilities.supportsFoveation
            let layouts = capabilities.supportedLayouts(options: configuration.isFoveationEnabled ? [.foveationEnabled] : [])
            configuration.layout = layouts.contains(.dedicated) ? .dedicated : .layered
            configuration.defaultDepthRange = SIMD2<Float>(100, 0.1)
        }
    }
#endif
