import AdaECS
import AdaRender
import Math

/// Immutable normal transforms shared by terrain tiles with the same owner pose.
/// Camera transforms remain in the existing per-view lighting constants.
public struct Terrain3DUniforms: Resource {
    public static let binding = 52
    private struct Entry {
        let buffer: any UniformBuffer
        var frame: UInt64
    }
    private var entries: [Transform3D: Entry] = [:]
    private var frame: UInt64 = 0

    public init() {}

    public mutating func beginFrame() {
        for (key, entry) in entries where entry.frame != frame { entries.removeValue(forKey: key) }
        frame &+= 1
    }

    public mutating func buffer(for transform: Transform3D, device: RenderDevice) -> (any UniformBuffer)? {
        var linear = transform
        linear.w = [0, 0, 0, 1]
        if var entry = entries[linear] {
            if entry.frame != frame { entry.frame = frame; entries[linear] = entry }
            return entry.buffer
        }
        let inverse = linear.inverse
        // Feeding inverse columns as rows performs the required transpose explicitly.
        let normal = Transform3D(rows: [inverse.x, inverse.y, inverse.z, inverse.w])
        guard [normal.x, normal.y, normal.z, normal.w].allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite }) else {
            return nil
        }
        let buffer = device.createUniformBuffer(Transform3D.self, binding: Self.binding)
        buffer.setData(normal)
        entries[linear] = Entry(buffer: buffer, frame: frame)
        return buffer
    }
}
