import AdaECS
import AdaRender
import Math

/// Render-world-owned edge buffers. Original vertex indices retain skinning,
/// morphing, instancing and material alpha testing in the ordinary PBR shader.
public struct Wireframe3DResources: Resource {
    private struct Entry {
        let source: any IndexBuffer
        let buffer: any IndexBuffer
        let triangles: [UInt32]
        let bytes: Int
        var used: UInt64
    }
    public var isEnabled = false
    public var drawingEdges = false
    public private(set) var allocatedBytes = 0
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var clock: UInt64 = 0
    private let maximumBytes = 64 * 1_024 * 1_024
    public init() {}

    public mutating func indices(source: any IndexBuffer, triangles: [UInt32], device: RenderDevice) -> (any IndexBuffer)? {
        clock &+= 1
        let key = ObjectIdentifier(source)
        if var entry = entries[key], entry.triangles == triangles {
            entry.used = clock; entries[key] = entry
            return entry.buffer
        }
        // Retained CPU indices establish content identity even when callers reuse
        // a GPU buffer. Equality has a COW identity fast path for immutable inputs.
        guard let lines = TriangleIndexEdges.make(from: triangles, maximumIndices: maximumBytes / 6), !lines.isEmpty else { return nil }
        let length = lines.count * MemoryLayout<UInt32>.stride
        let chargedBytes = length + triangles.count * MemoryLayout<UInt32>.stride
        if let previous = entries.removeValue(forKey: key) { allocatedBytes -= previous.bytes }
        while allocatedBytes > maximumBytes - chargedBytes, let oldest = entries.min(by: { $0.value.used < $1.value.used }) {
            allocatedBytes -= oldest.value.bytes
            entries.removeValue(forKey: oldest.key)
        }
        let buffer: (any IndexBuffer)? = unsafe lines.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return nil }
            return unsafe device.createIndexBuffer(label: "Triangle wireframe edges", format: .uInt32, bytes: base, length: length)
        }
        guard let buffer else { return nil }
        entries[key] = Entry(source: source, buffer: buffer, triangles: triangles, bytes: chargedBytes, used: clock)
        allocatedBytes += chargedBytes
        return buffer
    }
}
