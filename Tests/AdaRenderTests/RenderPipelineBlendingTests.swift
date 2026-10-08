@_spi(Internal) @testable import AdaRender
import Testing

@Suite("Render pipeline blending")
struct RenderPipelineBlendingTests {
    @Test("default translucent blending preserves source alpha coverage")
    func defaultTranslucentBlendingPreservesSourceAlphaCoverage() {
        let attachment = RenderPipelineColorAttachmentDescriptor(
            format: .bgra8,
            isBlendingEnabled: true
        )

        #expect(attachment.sourceRGBBlendFactor == .sourceAlpha)
        #expect(attachment.destinationRGBBlendFactor == .oneMinusSourceAlpha)
        #expect(attachment.sourceAlphaBlendFactor == .one)
        #expect(attachment.destinationAlphaBlendFactor == .oneMinusSourceAlpha)
    }
}
