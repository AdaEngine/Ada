import AdaECS
import AdaRender
import AdaUtils
import Math

/// Sprite preparation strategy, applied to `SpriteDrawData` in the render world.
public enum SpriteRenderingMode: Equatable, Sendable {
    /// Use instanced vertex inputs when the device supports them.
    case automatic
    /// Expand CPU vertices and indices, including on devices supporting instancing.
    /// Useful as a correctness/performance reference.
    case batched
}

/// One local layout quad, with an affine world plane and four cropped/flipped UVs.
/// Six vec4 values give the same 96-byte layout in Swift, Metal and WebGPU.
struct SpriteInstanceData: Sendable {
    let origin: Vector4
    let axisX: Vector4
    let axisY: Vector4
    let color: Color
    let bottomUV: Vector4
    let topUV: Vector4

    init(destination: Rect, source: Rect, textureCoordinates: [Vector2], transform: Transform3D, color: Color) {
        origin = transform * Vector4(destination.minX, destination.minY, 0, 1)
        axisX = transform * Vector4(destination.width, 0, 0, 0)
        axisY = transform * Vector4(0, destination.height, 0, 0)
        self.color = color
        func uv(_ u: Float, _ v: Float) -> Vector2 {
            let bottom = textureCoordinates[0] + (textureCoordinates[1] - textureCoordinates[0]) * u
            let top = textureCoordinates[3] + (textureCoordinates[2] - textureCoordinates[3]) * u
            return bottom + (top - bottom) * v
        }
        let bottomLeft = uv(source.minX, source.minY)
        let bottomRight = uv(source.maxX, source.minY)
        let topLeft = uv(source.minX, source.maxY)
        let topRight = uv(source.maxX, source.maxY)
        bottomUV = Vector4(bottomLeft.x, bottomLeft.y, bottomRight.x, bottomRight.y)
        topUV = Vector4(topLeft.x, topLeft.y, topRight.x, topRight.y)
    }
}

struct SpriteInstancingData: Sendable {
    var instances = BufferData<SpriteInstanceData>(label: "Sprite Instances", elements: [])
    var quad = BufferData<Vector2>(label: "Shared Sprite Quad", elements: [[0, 0], [1, 0], [1, 1], [0, 1]])
    var indices = BufferData<UInt32>(label: "Shared Sprite Indices", elements: [0, 1, 2, 2, 3, 0])
    private var pipelines: RenderPipelines<SpriteInstancedRenderPipeline>?
    private var buffers: [(any Buffer)?] = []
    private var slot = 0

    mutating func pipeline(device: RenderDevice) -> RenderPipeline {
        var cached = pipelines ?? RenderPipelines(configurator: SpriteInstancedRenderPipeline())
        let result = cached.pipeline(device: device)
        pipelines = cached
        return result
    }

    mutating func upload(to device: RenderDevice) {
        if quad.buffer == nil { quad.write(to: device); indices.write(to: device) }
        let frames = max(1, unsafe RenderEngine.configurations.maxFramesInFlight)
        if buffers.count != frames { buffers = Array(repeating: nil, count: frames); slot = 0 }
        slot = (slot + 1) % frames
        // Reuse CPU storage while rotating GPU storage, following the engine's in-flight frame budget.
        instances.buffer = buffers[slot]
        instances.write(to: device)
        buffers[slot] = instances.buffer
    }
}
