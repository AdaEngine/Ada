import AdaECS
import AdaRender

/// Each camera/pass has its own ring; the graph never rewrites constants referenced by another in-flight view.
struct FrameUniformCache3D<Value: Sendable>: Sendable {
    private struct Key: Hashable { var view: Entity.ID; var pass: Int }
    private struct Entry: Sendable { var buffers: [BufferData<Value>]; var index: Int }
    private var entries: [Key: Entry] = [:]
    private let frames = max(1, unsafe RenderEngine.configurations.maxFramesInFlight)

    mutating func retainViews(_ views: [Entity.ID]) {
        guard !entries.keys.allSatisfy({ views.contains($0.view) }) else {
            return
        }
        for key in entries.keys where !views.contains(key.view) { entries.removeValue(forKey: key) }
    }

    mutating func write(_ value: Value, view: Entity.ID, pass: Int = 0, device: RenderDevice) -> BufferData<Value> {
        let key = Key(view: view, pass: pass)
        var entry = entries[key] ?? Entry(buffers: (0..<frames).map { _ in BufferData(elements: [value]) }, index: 0)
        entry.index = (entry.index + 1) % frames
        entry.buffers[entry.index].elements[0] = value
        entry.buffers[entry.index].write(to: device)
        let output = entry.buffers[entry.index]
        entries[key] = entry
        return output
    }
}
