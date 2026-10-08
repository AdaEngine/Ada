//
//  DebugPhysics2DSystem.swift
//  AdaEngine
//
//  Created by v.prusakov on 2/26/23.
//

import AdaCorePipelines
import AdaECS
@_spi(Internal) import AdaRender
import AdaTransform
import AdaUtils
import box2d
import Math

public struct PhysicsDebugOptions: OptionSet, Resource {
    public var rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// Draw physics collision shapes for physics object.
    public static let showPhysicsShapes = Self(rawValue: 1 << 0)

    public static let showBoundingBoxes = Self(rawValue: 1 << 1)
}

// MARK: - Extracted Debug Shapes

/// Contains extracted debug shapes for rendering.
public struct ExtractedPhysicsDebugShapes: Resource {
    public var lines: [DebugLine] = []
    public var circles: [DebugCircle] = []

    public struct DebugLine: Sendable {
        public let start: Vector2
        public let end: Vector2
        public let color: Color
    }

    public struct DebugCircle: Sendable {
        public let center: Vector2
        public let radius: Float
        public let color: Color
    }
}

// MARK: - Draw Data Resources

/// A data for drawing physics debug shapes.
public struct PhysicsDebugDrawData: Resource, DefaultValue {
    public var lineVertexBuffer: BufferData<LineVertexData>
    public var lineIndexBuffer: BufferData<UInt32>
    public var circleVertexBuffer: BufferData<CircleVertexData>
    public var circleIndexBuffer: BufferData<UInt32>

    public static let defaultValue: PhysicsDebugDrawData = {
        Self(
            lineVertexBuffer: .init(label: "PhysicsDebug_LineVertexBuffer", elements: []),
            lineIndexBuffer: .init(label: "PhysicsDebug_LineIndexBuffer", elements: []),
            circleVertexBuffer: .init(label: "PhysicsDebug_CircleVertexBuffer", elements: []),
            circleIndexBuffer: .init(label: "PhysicsDebug_CircleIndexBuffer", elements: [])
        )
    }()
}

/// Batches for physics debug rendering.
public struct PhysicsDebugBatches: Resource {
    public struct LineBatch: Sendable {
        public var range: Range<Int32>
    }

    public struct CircleBatch: Sendable {
        public var range: Range<Int32>
    }

    public var lineBatch: LineBatch?
    public var circleBatch: CircleBatch?

    public init() {}
}

// MARK: - Debug Draw Context

/// Context for collecting debug draw calls from Box2D.
private final class WorldDebugDrawContext {
    var lines: [ExtractedPhysicsDebugShapes.DebugLine] = []
    var circles: [ExtractedPhysicsDebugShapes.DebugCircle] = []

    func addLine(start: Vector2, end: Vector2, color: Color) {
        self.lines.append(.init(start: start, end: end, color: color))
    }

    func addCircle(center: Vector2, radius: Float, color: Color) {
        self.circles.append(.init(center: center, radius: radius, color: color))
    }

    func clear() {
        lines.removeAll(keepingCapacity: true)
        circles.removeAll(keepingCapacity: true)
    }
}

// MARK: - Box2D Debug Draw Callbacks

private func DebugPhysicsExctract2DSystem_DrawSolidCircle(
    _ transform: b2Transform,
    _ radius: Float,
    _ color: b2HexColor,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else {
        return
    }
    let debugContext = unsafe Unmanaged<WorldDebugDrawContext>
        .fromOpaque(context)
        .takeUnretainedValue()

    let color = Color.fromHex(Int(color.rawValue))

    let center = Vector2(transform.p.x, transform.p.y)

    debugContext.addCircle(center: center, radius: radius, color: color)

    // Draw direction indicator line
    let direction = Vector2(
        transform.q.c * radius,  // cos(angle) * radius
        transform.q.s * radius  // sin(angle) * radius
    )

    let start = center
    let end = center + direction

    debugContext.addLine(start: start, end: end, color: color)
}

private func DebugPhysicsExctract2DSystem_DrawSolidPolygon(
    _ transform: b2Transform,
    _ verticies: UnsafePointer<b2Vec2>?,
    _ vertexCount: Int32,
    _: Float,
    _ color: b2HexColor,
    _ context: UnsafeMutableRawPointer?
) {
    guard let verticies = unsafe verticies else {
        return
    }
    guard let context else {
        return
    }

    let debugContext = unsafe Unmanaged<WorldDebugDrawContext>
        .fromOpaque(context)
        .takeUnretainedValue()
    let color = Color.fromHex(Int(color.rawValue))

    let vertices = (0..<vertexCount)
        .map { index in
            unsafe verticies[Int(index)].asVector2
        }

    for i in 0..<vertexCount {
        let start = vertices[Int(i)]
        let end = vertices[Int((Int(i) + 1) % Int(vertexCount))]

        let startTransformed = Vector2(
            transform.q.c * start.x - transform.q.s * start.y + transform.p.x,
            transform.q.s * start.x + transform.q.c * start.y + transform.p.y
        )

        let endTransformed = Vector2(
            transform.q.c * end.x - transform.q.s * end.y + transform.p.x,
            transform.q.s * end.x + transform.q.c * end.y + transform.p.y
        )

        debugContext.addLine(start: startTransformed, end: endTransformed, color: color)
    }
}

// MARK: - Extract System

/// System for extracting physics bodies for debug rendering.
@System
public func ExtractPhysicsDebug(
    _ extractedShapes: ResMut<ExtractedPhysicsDebugShapes>,
    _ debugOptions: Extract<Res<PhysicsDebugOptions>>,
    _ physicsWorld: Extract<
        Res<Physics2DWorldHolder>
    >
) {
    extractedShapes.lines.removeAll(keepingCapacity: true)
    extractedShapes.circles.removeAll(keepingCapacity: true)

    guard debugOptions().wrappedValue.contains(.showPhysicsShapes) else {
        return
    }

    let drawContext = WorldDebugDrawContext()

    var debugDraw = unsafe b2DefaultDebugDraw()
    unsafe debugDraw.DrawSolidPolygon = DebugPhysicsExctract2DSystem_DrawSolidPolygon
    unsafe debugDraw.DrawSolidCircle = DebugPhysicsExctract2DSystem_DrawSolidCircle
    unsafe debugDraw.context = Unmanaged.passUnretained(drawContext).toOpaque()
    unsafe debugDraw.drawShapes = true
    unsafe debugDraw.drawAABBs = false

    unsafe physicsWorld().world.debugDraw(with: debugDraw)

    extractedShapes.lines = drawContext.lines
    extractedShapes.circles = drawContext.circles
}

// MARK: - Prepare System

/// System for preparing physics debug render items.
@PlainSystem
public struct PreparePhysicsDebugSystem: Sendable {
    @ResMut<RenderItems<Transparent2DRenderItem>>
    private var renderItems

    @ResMut
    private var linePipeline: RenderPipelines<LinePipeline>

    @ResMut
    private var circlePipeline: RenderPipelines<CirclePipeline>

    @Res
    private var renderDevice: RenderDeviceHandler

    @Res<ExtractedPhysicsDebugShapes>
    private var extractedShapes

    @Res
    private var lineDrawPass: PhysicsDebugLineDrawPass

    @Res
    private var circleDrawPass: PhysicsDebugCircleDrawPass

    public init(world _: World) {}

    public func update(context _: UpdateContext) {
        // Skip if no shapes to render
        if extractedShapes.lines.isEmpty && extractedShapes.circles.isEmpty {
            return
        }

        // Add line render item if we have lines
        if !extractedShapes.lines.isEmpty {
            let pipeline = linePipeline.pipeline(device: renderDevice.renderDevice)

            renderItems.items.append(
                Transparent2DRenderItem(
                    entity: 0,
                    drawPass: lineDrawPass,
                    renderPipeline: pipeline,
                    sortKey: .greatestFiniteMagnitude,  // Render on top
                    batchRange: 0..<Int32(extractedShapes.lines.count)
                )
            )
        }

        // Add circle render item if we have circles
        if !extractedShapes.circles.isEmpty {
            let pipeline = circlePipeline.pipeline(device: renderDevice.renderDevice)

            renderItems.items.append(
                Transparent2DRenderItem(
                    entity: 0,
                    drawPass: circleDrawPass,
                    renderPipeline: pipeline,
                    sortKey: .greatestFiniteMagnitude,  // Render on top
                    batchRange: 0..<Int32(extractedShapes.circles.count)
                )
            )
        }
    }
}

// MARK: - Render System

/// System for tessellating and batching physics debug shapes.
@PlainSystem
public struct PhysicsDebugRenderSystem: Sendable {
    /// Quad corner positions for circle SDF rendering.
    private let quadPositions: [Vector4] = [
        [-0.5, -0.5, 0.0, 1.0],
        [0.5, -0.5, 0.0, 1.0],
        [0.5, 0.5, 0.0, 1.0],
        [-0.5, 0.5, 0.0, 1.0],
    ]

    @Res<ExtractedPhysicsDebugShapes>
    private var extractedShapes

    @ResMut<PhysicsDebugDrawData>
    private var drawData

    @ResMut<PhysicsDebugBatches>
    private var batches

    @Res<RenderDeviceHandler>
    private var renderDevice

    public init(world _: World) {}

    public func update(context _: UpdateContext) {
        // Clear previous frame data
        drawData.lineVertexBuffer.elements.removeAll(keepingCapacity: true)
        drawData.lineIndexBuffer.elements.removeAll(keepingCapacity: true)
        drawData.circleVertexBuffer.elements.removeAll(keepingCapacity: true)
        drawData.circleIndexBuffer.elements.removeAll(keepingCapacity: true)
        batches.lineBatch = nil
        batches.circleBatch = nil

        let device = renderDevice.renderDevice

        // Tessellate lines
        if !extractedShapes.lines.isEmpty {
            let lineCount = extractedShapes.lines.count

            for line in extractedShapes.lines {
                let vertexOffset = UInt32(drawData.lineVertexBuffer.count)

                // Add line vertices
                drawData.lineVertexBuffer.append(
                    LineVertexData(
                        position: Vector3(line.start.x, line.start.y, 0),
                        color: line.color,
                        lineWidth: 2.0
                    )
                )
                drawData.lineVertexBuffer.append(
                    LineVertexData(
                        position: Vector3(line.end.x, line.end.y, 0),
                        color: line.color,
                        lineWidth: 2.0
                    )
                )

                // Add line indices
                drawData.lineIndexBuffer.append(vertexOffset)
                drawData.lineIndexBuffer.append(vertexOffset + 1)
            }

            batches.lineBatch = .init(range: 0..<Int32(lineCount))

            drawData.lineVertexBuffer.write(to: device)
            drawData.lineIndexBuffer.write(to: device)
        }

        // Tessellate circles
        if !extractedShapes.circles.isEmpty {
            let circleCount = extractedShapes.circles.count

            for circle in extractedShapes.circles {
                let vertexOffset = UInt32(drawData.circleVertexBuffer.count)

                // Create a transform for the circle
                let scale = circle.radius * 2.0
                let transform = Transform3D(
                    translation: Vector3(circle.center.x, circle.center.y, 0),
                    rotation: .identity,
                    scale: Vector3(scale, scale, 1.0)
                )

                // Tessellate circle into 4 vertices (SDF rendering)
                for quadPos in quadPositions {
                    let worldPos = transform * quadPos
                    let localPos = quadPos * 2  // Scale to [-1, 1] range for SDF

                    drawData.circleVertexBuffer.append(
                        CircleVertexData(
                            worldPosition: worldPos.xyz,
                            localPosition: Vector2(localPos.x, localPos.y),
                            thickness: 0.05,  // Stroke thickness
                            fade: 0.01,  // Anti-aliasing fade
                            color: circle.color
                        )
                    )
                }

                // Add circle indices (2 triangles forming a quad)
                drawData.circleIndexBuffer.append(vertexOffset + 0)
                drawData.circleIndexBuffer.append(vertexOffset + 1)
                drawData.circleIndexBuffer.append(vertexOffset + 2)
                drawData.circleIndexBuffer.append(vertexOffset + 2)
                drawData.circleIndexBuffer.append(vertexOffset + 3)
                drawData.circleIndexBuffer.append(vertexOffset + 0)
            }

            batches.circleBatch = .init(range: 0..<Int32(circleCount))

            drawData.circleVertexBuffer.write(to: device)
            drawData.circleIndexBuffer.write(to: device)
        }
    }
}

// MARK: - Draw Passes

/// Draw pass for rendering physics debug lines.
public struct PhysicsDebugLineDrawPass: DrawPass, Resource {
    public typealias Item = Transparent2DRenderItem

    public init() {}

    public func render(
        with renderEncoder: RenderCommandEncoder,
        world: World,
        view _: Entity,
        item: Transparent2DRenderItem
    ) throws {
        guard
            let drawData = world.getResource(PhysicsDebugDrawData.self),
            let batches = world.getResource(PhysicsDebugBatches.self),
            let batch = batches.lineBatch
        else {
            return
        }

        guard !drawData.lineVertexBuffer.isEmpty else {
            return
        }

        renderEncoder.pushDebugName("PhysicsDebugLineDrawPass")
        defer {
            renderEncoder.popDebugName()
        }

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

/// Draw pass for rendering physics debug circles.
public struct PhysicsDebugCircleDrawPass: DrawPass, Resource {
    public typealias Item = Transparent2DRenderItem

    public init() {}

    public func render(
        with renderEncoder: RenderCommandEncoder,
        world: World,
        view _: Entity,
        item: Transparent2DRenderItem
    ) throws {
        guard
            let drawData = world.getResource(PhysicsDebugDrawData.self),
            let batches = world.getResource(PhysicsDebugBatches.self),
            let batch = batches.circleBatch
        else {
            return
        }

        guard !drawData.circleVertexBuffer.isEmpty else {
            return
        }

        renderEncoder.pushDebugName("PhysicsDebugCircleDrawPass")
        defer {
            renderEncoder.popDebugName()
        }

        renderEncoder.setVertexBuffer(drawData.circleVertexBuffer, offset: 0, slot: 0)
        renderEncoder.setIndexBuffer(drawData.circleIndexBuffer, indexFormat: .uInt32)
        renderEncoder.setRenderPipelineState(item.renderPipeline)

        let circleCount = Int(batch.range.upperBound - batch.range.lowerBound)
        renderEncoder.drawIndexed(
            indexCount: circleCount * 6,  // 6 indices per circle quad
            indexBufferOffset: 0,
            instanceCount: 1
        )
    }
}
