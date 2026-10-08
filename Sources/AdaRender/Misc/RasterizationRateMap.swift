import Math

/// A frame's immutable mapping from logical screen pixels to physical fragments.
/// Native backends provide these maps; screen-space effects consume the resolved attachments.
public protocol RasterizationRateMap: Sendable {
    var screenSize: SizeInt { get }
}

public enum FoveatedRenderingError: Error {
    case unsupportedBackend
    case invalidAttachments
    case invalidRateMap
    case metalResourceUnavailable
}

/// Geometry encoder and its screen-space resolve, belonging to one command buffer.
/// End the geometry pass before calling ``resolve()`` and commit only after it succeeds.
public struct FoveatedRenderPass {
    public let encoder: any RenderCommandEncoder
    private let resolveAction: () throws -> Void

    init(encoder: any RenderCommandEncoder, resolve: @escaping () throws -> Void) {
        self.encoder = encoder
        self.resolveAction = resolve
    }

    /// Expands color and depth attachments to logical screen coordinates for subsequent passes.
    public func resolve() throws { try resolveAction() }
}
