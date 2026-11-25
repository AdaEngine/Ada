import AdaECS
import AdaRender

struct View3DGPUScratch: Resource {
    var cache = FrameUniformCache3D<GlobalViewUniform>()
}

/// Each camera/pass has its own ring; the graph never rewrites constants referenced by another in-flight view.
package struct FrameUniformCache3D<Value: Sendable>: Sendable {
    private struct Key: Hashable { var view: Entity.ID; var pass: Int }
    private struct Entry: Sendable { var buffers: [BufferData<Value>]; var index: Int }
    private var entries: [Key: Entry] = [:]
    private let frames = max(1, unsafe RenderEngine.configurations.maxFramesInFlight)

    package init() {}

    package mutating func retainViews(_ views: [Entity.ID]) {
        guard !entries.keys.allSatisfy({ views.contains($0.view) }) else {
            return
        }
        for key in entries.keys where !views.contains(key.view) { entries.removeValue(forKey: key) }
    }

    package mutating func write(_ value: Value, view: Entity.ID, pass: Int = 0, device: RenderDevice) -> BufferData<Value> {
        let key = Key(view: view, pass: pass)
        var entry = entries.removeValue(forKey: key) ?? Entry(buffers: (0..<frames).map { _ in BufferData(elements: [value]) }, index: 0)
        entry.index = (entry.index + 1) % frames
        // Keep rotating even when the constants are identical. The previous slot may
        // still be sampled by the GPU. Each slot holds only uniforms read by shaders.
        let slot = entry.index
        let alreadyUploaded = entry.buffers[slot].buffer != nil && withUnsafeBytes(of: value) { requested in
            entry.buffers[slot].elements.withUnsafeBytes { stored in
                stored.prefix(requested.count).elementsEqual(requested)
            }
        }
        if !alreadyUploaded {
            entry.buffers[slot].elements[0] = value
            entry.buffers[slot].write(to: device)
        }
        let output = entry.buffers[entry.index]
        entries[key] = entry
        return output
    }
}
