import AdaECS
import AdaRender
import Math

struct IBL3DUniform: Sendable {
    let inverseView: Transform3D
    let parameters: Vector4
}

public struct IBL3DScratch: Resource, Sendable {
    var cache = FrameUniformCache3D<IBL3DUniform>()
    var uniform = BufferData<IBL3DUniform>(label: "Image Based Lighting", elements: [])
    public init() {}
}
