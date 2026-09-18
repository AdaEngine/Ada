//
//  UITessellator.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 19.12.2025.
//

import AdaCorePipelines
import AdaRender
import AdaText
import AdaUtils
import Math

/// Tessellator for converting UI draw commands into vertex and index data.
public struct UITessellator {
    /// Quad corner positions in local space (centered at origin).
    public static let quadPositions: [Vector4] = [
        [-0.5, -0.5, 0.0, 1.0],
        [0.5, -0.5, 0.0, 1.0],
        [0.5, 0.5, 0.0, 1.0],
        [-0.5, 0.5, 0.0, 1.0],
    ]

    /// Default texture coordinates for a quad.
    public static let defaultTextureCoords: [Vector2] = [
        [0.0, 0.0],
        [1.0, 0.0],
        [1.0, 1.0],
        [0.0, 1.0],
    ]

    /// Texture coordinates for UI gradients. `Rect.toTransform3D` flips the
    /// local Y axis for UI rendering, so gradients need vertically flipped UVs
    /// to keep UnitPoint.top and UnitPoint.bottom visually correct.
    public static let gradientTextureCoords: [Vector2] = [
        [0.0, 1.0],
        [1.0, 1.0],
        [1.0, 0.0],
        [0.0, 0.0],
    ]

    /// Number of segments for Bezier curve tessellation.
    public static let curveSegments: Int = 16

    public init() {}

    // MARK: - Quad Tessellation

    /// Tessellates a quad into 4 vertices.
    /// - Parameters:
    ///   - transform: The transformation matrix for the quad.
    ///   - texture: Optional texture for the quad.
    ///   - color: Color of the quad.
    ///   - textureIndex: Index into the texture array.
    /// - Returns: Array of 4 quad vertices.
    public func tessellateQuad(
        transform: Transform3D,
        texture: Texture2D?,
        color: Color,
        textureIndex: Int
    ) -> [QuadVertexData] {
        let textureCoords = texture?.textureCoordinates ?? Self.defaultTextureCoords

        return Self.quadPositions.enumerated()
            .map { index, quadPos in
                QuadVertexData(
                    position: transform * quadPos,
                    color: color,
                    textureCoordinate: textureCoords[index],
                    textureIndex: textureIndex
                )
            }
    }

    /// Generates 6 indices for a quad starting at the given vertex offset.
    /// - Parameter vertexOffset: The starting vertex index.
    /// - Returns: Array of 6 indices forming 2 triangles.
    public func generateQuadIndices(vertexOffset: UInt32) -> [UInt32] {
        return [
            vertexOffset + 0,
            vertexOffset + 1,
            vertexOffset + 2,
            vertexOffset + 2,
            vertexOffset + 3,
            vertexOffset + 0,
        ]
    }

    /// Appends an unclipped quad directly into retained build buffers.
    /// This avoids allocating two short-lived arrays for every UI rectangle.
    func appendQuad(
        transform: Transform3D,
        texture: Texture2D?,
        color: Color,
        textureIndex: Int,
        vertices: inout [QuadVertexData],
        indices: inout [UInt32]
    ) {
        let vertexOffset = UInt32(vertices.count)
        let textureCoords = texture?.textureCoordinates ?? Self.defaultTextureCoords
        for (index, quadPosition) in Self.quadPositions.enumerated() {
            vertices.append(
                QuadVertexData(
                    position: transform * quadPosition,
                    color: color,
                    textureCoordinate: textureCoords[index],
                    textureIndex: textureIndex
                )
            )
        }
        appendQuadIndices(vertexOffset: vertexOffset, to: &indices)
    }

    /// Appends an unclipped gradient quad without intermediate arrays.
    func appendLinearGradient(
        transform: Transform3D,
        vertices: inout [QuadVertexData],
        indices: inout [UInt32]
    ) {
        let vertexOffset = UInt32(vertices.count)
        for (index, quadPosition) in Self.quadPositions.enumerated() {
            vertices.append(
                QuadVertexData(
                    position: transform * quadPosition,
                    color: .white,
                    textureCoordinate: Self.gradientTextureCoords[index],
                    textureIndex: 0
                )
            )
        }
        appendQuadIndices(vertexOffset: vertexOffset, to: &indices)
    }

    func tessellateClippedQuad(
        transform: Transform3D,
        texture: Texture2D?,
        color: Color,
        textureIndex: Int,
        clipPolygons: [[Vector2]]
    ) -> (vertices: [QuadVertexData], indices: [UInt32]) {
        let vertices = tessellateQuad(
            transform: transform,
            texture: texture,
            color: color,
            textureIndex: textureIndex
        )
        return clipQuadVertices(vertices, to: clipPolygons)
    }

    /// Tessellates a linear gradient quad into 4 vertices.
    public func tessellateLinearGradient(
        transform: Transform3D
    ) -> [QuadVertexData] {
        Self.quadPositions.enumerated()
            .map { index, quadPos in
                QuadVertexData(
                    position: transform * quadPos,
                    color: .white,
                    textureCoordinate: Self.gradientTextureCoords[index],
                    textureIndex: 0
                )
            }
    }

    func tessellateClippedLinearGradient(
        transform: Transform3D,
        clipPolygons: [[Vector2]]
    ) -> (vertices: [QuadVertexData], indices: [UInt32]) {
        clipQuadVertices(tessellateLinearGradient(transform: transform), to: clipPolygons)
    }

    /// Tessellates a custom shader effect quad into 4 vertices.
    public func tessellateShaderEffect(
        transform: Transform3D
    ) -> [QuadVertexData] {
        tessellateQuad(
            transform: transform,
            texture: nil,
            color: .white,
            textureIndex: 0
        )
    }

    func tessellateClippedShaderEffect(
        transform: Transform3D,
        clipPolygons: [[Vector2]]
    ) -> (vertices: [QuadVertexData], indices: [UInt32]) {
        clipQuadVertices(tessellateShaderEffect(transform: transform), to: clipPolygons)
    }

    // MARK: - Circle Tessellation

    /// Tessellates a circle into 4 vertices (rendered using SDF in fragment shader).
    /// - Parameters:
    ///   - transform: The transformation matrix for the circle.
    ///   - thickness: Stroke thickness of the circle.
    ///   - fade: Anti-aliasing fade value.
    ///   - color: Color of the circle.
    /// - Returns: Array of 4 circle vertices.
    public func tessellateCircle(
        transform: Transform3D,
        thickness: Float,
        fade: Float,
        color: Color
    ) -> [CircleVertexData] {
        return Self.quadPositions.map { quadPos in
            let worldPos = transform * quadPos
            let localPos = quadPos * 2  // Scale to [-1, 1] range for SDF

            return CircleVertexData(
                worldPosition: worldPos.xyz,
                localPosition: Vector2(localPos.x, localPos.y),
                thickness: thickness,
                fade: fade,
                color: color
            )
        }
    }

    /// Generates 6 indices for a circle quad starting at the given vertex offset.
    /// - Parameter vertexOffset: The starting vertex index.
    /// - Returns: Array of 6 indices forming 2 triangles.
    public func generateCircleIndices(vertexOffset: UInt32) -> [UInt32] {
        return generateQuadIndices(vertexOffset: vertexOffset)
    }

    // MARK: - Line Tessellation

    /// Tessellates a line into 2 vertices.
    /// - Parameters:
    ///   - start: Start position of the line.
    ///   - end: End position of the line.
    ///   - lineWidth: Width of the line.
    ///   - color: Color of the line.
    /// - Returns: Array of 2 line vertices.
    public func tessellateLine(
        start: Vector3,
        end: Vector3,
        lineWidth: Float,
        color: Color
    ) -> [LineVertexData] {
        return [
            LineVertexData(position: start, color: color, lineWidth: lineWidth),
            LineVertexData(position: end, color: color, lineWidth: lineWidth),
        ]
    }

    /// Generates 2 indices for a line starting at the given vertex offset.
    /// - Parameter vertexOffset: The starting vertex index.
    /// - Returns: Array of 2 indices.
    public func generateLineIndices(vertexOffset: UInt32) -> [UInt32] {
        return [vertexOffset, vertexOffset + 1]
    }

    // MARK: - Glyph Tessellation

    /// Tessellates a glyph into 4 vertices.
    /// - Parameters:
    ///   - glyph: The glyph to tessellate.
    ///   - transform: The transformation matrix.
    ///   - textureIndex: Index into the font atlas array.
    ///   - offset: Optional offset to apply to glyph positions (for centering).
    /// - Returns: Array of 4 glyph vertices.
    public func tessellateGlyph(
        _ glyph: Glyph,
        transform: Transform3D,
        textureIndex: Int,
        offset: Vector2 = .zero,
        opacity: Float = 1
    ) -> [GlyphVertexData] {
        let foregroundColor = glyph.attributes.foregroundColor
            .opacity(glyph.attributes.foregroundColor.alpha * opacity)
        let outlineColor = glyph.attributes.outlineColor
            .opacity(glyph.attributes.outlineColor.alpha * opacity)
        let texCoord = glyph.textureCoordinates

        // Glyph position: [x: pl, y: pb, z: pr, w: pt]
        let pos = glyph.position

        // Apply offset to positions
        let x1 = pos.x + offset.x
        let y1 = pos.y + offset.y
        let x2 = pos.z + offset.x
        let y2 = pos.w + offset.y

        return [
            GlyphVertexData(
                position: transform * Vector4(x: x2, y: y1, z: 0, w: 1),
                foregroundColor: foregroundColor,
                outlineColor: outlineColor,
                outlineWidth: glyph.attributes.outlineWidth,
                textureCoordinate: Vector2(texCoord.z, texCoord.y),
                textureIndex: textureIndex
            ),
            GlyphVertexData(
                position: transform * Vector4(x: x2, y: y2, z: 0, w: 1),
                foregroundColor: foregroundColor,
                outlineColor: outlineColor,
                outlineWidth: glyph.attributes.outlineWidth,
                textureCoordinate: Vector2(texCoord.z, texCoord.w),
                textureIndex: textureIndex
            ),
            GlyphVertexData(
                position: transform * Vector4(x: x1, y: y2, z: 0, w: 1),
                foregroundColor: foregroundColor,
                outlineColor: outlineColor,
                outlineWidth: glyph.attributes.outlineWidth,
                textureCoordinate: Vector2(texCoord.x, texCoord.w),
                textureIndex: textureIndex
            ),
            GlyphVertexData(
                position: transform * Vector4(x: x1, y: y1, z: 0, w: 1),
                foregroundColor: foregroundColor,
                outlineColor: outlineColor,
                outlineWidth: glyph.attributes.outlineWidth,
                textureCoordinate: Vector2(texCoord.x, texCoord.y),
                textureIndex: textureIndex
            ),
        ]
    }

    /// Generates 6 indices for a glyph quad starting at the given vertex offset.
    /// - Parameter vertexOffset: The starting vertex index.
    /// - Returns: Array of 6 indices forming 2 triangles.
    public func generateGlyphIndices(vertexOffset: UInt32) -> [UInt32] {
        return generateQuadIndices(vertexOffset: vertexOffset)
    }

    /// Appends an unclipped glyph directly into retained build buffers.
    func appendGlyph(
        _ glyph: Glyph,
        transform: Transform3D,
        textureIndex: Int,
        offset: Vector2 = .zero,
        opacity: Float = 1,
        vertices: inout [GlyphVertexData],
        indices: inout [UInt32]
    ) {
        let vertexOffset = UInt32(vertices.count)
        let foregroundColor = glyph.attributes.foregroundColor
            .opacity(glyph.attributes.foregroundColor.alpha * opacity)
        let outlineColor = glyph.attributes.outlineColor
            .opacity(glyph.attributes.outlineColor.alpha * opacity)
        let textureCoordinates = glyph.textureCoordinates
        let position = glyph.position
        let x1 = position.x + offset.x
        let y1 = position.y + offset.y
        let x2 = position.z + offset.x
        let y2 = position.w + offset.y

        vertices.append(
            GlyphVertexData(
                position: transform * Vector4(x: x2, y: y1, z: 0, w: 1),
                foregroundColor: foregroundColor,
                outlineColor: outlineColor,
                outlineWidth: glyph.attributes.outlineWidth,
                textureCoordinate: Vector2(textureCoordinates.z, textureCoordinates.y),
                textureIndex: textureIndex
            )
        )
        vertices.append(
            GlyphVertexData(
                position: transform * Vector4(x: x2, y: y2, z: 0, w: 1),
                foregroundColor: foregroundColor,
                outlineColor: outlineColor,
                outlineWidth: glyph.attributes.outlineWidth,
                textureCoordinate: Vector2(textureCoordinates.z, textureCoordinates.w),
                textureIndex: textureIndex
            )
        )
        vertices.append(
            GlyphVertexData(
                position: transform * Vector4(x: x1, y: y2, z: 0, w: 1),
                foregroundColor: foregroundColor,
                outlineColor: outlineColor,
                outlineWidth: glyph.attributes.outlineWidth,
                textureCoordinate: Vector2(textureCoordinates.x, textureCoordinates.w),
                textureIndex: textureIndex
            )
        )
        vertices.append(
            GlyphVertexData(
                position: transform * Vector4(x: x1, y: y1, z: 0, w: 1),
                foregroundColor: foregroundColor,
                outlineColor: outlineColor,
                outlineWidth: glyph.attributes.outlineWidth,
                textureCoordinate: Vector2(textureCoordinates.x, textureCoordinates.y),
                textureIndex: textureIndex
            )
        )
        appendQuadIndices(vertexOffset: vertexOffset, to: &indices)
    }

    func tessellateClippedGlyph(
        _ glyph: Glyph,
        transform: Transform3D,
        textureIndex: Int,
        offset: Vector2 = .zero,
        opacity: Float = 1,
        clipPolygons: [[Vector2]]
    ) -> (vertices: [GlyphVertexData], indices: [UInt32]) {
        let vertices = tessellateGlyph(
            glyph,
            transform: transform,
            textureIndex: textureIndex,
            offset: offset,
            opacity: opacity
        )
        return clipGlyphVertices(vertices, to: clipPolygons)
    }

    private func appendQuadIndices(vertexOffset: UInt32, to indices: inout [UInt32]) {
        indices.append(vertexOffset)
        indices.append(vertexOffset + 1)
        indices.append(vertexOffset + 2)
        indices.append(vertexOffset + 2)
        indices.append(vertexOffset + 3)
        indices.append(vertexOffset)
    }

    // MARK: - Glass Tessellation

    /// Tessellates a glass quad into 4 vertices carrying all glass effect parameters.
    ///
    /// - Parameters:
    ///   - transform: World-space transform with the context transform already baked in.
    ///   - halfSize: Half-dimensions of the glass quad in logical pixels (used by the SDF in the shader).
    ///   - configuration: Visual configuration for the glass effect.
    ///   - scaleFactor: Display scale factor (points → physical pixels).
    public func tessellateGlassQuad(
        transform: Transform3D,
        halfSize: Vector2,
        configuration: Glass,
        scaleFactor: Float
    ) -> [GlassVertexData] {
        let glassParams0 = Vector4(
            configuration.blurRadius,
            configuration.cornerRadius,
            configuration.glassTintStrength,
            configuration.edgeShadowStrength
        )
        let glassParams1 = Vector4(
            configuration.cornerRoundnessExponent,
            configuration.glassThickness,
            configuration.refractiveIndex,
            configuration.dispersionStrength
        )
        let glassParams2 = Vector4(
            configuration.fresnelDistanceRange,
            configuration.fresnelIntensity,
            configuration.fresnelEdgeSharpness,
            configuration.glareDistanceRange
        )
        let glassParams3 = Vector4(
            configuration.glareAngleConvergence,
            configuration.glareOppositeSideBias,
            configuration.glareIntensity,
            configuration.glareEdgeSharpness
        )
        let glassInfo0 = Vector4(
            halfSize.x,
            halfSize.y,
            scaleFactor,
            configuration.opacity
        )
        let glassInfo1 = Vector4(
            configuration.glareDirectionOffset,
            0,
            0,
            0
        )

        let tintColor = configuration.tintColor ?? Color(red: 0, green: 0, blue: 0, alpha: 0)
        return Self.quadPositions.enumerated()
            .map { index, quadPos in
                GlassVertexData(
                    position: transform * quadPos,
                    color: tintColor,
                    texCoord: Self.defaultTextureCoords[index],
                    glassParams0: glassParams0,
                    glassParams1: glassParams1,
                    glassParams2: glassParams2,
                    glassParams3: glassParams3,
                    glassInfo0: glassInfo0,
                    glassInfo1: glassInfo1
                )
            }
    }

    // MARK: - Path Tessellation

    /// Tessellates a path stroke into line vertices.
    /// Bezier curves are approximated with line segments.
    /// - Parameters:
    ///   - path: The path to tessellate.
    ///   - lineWidth: Width of the path stroke.
    ///   - color: Color of the path.
    ///   - transform: The transformation matrix.
    /// - Returns: Tuple of vertices and indices for lines.
    public func tessellatePathStroke(
        _ path: Path,
        lineWidth: Float,
        color: Color,
        transform: Transform3D
    ) -> (vertices: [LineVertexData], indices: [UInt32]) {
        var vertices: [LineVertexData] = []
        var indices: [UInt32] = []

        var currentPoint: Vector2?
        var subpathStart: Vector2?

        path.forEach { element in
            switch element {
            case let .move(to: point):
                currentPoint = point
                subpathStart = point

            case let .line(to: end):
                guard let start = currentPoint else {
                    break
                }

                let startWorld = transformedPathPoint(start, with: transform)
                let endWorld = transformedPathPoint(end, with: transform)

                let vertexOffset = UInt32(vertices.count)
                vertices.append(
                    contentsOf: tessellateLine(
                        start: startWorld.xyz,
                        end: endWorld.xyz,
                        lineWidth: lineWidth,
                        color: color
                    )
                )
                indices.append(contentsOf: generateLineIndices(vertexOffset: vertexOffset))

                currentPoint = end

            case let .quadCurve(to: end, control: control):
                guard let start = currentPoint else {
                    break
                }

                // Tessellate quadratic Bezier curve
                let curveVertices = tessellateQuadraticBezier(
                    start: start,
                    control: control,
                    end: end,
                    segments: Self.curveSegments,
                    lineWidth: lineWidth,
                    color: color,
                    transform: transform
                )

                let vertexOffset = UInt32(vertices.count)
                vertices.append(contentsOf: curveVertices.vertices)
                indices.append(contentsOf: curveVertices.indices.map { $0 + vertexOffset })

                currentPoint = end

            case let .curve(to: end, control1: control1, control2: control2):
                guard let start = currentPoint else {
                    break
                }

                // Tessellate cubic Bezier curve
                let curveVertices = tessellateCubicBezier(
                    start: start,
                    control1: control1,
                    control2: control2,
                    end: end,
                    segments: Self.curveSegments,
                    lineWidth: lineWidth,
                    color: color,
                    transform: transform
                )

                let vertexOffset = UInt32(vertices.count)
                vertices.append(contentsOf: curveVertices.vertices)
                indices.append(contentsOf: curveVertices.indices.map { $0 + vertexOffset })

                currentPoint = end

            case .closeSubpath:
                guard let start = currentPoint, let subStart = subpathStart else {
                    break
                }

                let startWorld = transformedPathPoint(start, with: transform)
                let endWorld = transformedPathPoint(subStart, with: transform)

                let vertexOffset = UInt32(vertices.count)
                vertices.append(
                    contentsOf: tessellateLine(
                        start: startWorld.xyz,
                        end: endWorld.xyz,
                        lineWidth: lineWidth,
                        color: color
                    )
                )
                indices.append(contentsOf: generateLineIndices(vertexOffset: vertexOffset))

                currentPoint = nil
                subpathStart = nil
            }
        }

        return (vertices, indices)
    }

    /// Compatibility alias for legacy stroked path rendering.
    public func tessellatePath(
        _ path: Path,
        lineWidth: Float,
        color: Color,
        transform: Transform3D
    ) -> (vertices: [LineVertexData], indices: [UInt32]) {
        tessellatePathStroke(
            path,
            lineWidth: lineWidth,
            color: color,
            transform: transform
        )
    }

    /// Tessellates a path fill into triangle vertices.
    ///
    /// Closed subpaths are flattened into polygons and triangulated using a
    /// simple ear clipping pass. Open subpaths are ignored in fill mode.
    public func tessellatePathFill(
        _ path: Path,
        color: Color,
        transform: Transform3D,
        textureIndex: Int = 0,
        clipPolygons: [[Vector2]]? = nil
    ) -> (vertices: [QuadVertexData], indices: [UInt32]) {
        var vertices: [QuadVertexData] = []
        var indices: [UInt32] = []

        for polygon in flattenClosedSubpaths(from: path) {
            let polygons: [[Vector2]]
            if let clipPolygons {
                let transformedPolygon = polygon.map { point in
                    let transformed = transformedPathPoint(point, with: transform)
                    return Vector2(transformed.x, transformed.y)
                }
                polygons = self.clipPolygons([transformedPolygon], to: clipPolygons)
            } else {
                polygons = [polygon]
            }

            for polygon in polygons {
                let polygonIndices = triangulatePolygon(polygon)
                guard !polygonIndices.isEmpty else {
                    continue
                }

                let vertexOffset = UInt32(vertices.count)
                for point in polygon {
                    let position: Vector4
                    if clipPolygons == nil {
                        position = transformedPathPoint(point, with: transform)
                    } else {
                        position = Vector4(point.x, point.y, 0, 1)
                    }
                    vertices.append(
                        QuadVertexData(
                            position: position,
                            color: color,
                            textureCoordinate: .zero,
                            textureIndex: textureIndex
                        )
                    )
                }
                indices.append(contentsOf: polygonIndices.map { $0 + vertexOffset })
            }
        }

        return (vertices, indices)
    }

    func clipPathPolygons(_ path: Path, transform: Transform3D) -> [[Vector2]] {
        flattenClosedSubpaths(from: path)
            .map { polygon in
                polygon.map { point in
                    let transformed = transformedPathPoint(point, with: transform)
                    return Vector2(transformed.x, transformed.y)
                }
            }
    }

    func clipPolygons(_ polygons: [[Vector2]], to clipPolygons: [[Vector2]]) -> [[Vector2]] {
        var result: [[Vector2]] = []

        for polygon in polygons {
            for clipPolygon in clipPolygons {
                let clipped = clipVectorPolygon(polygon, to: clipPolygon)
                if clipped.count >= 3 {
                    result.append(clipped)
                }
            }
        }

        return result
    }

    private func clipQuadVertices(
        _ vertices: [QuadVertexData],
        to clipPolygons: [[Vector2]]
    ) -> (vertices: [QuadVertexData], indices: [UInt32]) {
        var resultVertices: [QuadVertexData] = []
        var resultIndices: [UInt32] = []

        for clipped in clipVertexPolygon(vertices, to: clipPolygons, position: quadPosition, interpolate: interpolateQuad) {
            appendFan(for: clipped, vertices: &resultVertices, indices: &resultIndices)
        }

        return (resultVertices, resultIndices)
    }

    private func clipGlyphVertices(
        _ vertices: [GlyphVertexData],
        to clipPolygons: [[Vector2]]
    ) -> (vertices: [GlyphVertexData], indices: [UInt32]) {
        var resultVertices: [GlyphVertexData] = []
        var resultIndices: [UInt32] = []

        for clipped in clipVertexPolygon(vertices, to: clipPolygons, position: glyphPosition, interpolate: interpolateGlyph) {
            appendFan(for: clipped, vertices: &resultVertices, indices: &resultIndices)
        }

        return (resultVertices, resultIndices)
    }

    private func clipVertexPolygon<Vertex>(
        _ vertices: [Vertex],
        to clipPolygons: [[Vector2]],
        position: (Vertex) -> Vector2,
        interpolate: (Vertex, Vertex, Float) -> Vertex
    ) -> [[Vertex]] {
        var result: [[Vertex]] = []
        guard let vertexBounds = clipBounds(of: vertices, position: position) else {
            return result
        }

        for clipPolygon in clipPolygons {
            guard
                let polygonBounds = clipBounds(of: clipPolygon),
                vertexBounds.intersects(polygonBounds)
            else {
                continue
            }
            let polygonArea = signedArea(of: clipPolygon)
            // Preserve fully contained geometry under rounded/rotated masks too.
            // Bounding-box overlap alone is insufficient: every clip half-plane
            // must contain the entire vertex bounds before bypassing clipping.
            if polygonBounds.contains(vertexBounds),
                isAxisAlignedRectangle(clipPolygon, bounds: polygonBounds, signedArea: polygonArea)
                    || containsBounds(vertexBounds, in: clipPolygon, signedArea: polygonArea) {
                result.append(vertices)
                continue
            }

            let isCounterClockwise = polygonArea >= 0
            var output = vertices
            var scratch: [Vertex] = []

            for index in clipPolygon.indices {
                let edgeStart = clipPolygon[index]
                let edgeEnd = clipPolygon[(index + 1) % clipPolygon.count]
                clipAgainstEdge(
                    output,
                    edgeStart: edgeStart,
                    edgeEnd: edgeEnd,
                    isCounterClockwise: isCounterClockwise,
                    position: position,
                    interpolate: interpolate,
                    into: &scratch
                )
                swap(&output, &scratch)

                if output.isEmpty {
                    break
                }
            }

            if output.count >= 3 {
                result.append(output)
            }
        }

        return result
    }

    private func containsBounds(_ bounds: ClipBounds, in polygon: [Vector2], signedArea: Float) -> Bool {
        guard
            signedArea.isFinite, abs(signedArea) > 0.0001,
            bounds.minX.isFinite, bounds.maxX.isFinite,
            bounds.minY.isFinite, bounds.maxY.isFinite
        else {
            return false
        }

        let direction: Float = signedArea > 0 ? 1 : -1
        for index in polygon.indices {
            let start = polygon[index]
            let end = polygon[(index + 1) % polygon.count]
            let normalX = (start.y - end.y) * direction
            let normalY = (end.x - start.x) * direction
            // This corner has the smallest inward distance to the edge. If it
            // is inside, all four bounds corners (and the enclosed quad) are.
            let x = normalX >= 0 ? bounds.minX : bounds.maxX
            let y = normalY >= 0 ? bounds.minY : bounds.maxY
            let distance = normalX * (x - start.x) + normalY * (y - start.y)
            guard distance.isFinite, distance >= 0 else {
                return false
            }
        }
        return true
    }

    private struct ClipBounds {
        let minX: Float
        let minY: Float
        let maxX: Float
        let maxY: Float

        func intersects(_ other: Self) -> Bool {
            minX <= other.maxX
                && maxX >= other.minX
                && minY <= other.maxY
                && maxY >= other.minY
        }

        func contains(_ other: Self) -> Bool {
            minX <= other.minX
                && maxX >= other.maxX
                && minY <= other.minY
                && maxY >= other.maxY
        }
    }

    private func isAxisAlignedRectangle(
        _ polygon: [Vector2],
        bounds: ClipBounds,
        signedArea: Float
    ) -> Bool {
        guard polygon.count == 4 else {
            return false
        }

        let width = bounds.maxX - bounds.minX
        let height = bounds.maxY - bounds.minY
        let epsilon: Float = 0.0001
        guard width > epsilon, height > epsilon else {
            return false
        }

        let rectangleArea = width * height
        let tolerance = epsilon * max(1, rectangleArea)
        return abs(abs(signedArea) - rectangleArea) <= tolerance
    }

    private func clipBounds<Vertex>(
        of vertices: [Vertex],
        position: (Vertex) -> Vector2
    ) -> ClipBounds? {
        guard let first = vertices.first else {
            return nil
        }

        let firstPosition = position(first)
        var minX = firstPosition.x
        var minY = firstPosition.y
        var maxX = firstPosition.x
        var maxY = firstPosition.y
        for vertex in vertices {
            let point = position(vertex)
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }

        return Self.ClipBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    private func clipBounds(of polygon: [Vector2]) -> ClipBounds? {
        guard polygon.count >= 3, let first = polygon.first else {
            return nil
        }

        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y
        for point in polygon {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }

        return Self.ClipBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    private func clipVectorPolygon(_ polygon: [Vector2], to clipPolygon: [Vector2]) -> [Vector2] {
        let polygonArea = signedArea(of: clipPolygon)
        if let bounds = clipBounds(of: polygon) {
            switch classifyBounds(bounds, in: clipPolygon, signedArea: polygonArea) {
            case .inside: return polygon
            case .outside: return []
            case .intersecting: break
            }
        }
        let isCounterClockwise = polygonArea >= 0
        var output = polygon
        var scratch: [Vector2] = []

        for index in clipPolygon.indices {
            let edgeStart = clipPolygon[index]
            let edgeEnd = clipPolygon[(index + 1) % clipPolygon.count]
            clipAgainstEdge(
                output,
                edgeStart: edgeStart,
                edgeEnd: edgeEnd,
                isCounterClockwise: isCounterClockwise,
                position: { $0 },
                interpolate: { start, end, t in start + (end - start) * t },
                into: &scratch
            )
            swap(&output, &scratch)

            if output.isEmpty {
                break
            }
        }

        return output
    }

    private enum BoundsClipRelation {
        case inside
        case outside
        case intersecting
    }

    private func classifyBounds(_ bounds: ClipBounds, in polygon: [Vector2], signedArea: Float) -> BoundsClipRelation {
        guard
            signedArea.isFinite, abs(signedArea) > 0.0001,
            bounds.minX.isFinite, bounds.maxX.isFinite,
            bounds.minY.isFinite, bounds.maxY.isFinite
        else {
            return .intersecting
        }

        let direction: Float = signedArea > 0 ? 1 : -1
        var fullyInside = true
        for index in polygon.indices {
            let start = polygon[index]
            let end = polygon[(index + 1) % polygon.count]
            let normalX = (start.y - end.y) * direction
            let normalY = (end.x - start.x) * direction
            let nearX = normalX >= 0 ? bounds.minX : bounds.maxX
            let nearY = normalY >= 0 ? bounds.minY : bounds.maxY
            let farX = normalX >= 0 ? bounds.maxX : bounds.minX
            let farY = normalY >= 0 ? bounds.maxY : bounds.minY
            let minimum = normalX * (nearX - start.x) + normalY * (nearY - start.y)
            let maximum = normalX * (farX - start.x) + normalY * (farY - start.y)
            guard minimum.isFinite, maximum.isFinite else {
                return .intersecting
            }
            // Use the same half-plane tolerance as isInsideClipEdge. A plain
            // bounding-box rejection would incorrectly drop near-edge geometry.
            if maximum < -0.0001 {
                return .outside
            }
            if minimum < 0 {
                fullyInside = false
            }
        }
        return fullyInside ? .inside : .intersecting
    }

    private func clipAgainstEdge<Vertex>(
        _ vertices: [Vertex],
        edgeStart: Vector2,
        edgeEnd: Vector2,
        isCounterClockwise: Bool,
        position: (Vertex) -> Vector2,
        interpolate: (Vertex, Vertex, Float) -> Vertex,
        into output: inout [Vertex]
    ) {
        output.removeAll(keepingCapacity: true)
        guard let last = vertices.last else {
            return
        }

        output.reserveCapacity(vertices.count + 1)
        var previousVertex = last
        var previousPosition = position(previousVertex)
        var previousInside = isInsideClipEdge(
            previousPosition,
            edgeStart: edgeStart,
            edgeEnd: edgeEnd,
            isCounterClockwise: isCounterClockwise
        )

        for currentVertex in vertices {
            let currentPosition = position(currentVertex)
            let currentInside = isInsideClipEdge(
                currentPosition,
                edgeStart: edgeStart,
                edgeEnd: edgeEnd,
                isCounterClockwise: isCounterClockwise
            )

            if currentInside {
                if !previousInside {
                    let t = intersectionParameter(
                        from: previousPosition,
                        to: currentPosition,
                        edgeStart: edgeStart,
                        edgeEnd: edgeEnd
                    )
                    output.append(interpolate(previousVertex, currentVertex, t))
                }
                output.append(currentVertex)
            } else if previousInside {
                let t = intersectionParameter(
                    from: previousPosition,
                    to: currentPosition,
                    edgeStart: edgeStart,
                    edgeEnd: edgeEnd
                )
                output.append(interpolate(previousVertex, currentVertex, t))
            }

            previousVertex = currentVertex
            previousPosition = currentPosition
            previousInside = currentInside
        }
    }

    private func appendFan<Vertex>(
        for polygon: [Vertex],
        vertices: inout [Vertex],
        indices: inout [UInt32]
    ) {
        guard polygon.count >= 3 else {
            return
        }

        let vertexOffset = UInt32(vertices.count)
        vertices.append(contentsOf: polygon)

        for index in 1..<(polygon.count - 1) {
            indices.append(vertexOffset)
            indices.append(vertexOffset + UInt32(index))
            indices.append(vertexOffset + UInt32(index + 1))
        }
    }

    private func isInsideClipEdge(
        _ point: Vector2,
        edgeStart: Vector2,
        edgeEnd: Vector2,
        isCounterClockwise: Bool
    ) -> Bool {
        let edge = edgeEnd - edgeStart
        let candidate = point - edgeStart
        let cross = edge.x * candidate.y - edge.y * candidate.x
        let epsilon: Float = 0.0001
        return isCounterClockwise ? cross >= -epsilon : cross <= epsilon
    }

    private func intersectionParameter(
        from start: Vector2,
        to end: Vector2,
        edgeStart: Vector2,
        edgeEnd: Vector2
    ) -> Float {
        let segment = end - start
        let edge = edgeEnd - edgeStart
        let denominator = segment.x * edge.y - segment.y * edge.x

        guard abs(denominator) > 0.0001 else {
            return 0
        }

        let distance = edgeStart - start
        let t = (distance.x * edge.y - distance.y * edge.x) / denominator
        return min(max(t, 0), 1)
    }

    private func quadPosition(_ vertex: QuadVertexData) -> Vector2 {
        Vector2(vertex.position.x, vertex.position.y)
    }

    private func glyphPosition(_ vertex: GlyphVertexData) -> Vector2 {
        Vector2(vertex.position.x, vertex.position.y)
    }

    private func interpolateQuad(_ start: QuadVertexData, _ end: QuadVertexData, _ t: Float) -> QuadVertexData {
        QuadVertexData(
            position: interpolate(start.position, end.position, t),
            color: start.color,
            textureCoordinate: start.textureCoordinate + (end.textureCoordinate - start.textureCoordinate) * t,
            textureIndex: start.textureIndex
        )
    }

    private func interpolateGlyph(_ start: GlyphVertexData, _ end: GlyphVertexData, _ t: Float) -> GlyphVertexData {
        GlyphVertexData(
            position: interpolate(start.position, end.position, t),
            foregroundColor: start.foregroundColor,
            outlineColor: start.outlineColor,
            outlineWidth: start.outlineWidth,
            textureCoordinate: start.textureCoordinate + (end.textureCoordinate - start.textureCoordinate) * t,
            textureIndex: start.textureIndex
        )
    }

    private func interpolate(_ start: Vector4, _ end: Vector4, _ t: Float) -> Vector4 {
        start + (end - start) * t
    }

    // MARK: - Bezier Curve Helpers

    private func tessellateQuadraticBezier(
        start: Vector2,
        control: Vector2,
        end: Vector2,
        segments: Int,
        lineWidth: Float,
        color: Color,
        transform: Transform3D
    ) -> (vertices: [LineVertexData], indices: [UInt32]) {
        var vertices: [LineVertexData] = []
        var indices: [UInt32] = []

        var previousPoint = start

        for i in 1...segments {
            let t = Float(i) / Float(segments)

            // Quadratic Bezier: B(t) = (1-t)^2 * P0 + 2*(1-t)*t * P1 + t^2 * P2
            let oneMinusT = 1 - t
            let point = oneMinusT * oneMinusT * start + 2 * oneMinusT * t * control + t * t * end

            let startWorld = transformedPathPoint(previousPoint, with: transform)
            let endWorld = transformedPathPoint(point, with: transform)

            let vertexOffset = UInt32(vertices.count)
            vertices.append(
                contentsOf: tessellateLine(
                    start: startWorld.xyz,
                    end: endWorld.xyz,
                    lineWidth: lineWidth,
                    color: color
                )
            )
            indices.append(contentsOf: generateLineIndices(vertexOffset: vertexOffset))

            previousPoint = point
        }

        return (vertices, indices)
    }

    private func tessellateCubicBezier(
        start: Vector2,
        control1: Vector2,
        control2: Vector2,
        end: Vector2,
        segments: Int,
        lineWidth: Float,
        color: Color,
        transform: Transform3D
    ) -> (vertices: [LineVertexData], indices: [UInt32]) {
        var vertices: [LineVertexData] = []
        var indices: [UInt32] = []

        var previousPoint = start

        for i in 1...segments {
            let t = Float(i) / Float(segments)

            // Cubic Bezier: B(t) = (1-t)^3 * P0 + 3*(1-t)^2*t * P1 + 3*(1-t)*t^2 * P2 + t^3 * P3
            let oneMinusT = 1 - t
            let oneMinusT2 = oneMinusT * oneMinusT
            let oneMinusT3 = oneMinusT2 * oneMinusT
            let t2 = t * t
            let t3 = t2 * t

            let point = oneMinusT3 * start + 3 * oneMinusT2 * t * control1 + 3 * oneMinusT * t2 * control2 + t3 * end

            let startWorld = transformedPathPoint(previousPoint, with: transform)
            let endWorld = transformedPathPoint(point, with: transform)

            let vertexOffset = UInt32(vertices.count)
            vertices.append(
                contentsOf: tessellateLine(
                    start: startWorld.xyz,
                    end: endWorld.xyz,
                    lineWidth: lineWidth,
                    color: color
                )
            )
            indices.append(contentsOf: generateLineIndices(vertexOffset: vertexOffset))

            previousPoint = point
        }

        return (vertices, indices)
    }

    // MARK: - Fill Helpers

    private func flattenClosedSubpaths(from path: Path) -> [[Vector2]] {
        var closedSubpaths: [[Vector2]] = []
        var currentSubpath: [Vector2] = []
        var currentPoint: Vector2?

        func appendPoint(_ point: Vector2) {
            if let last = currentSubpath.last, arePointsEqual(last, point) {
                return
            }
            currentSubpath.append(point)
            currentPoint = point
        }

        func finishCurrentSubpath(closed: Bool) {
            defer {
                currentSubpath.removeAll(keepingCapacity: true)
                currentPoint = nil
            }

            guard closed else {
                return
            }

            let polygon = normalizedPolygon(currentSubpath)
            if polygon.count >= 3 {
                closedSubpaths.append(polygon)
            }
        }

        path.forEach { element in
            switch element {
            case let .move(to: point):
                finishCurrentSubpath(closed: false)
                currentSubpath = [point]
                currentPoint = point

            case let .line(to: end):
                guard currentPoint != nil else {
                    break
                }
                appendPoint(end)

            case let .quadCurve(to: end, control: control):
                guard let start = currentPoint else {
                    break
                }
                for segmentIndex in 1...Self.curveSegments {
                    let t = Float(segmentIndex) / Float(Self.curveSegments)
                    let oneMinusT = 1 - t
                    let point =
                        oneMinusT * oneMinusT * start
                        + 2 * oneMinusT * t * control
                        + t * t * end
                    appendPoint(point)
                }

            case let .curve(to: end, control1: control1, control2: control2):
                guard let start = currentPoint else {
                    break
                }
                for segmentIndex in 1...Self.curveSegments {
                    let t = Float(segmentIndex) / Float(Self.curveSegments)
                    let oneMinusT = 1 - t
                    let oneMinusT2 = oneMinusT * oneMinusT
                    let oneMinusT3 = oneMinusT2 * oneMinusT
                    let t2 = t * t
                    let t3 = t2 * t
                    let point =
                        oneMinusT3 * start
                        + 3 * oneMinusT2 * t * control1
                        + 3 * oneMinusT * t2 * control2
                        + t3 * end
                    appendPoint(point)
                }

            case .closeSubpath:
                finishCurrentSubpath(closed: true)
            }
        }

        finishCurrentSubpath(closed: false)
        return closedSubpaths
    }

    private func normalizedPolygon(_ points: [Vector2]) -> [Vector2] {
        var normalized: [Vector2] = []

        for point in points {
            if let last = normalized.last, arePointsEqual(last, point) {
                continue
            }
            normalized.append(point)
        }

        if let first = normalized.first, let last = normalized.last, arePointsEqual(first, last) {
            normalized.removeLast()
        }

        return normalized
    }

    private func triangulatePolygon(_ polygon: [Vector2]) -> [UInt32] {
        guard polygon.count >= 3 else {
            return []
        }

        let isCounterClockwise = signedArea(of: polygon) >= 0
        var remainingIndices = Array(polygon.indices)
        var triangleIndices: [UInt32] = []
        var guardCounter = 0
        let maxIterations = polygon.count * polygon.count

        while remainingIndices.count > 3 && guardCounter < maxIterations {
            var earIndexToRemove: Int?

            for offset in remainingIndices.indices {
                let previousOffset = (offset + remainingIndices.count - 1) % remainingIndices.count
                let nextOffset = (offset + 1) % remainingIndices.count

                let previousIndex = remainingIndices[previousOffset]
                let currentIndex = remainingIndices[offset]
                let nextIndex = remainingIndices[nextOffset]

                let a = polygon[previousIndex]
                let b = polygon[currentIndex]
                let c = polygon[nextIndex]

                guard isConvex(a: a, b: b, c: c, isCounterClockwise: isCounterClockwise) else {
                    continue
                }

                var containsPointInsideEar = false
                for candidateIndex in remainingIndices {
                    if candidateIndex == previousIndex || candidateIndex == currentIndex || candidateIndex == nextIndex {
                        continue
                    }

                    if pointInTriangle(polygon[candidateIndex], a: a, b: b, c: c) {
                        containsPointInsideEar = true
                        break
                    }
                }

                if containsPointInsideEar {
                    continue
                }

                triangleIndices.append(UInt32(previousIndex))
                triangleIndices.append(UInt32(currentIndex))
                triangleIndices.append(UInt32(nextIndex))
                earIndexToRemove = offset
                break
            }

            guard let earIndexToRemove else {
                return []
            }

            remainingIndices.remove(at: earIndexToRemove)
            guardCounter += 1
        }

        guard remainingIndices.count == 3 else {
            return []
        }

        triangleIndices.append(UInt32(remainingIndices[0]))
        triangleIndices.append(UInt32(remainingIndices[1]))
        triangleIndices.append(UInt32(remainingIndices[2]))
        return triangleIndices
    }

    private func arePointsEqual(_ lhs: Vector2, _ rhs: Vector2, epsilon: Float = 0.0001) -> Bool {
        abs(lhs.x - rhs.x) <= epsilon && abs(lhs.y - rhs.y) <= epsilon
    }

    private func signedArea(of polygon: [Vector2]) -> Float {
        guard polygon.count >= 3 else {
            return 0
        }

        var area: Float = 0
        for index in polygon.indices {
            let nextIndex = (index + 1) % polygon.count
            area += polygon[index].x * polygon[nextIndex].y
            area -= polygon[nextIndex].x * polygon[index].y
        }
        return area * 0.5
    }

    private func isConvex(
        a: Vector2,
        b: Vector2,
        c: Vector2,
        isCounterClockwise: Bool
    ) -> Bool {
        let cross = crossProduct(a: a, b: b, c: c)
        let epsilon: Float = 0.0001
        return isCounterClockwise ? cross > epsilon : cross < -epsilon
    }

    private func pointInTriangle(
        _ point: Vector2,
        a: Vector2,
        b: Vector2,
        c: Vector2
    ) -> Bool {
        let epsilon: Float = 0.0001
        let ab = crossProduct(a: point, b: a, c: b)
        let bc = crossProduct(a: point, b: b, c: c)
        let ca = crossProduct(a: point, b: c, c: a)

        let hasNegative = ab < -epsilon || bc < -epsilon || ca < -epsilon
        let hasPositive = ab > epsilon || bc > epsilon || ca > epsilon
        return !(hasNegative && hasPositive)
    }

    private func crossProduct(a: Vector2, b: Vector2, c: Vector2) -> Float {
        let ab = b - a
        let ac = c - a
        return ab.x * ac.y - ab.y * ac.x
    }

    private func transformedPathPoint(
        _ point: Vector2,
        with transform: Transform3D
    ) -> Vector4 {
        transform * Vector4(point.x, -point.y, 0, 1)
    }
}
