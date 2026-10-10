import AdaRender
@testable import AdaSprite
import AdaUtils
import Math
import Testing

@Suite("Sprite instance geometry")
struct SpriteInstancingTests {
    @Test("Instance layout uses six aligned vectors and less data than expanded quads")
    func layout() {
        #expect(MemoryLayout<SpriteInstanceData>.stride == 96)
        #expect(MemoryLayout<SpriteInstanceData>.offset(of: \.origin) == 0)
        #expect(MemoryLayout<SpriteInstanceData>.offset(of: \.axisX) == 16)
        #expect(MemoryLayout<SpriteInstanceData>.offset(of: \.axisY) == 32)
        #expect(MemoryLayout<SpriteInstanceData>.offset(of: \.color) == 48)
        #expect(MemoryLayout<SpriteInstanceData>.offset(of: \.bottomUV) == 64)
        #expect(MemoryLayout<SpriteInstanceData>.offset(of: \.topUV) == 80)
        #expect(MemoryLayout<SpriteInstanceData>.stride < 4 * MemoryLayout<SpriteVertexData>.stride + 6 * MemoryLayout<UInt32>.stride)
    }

    @Test("Every layout reconstructs world positions and cropped atlas corners", arguments: [
        SpriteImageMode.stretch, .fit, .fill, .sliced(SpriteSliceBorder(top: 3, left: 7, bottom: 2, right: 5)),
        .tiled(tileX: true, tileY: false, scale: 0.75), .tiled(scale: 0.5)
    ])
    func reconstructsGeometry(mode: SpriteImageMode) {
        let transform = Transform3D(translation: [13, -5, 2], rotation: Quat(axis: [1, 0, 1], angle: 0.7), scale: [-2, 3, 1])
        let geometry = SpriteGeometry(size: [67, 39], sourceSize: [32, 16], anchor: .bottomRight, imageMode: mode, flipX: true, flipY: true)
        let coords: [Vector2] = [[0.75, 0.6], [0.25, 0.6], [0.25, 0.2], [0.75, 0.2]]
        var count = 0
        geometry.forEachQuad { destination, source in
            let instance = SpriteInstanceData(destination: destination, source: source, textureCoordinates: coords, transform: transform, color: .red)
            #expect(instance.color == .red)
            for corner: Vector2 in [[0, 0], [1, 0], [1, 1], [0, 1]] {
                let actual = instance.origin + instance.axisX * corner.x + instance.axisY * corner.y
                let expected = transform * Vector4(destination.minX + corner.x * destination.width, destination.minY + corner.y * destination.height, 0, 1)
                for axis in 0..<4 { #expect(abs(actual[axis] - expected[axis]) < 0.0001) }
                let u = source.minX + corner.x * source.width
                let v = source.minY + corner.y * source.height
                let bottom = coords[0] + (coords[1] - coords[0]) * u
                let top = coords[3] + (coords[2] - coords[3]) * u
                let uv = bottom + (top - bottom) * v
                let left = corner.y == 0 ? Vector2(instance.bottomUV.x, instance.bottomUV.y) : Vector2(instance.topUV.x, instance.topUV.y)
                let right = corner.y == 0 ? Vector2(instance.bottomUV.z, instance.bottomUV.w) : Vector2(instance.topUV.z, instance.topUV.w)
                let reconstructed = left + (right - left) * corner.x
                #expect(abs(reconstructed.x - uv.x) < 0.00001 && abs(reconstructed.y - uv.y) < 0.00001)
            }
            count += 1
        }
        #expect(count > 0)
    }
}
