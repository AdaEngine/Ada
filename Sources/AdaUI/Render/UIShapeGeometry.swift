import AdaRender

/// Vertex and index ranges of one draw item in a shared, immutable GPU upload.
struct UIShapeGeometry: Sendable {
    var storage = BufferData<UInt8>(elements: [])
    let circleVertices: Int
    let circleIndices: Int
    let lineVertices: Int
    let lineIndices: Int

    static func upload(
        _ items: inout [UIDrawData],
        device: any RenderDevice,
        pool: UIGeometryBufferPool?,
        pageSize: Int = 64 * 1024
    ) {
        var bytes: [UInt8] = []
        var slices: [(Int, Self)] = []

        func flushPage() {
            guard !slices.isEmpty else {
                return
            }
            let label = "UI_ShapeGeometry"
            let lease = pool?.acquire(label: label, byteCount: bytes.count, device: device)
            let buffer = lease?.buffer ?? device.createBuffer(label: label, length: bytes.count, options: .storageShared)
            buffer.setElements(&bytes)
            for (index, var slice) in slices {
                slice.storage.buffer = buffer
                items[index].shapeGeometry = slice
                if let lease { items[index].geometryLeases.append(lease) }
            }
            bytes.removeAll(keepingCapacity: true)
            slices.removeAll(keepingCapacity: true)
        }

        for index in items.indices {
            let item = items[index]
            guard item.shapeGeometry == nil, !item.lineIndexBuffer.isEmpty || !item.circleIndexBuffer.isEmpty,
                item.lineIndexBuffer.buffer == nil, item.circleIndexBuffer.buffer == nil else {
                continue
            }
            let required = maximumBytes(item.circleVertexBuffer) + maximumBytes(item.circleIndexBuffer)
                + maximumBytes(item.lineVertexBuffer) + maximumBytes(item.lineIndexBuffer)
            if required > pageSize {
                // Keep the original per-stream capacity for individually large paths.
                items[index].circleVertexBuffer.write(to: device)
                items[index].circleIndexBuffer.write(to: device)
                items[index].lineVertexBuffer.write(to: device)
                items[index].lineIndexBuffer.write(to: device)
                continue
            }
            if required > pageSize - bytes.count { flushPage() }
            let slice = Self(
                circleVertices: append(item.circleVertexBuffer.elements, to: &bytes),
                circleIndices: append(item.circleIndexBuffer.elements, to: &bytes),
                lineVertices: append(item.lineVertexBuffer.elements, to: &bytes),
                lineIndices: append(item.lineIndexBuffer.elements, to: &bytes)
            )
            slices.append((index, slice))
        }
        flushPage()
    }

    static func maximumBytes<T>(_ data: BufferData<T>) -> Int {
        data.isEmpty ? 0 : data.count * MemoryLayout<T>.stride + max(4, MemoryLayout<T>.alignment) - 1
    }

    static func append<Element>(_ source: [Element], to bytes: inout [UInt8]) -> Int {
        guard !source.isEmpty else {
            return 0
        }
        let alignment = max(4, MemoryLayout<Element>.alignment)
        let padding = (-bytes.count) & (alignment - 1)
        bytes.append(contentsOf: repeatElement(0, count: padding))
        let offset = bytes.count
        unsafe source.withUnsafeBytes { rawBytes in
            unsafe bytes.append(contentsOf: rawBytes)
        }
        return offset
    }
}

/// Offset ranges for the quad and glyph draws of one scissored item.
struct UIQuadGlyphGeometry: Sendable {
    var storage = BufferData<UInt8>(elements: [])
    let quadVertices: Int
    let quadIndices: Int
    let glyphVertices: Int
    let glyphIndices: Int

    static func upload(_ items: inout [UIDrawData], device: any RenderDevice, pool: UIGeometryBufferPool?) {
        let pageSize = 64 * 1024
        var bytes: [UInt8] = []
        var slices: [(Int, Self)] = []

        func flushPage() {
            guard !slices.isEmpty else {
                return
            }
            let label = "UI_QuadGlyphGeometry"
            let lease = pool?.acquire(label: label, byteCount: bytes.count, device: device)
            let buffer = lease?.buffer ?? device.createBuffer(label: label, length: bytes.count, options: .storageShared)
            buffer.setElements(&bytes)
            for (index, var slice) in slices {
                slice.storage.buffer = buffer
                items[index].quadGlyphGeometry = slice
                if let lease { items[index].geometryLeases.append(lease) }
            }
            bytes.removeAll(keepingCapacity: true)
            slices.removeAll(keepingCapacity: true)
        }

        for index in items.indices {
            let item = items[index]
            guard item.quadGlyphGeometry == nil, !item.quadIndexBuffer.isEmpty || !item.glyphIndexBuffer.isEmpty,
                item.quadIndexBuffer.buffer == nil, item.glyphIndexBuffer.buffer == nil else {
                continue
            }
            let required = UIShapeGeometry.maximumBytes(item.quadVertexBuffer) + UIShapeGeometry.maximumBytes(item.quadIndexBuffer)
                + UIShapeGeometry.maximumBytes(item.glyphVertexBuffer) + UIShapeGeometry.maximumBytes(item.glyphIndexBuffer)
            if required > pageSize {
                items[index].quadVertexBuffer.write(to: device)
                items[index].quadIndexBuffer.write(to: device)
                items[index].glyphVertexBuffer.write(to: device)
                items[index].glyphIndexBuffer.write(to: device)
                continue
            }
            if required > pageSize - bytes.count { flushPage() }
            slices.append((index, Self(
                quadVertices: UIShapeGeometry.append(item.quadVertexBuffer.elements, to: &bytes),
                quadIndices: UIShapeGeometry.append(item.quadIndexBuffer.elements, to: &bytes),
                glyphVertices: UIShapeGeometry.append(item.glyphVertexBuffer.elements, to: &bytes),
                glyphIndices: UIShapeGeometry.append(item.glyphIndexBuffer.elements, to: &bytes)
            )))
        }
        flushPage()
    }
}
