//
//  Lighting2DShadowMathTests.swift
//  AdaEngine
//

@testable import AdaSprite
import Math
import Testing

@Suite("Lighting2DShadowMath")
struct Lighting2DShadowMathTests {

    @Test
    func shadowFinQuads_emptyPolygon() {
        let quads = Lighting2DShadowMath.shadowFinQuads(lightWorld: .zero, polygonWorldCCW: [])
        #expect(quads.isEmpty)
    }

    @Test
    func shadowFinQuads_squareContainsLight() {
        let square: [Vector2] = [
            Vector2(0, 0),
            Vector2(10, 0),
            Vector2(10, 10),
            Vector2(0, 10),
        ]
        let light = Vector2(5, 5)
        let quads = Lighting2DShadowMath.shadowFinQuads(lightWorld: light, polygonWorldCCW: square)
        #expect(quads.isEmpty)
    }

    @Test
    func shadowFinQuads_squareOutsideLightProducesGeometry() {
        let square: [Vector2] = [
            Vector2(100, 0),
            Vector2(110, 0),
            Vector2(110, 10),
            Vector2(100, 10),
        ]
        let light = Vector2(0, 0)
        let quads = Lighting2DShadowMath.shadowFinQuads(lightWorld: light, polygonWorldCCW: square)
        #expect(!quads.isEmpty)
        #expect(quads.count % 6 == 0)
    }

    @Test
    func directionalShadowFinQuads_empty() {
        let quads = Lighting2DShadowMath.directionalShadowFinQuads(
            polygonWorldCCW: [],
            lightDirection: Vector2(0, -1)
        )
        #expect(quads.isEmpty)
    }

    @Test
    func preparedShadowRangesKeepPerLightGeometryDisjoint() throws {
        let polygon: [Vector2] = [
            Vector2(0, 60),
            Vector2(80, 60),
            Vector2(80, 80),
            Vector2(0, 80),
        ]
        let lights = [
            ExtractedLight2DInstance(
                worldPosition: Vector2(0, 40),
                kind: .point,
                color: .white,
                energy: 1,
                direction: Vector2(0, -1),
                radius: 320,
                spotAngle: 0,
                texture: nil,
                castsShadows: true
            ),
            ExtractedLight2DInstance(
                worldPosition: .zero,
                kind: .directional,
                color: .white,
                energy: 1,
                direction: Vector2(0.4, -0.9),
                radius: 0,
                spotAngle: 0,
                texture: nil,
                castsShadows: true
            ),
        ]
        let occluders = [
            ExtractedOccluder2DInstance(worldPointsCCW: polygon, isEnabled: true),
        ]
        var scratch = Lighting2DGPUScratch()

        scratch.prepareShadowVertices(lights: lights, occluders: occluders)

        let pointRange = try #require(scratch.shadowVertexRanges.first)
        let directionalRange = try #require(scratch.shadowVertexRanges.last)
        #expect(!pointRange.isEmpty)
        #expect(!directionalRange.isEmpty)
        #expect(pointRange.upperBound == directionalRange.lowerBound)

        let pointVertices = scratch.shadowVerts.elements[pointRange].map(\.position)
        let directionalVertices = scratch.shadowVerts.elements[directionalRange].map(\.position)
        #expect(pointVertices != directionalVertices)
    }
}
