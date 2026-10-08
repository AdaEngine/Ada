//
//  GlassBackgroundCapture.swift
//  AdaEngine
//

import AdaECS
import AdaRender
import Math

/// Holds the captured background texture used by the glass effect.
///
/// Updated inside ``UIRenderNode`` immediately before drawing each UI batch that contains
/// glass: the render pass is ended, the camera main target is blitted into this texture on
/// the **same** command buffer, then the UI pass continues with ``loadAction`` so prior
/// pixels (ECS, `.background()`, etc.) stay in the main target. Glass quads sample this
/// texture for blur and refraction.
///
/// Rendering owns mutation of this resource during the draw pass; the unchecked
/// conformance mirrors other render resources passed through ECS storage.
public final class GlassBackgroundTexture: Resource, @unchecked Sendable {
    public var texture: RenderTexture?

    public init() {}
}
