//
//  DebugPhysics3DSystem.swift
//  AdaEngine
//
//

import AdaCorePipelines
import AdaECS
@_spi(Internal) import AdaRender
import AdaTransform
import AdaUtils
import Math

public struct ExtractedPhysicsDebugShapes3D: Resource {
    public var lines: [DebugLine] = []

    public struct DebugLine: Sendable {
        public let start: Vector3
        public let end: Vector3
        public let color: Color
    }
}

public struct PhysicsDebug3DDrawData: Resource, DefaultValue {
    public var lineVertexBuffer: BufferData<LineVertexData>
    public var lineIndexBuffer: BufferData<UInt32>

    public static let defaultValue = Self(
        lineVertexBuffer: .init(label: "PhysicsDebug3D_LineVertexBuffer", elements: []),
        lineIndexBuffer: .init(label: "PhysicsDebug3D_LineIndexBuffer", elements: [])
    )
}

public struct PhysicsDebug3DBatches: Resource {
    public struct LineBatch: Sendable {
        public var range: Range<Int32>
    }

    public var lineBatch: LineBatch?

    public init() {}
}

@System
public func ExtractPhysicsDebug3D(
    _ extractedShapes: ResMut<ExtractedPhysicsDebugShapes3D>,
    _ debugOptions: Extract<Res<PhysicsDebugOptions>>,
    _ physicsBodies: Extract<Query<PhysicsBody3DComponent, Transform>>
) {
    extractedShapes.lines.removeAll(keepingCapacity: true)

    let options = debugOptions().wrappedValue
    guard !options.isEmpty else {
        return
    }

    physicsBodies.wrappedValue.forEach { physicsBody, transform in
        let worldTransform = transform.matrix

        if options.contains(.showPhysicsShapes) {
            for shape in physicsBody.shapes {
                appendShapeLines(
                    for: shape,
                    to: extractedShapes,
                    transform: worldTransform,
                    color: .fromHex(0x4DD6FF)
                )
            }
        }

        if options.contains(.showBoundingBoxes),
            let bounds = combinedLocalBounds(for: physicsBody.shapes) {
            appendAABBLines(
                bounds.transformed(by: worldTransform),
                to: extractedShapes,
                color: .fromHex(0xFFD166)
            )
        }
    }
}

@PlainSystem
public struct PreparePhysicsDebug3DSystem: Sendable {
    @ResMut<RenderItems<Transparent2DRenderItem>>
    private var renderItems

    @ResMut
    private var linePipeline: RenderPipelines<LinePipeline>

    @Res
    private var renderDevice: RenderDeviceHandler

    @Res<ExtractedPhysicsDebugShapes3D>
    private var extractedShapes

    @Res
    private var lineDrawPass: PhysicsDebug3DLineDrawPass

    public init(world _: World) {}

    public func update(context _: UpdateContext) {
        guard !extractedShapes.lines.isEmpty else {
            return
        }

        let pipeline = linePipeline.pipeline(device: renderDevice.renderDevice)
        renderItems.items.append(
            Transparent2DRenderItem(
                entity: 0,
                drawPass: lineDrawPass,
                renderPipeline: pipeline,
                sortKey: .greatestFiniteMagnitude,
                batchRange: 0..<Int32(extractedShapes.lines.count)
            )
        )
    }
}

@PlainSystem
public struct PhysicsDebug3DRenderSystem: Sendable {
    @Res<ExtractedPhysicsDebugShapes3D>
    private var extractedShapes

    @ResMut<PhysicsDebug3DDrawData>
    private var drawData

    @ResMut<PhysicsDebug3DBatches>
    private var batches

    @Res<RenderDeviceHandler>
    private var renderDevice

    public init(world _: World) {}

    public func update(context _: UpdateContext) {
        drawData.lineVertexBuffer.elements.removeAll(keepingCapacity: true)
        drawData.lineIndexBuffer.elements.removeAll(keepingCapacity: true)
        batches.lineBatch = nil

        guard !extractedShapes.lines.isEmpty else {
            return
        }

        for line in extractedShapes.lines {
            let vertexOffset = UInt32(drawData.lineVertexBuffer.count)
            drawData.lineVertexBuffer.append(
                LineVertexData(position: line.start, color: line.color, lineWidth: 1.0)
            )
            drawData.lineVertexBuffer.append(
                LineVertexData(position: line.end, color: line.color, lineWidth: 1.0)
            )
            drawData.lineIndexBuffer.append(vertexOffset)
            drawData.lineIndexBuffer.append(vertexOffset + 1)
        }

        batches.lineBatch = .init(range: 0..<Int32(extractedShapes.lines.count))

        let device = renderDevice.renderDevice
        drawData.lineVertexBuffer.write(to: device)
        drawData.lineIndexBuffer.write(to: device)
    }
}

public struct PhysicsDebug3DLineDrawPass: DrawPass, Resource {
    public typealias Item = Transparent2DRenderItem

    public init() {}

    public func render(
        with renderEncoder: RenderCommandEncoder,
        world: World,
        view _: Entity,
        item: Transparent2DRenderItem
    ) throws {
        guard
            let drawData = world.getResource(PhysicsDebug3DDrawData.self),
            let batches = world.getResource(PhysicsDebug3DBatches.self),
            let batch = batches.lineBatch,
            !drawData.lineVertexBuffer.isEmpty
        else {
            return
        }

        renderEncoder.pushDebugName("PhysicsDebug3DLineDrawPass")
        defer { renderEncoder.popDebugName() }

        renderEncoder.setVertexBuffer(drawData.lineVertexBuffer, offset: 0, slot: 0)
        renderEncoder.setIndexBuffer(drawData.lineIndexBuffer, indexFormat: .uInt32)
        renderEncoder.setRenderPipelineState(item.renderPipeline)

        let lineCount = Int(batch.range.upperBound - batch.range.lowerBound)
        renderEncoder.drawIndexed(
            indexCount: lineCount * 2,
            indexBufferOffset: 0,
            instanceCount: 1
        )
    }
}

private func appendShapeLines(
    for shape: Shape3DResource,
    to extractedShapes: ResMut<ExtractedPhysicsDebugShapes3D>,
    transform: Transform3D,
    color: Color
) {
    switch shape.fixture {
    case let .box(box):
        appendOrientedBoxLines(
            halfExtents: box.halfExtents,
            transform: transform,
            to: extractedShapes,
            color: color
        )
    case let .sphere(sphere):
        appendSphereLines(
            center: sphere.center,
            radius: sphere.radius,
            transform: transform,
            to: extractedShapes,
            color: color
        )
    }
}

private func combinedLocalBounds(for shapes: [Shape3DResource]) -> AABB? {
    guard !shapes.isEmpty else {
        return nil
    }

    var minimum = Vector3(Float.greatestFiniteMagnitude)
    var maximum = Vector3(-Float.greatestFiniteMagnitude)

    for shape in shapes {
        switch shape.fixture {
        case let .box(box):
            minimum = min(minimum, -box.halfExtents)
            maximum = max(maximum, box.halfExtents)
        case let .sphere(sphere):
            let extents = Vector3(sphere.radius)
            minimum = min(minimum, sphere.center - extents)
            maximum = max(maximum, sphere.center + extents)
        }
    }

    return AABB(min: minimum, max: maximum)
}

private func appendOrientedBoxLines(
    halfExtents: Vector3,
    transform: Transform3D,
    to extractedShapes: ResMut<ExtractedPhysicsDebugShapes3D>,
    color: Color
) {
    let corners = [
        Vector3(-halfExtents.x, -halfExtents.y, -halfExtents.z),
        Vector3(halfExtents.x, -halfExtents.y, -halfExtents.z),
        Vector3(halfExtents.x, halfExtents.y, -halfExtents.z),
        Vector3(-halfExtents.x, halfExtents.y, -halfExtents.z),
        Vector3(-halfExtents.x, -halfExtents.y, halfExtents.z),
        Vector3(halfExtents.x, -halfExtents.y, halfExtents.z),
        Vector3(halfExtents.x, halfExtents.y, halfExtents.z),
        Vector3(-halfExtents.x, halfExtents.y, halfExtents.z),
    ]
    .map { (transform * Vector4($0, 1)).xyz }

    appendBoxEdges(corners: corners, to: extractedShapes, color: color)
}

private func appendSphereLines(
    center: Vector3,
    radius: Float,
    transform: Transform3D,
    to extractedShapes: ResMut<ExtractedPhysicsDebugShapes3D>,
    color: Color,
    segments: Int = 24
) {
    guard segments >= 3 else {
        return
    }

    let planes: [(Vector3, Vector3)] = [
        (.right, .up),
        (.right, [0, 0, 1]),
        (.up, [0, 0, 1]),
    ]

    for (axisA, axisB) in planes {
        for index in 0..<segments {
            let currentAngle = (Float(index) / Float(segments)) * 2 * .pi
            let nextAngle = (Float(index + 1) / Float(segments)) * 2 * .pi

            let current =
                center
                + axisA * (Math.cos(currentAngle) * radius)
                + axisB * (Math.sin(currentAngle) * radius)
            let next =
                center
                + axisA * (Math.cos(nextAngle) * radius)
                + axisB * (Math.sin(nextAngle) * radius)

            extractedShapes.lines.append(
                .init(
                    start: (transform * Vector4(current, 1)).xyz,
                    end: (transform * Vector4(next, 1)).xyz,
                    color: color
                )
            )
        }
    }
}

private func appendAABBLines(
    _ bounds: AABB,
    to extractedShapes: ResMut<ExtractedPhysicsDebugShapes3D>,
    color: Color
) {
    let min = bounds.min
    let max = bounds.max
    let corners = [
        Vector3(min.x, min.y, min.z),
        Vector3(max.x, min.y, min.z),
        Vector3(max.x, max.y, min.z),
        Vector3(min.x, max.y, min.z),
        Vector3(min.x, min.y, max.z),
        Vector3(max.x, min.y, max.z),
        Vector3(max.x, max.y, max.z),
        Vector3(min.x, max.y, max.z),
    ]

    appendBoxEdges(corners: corners, to: extractedShapes, color: color)
}

private func appendBoxEdges(
    corners: [Vector3],
    to extractedShapes: ResMut<ExtractedPhysicsDebugShapes3D>,
    color: Color
) {
    let edges = [
        (0, 1), (1, 2), (2, 3), (3, 0),
        (4, 5), (5, 6), (6, 7), (7, 4),
        (0, 4), (1, 5), (2, 6), (3, 7),
    ]

    for (start, end) in edges {
        extractedShapes.lines.append(
            .init(start: corners[start], end: corners[end], color: color)
        )
    }
}

extension AABB {
    func transformed(by transform: Transform3D) -> AABB {
        let min = self.min
        let max = self.max
        var transformedMin = (transform * Vector4(min, 1)).xyz
        var transformedMax = transformedMin

        for corner in [
            Vector3(min.x, min.y, max.z),
            Vector3(min.x, max.y, min.z),
            Vector3(min.x, max.y, max.z),
            Vector3(max.x, min.y, min.z),
            Vector3(max.x, min.y, max.z),
            Vector3(max.x, max.y, min.z),
            max,
        ] {
            let transformedCorner = (transform * Vector4(corner, 1)).xyz
            transformedMin = Math.min(transformedMin, transformedCorner)
            transformedMax = Math.max(transformedMax, transformedCorner)
        }

        return AABB(min: transformedMin, max: transformedMax)
    }
}
