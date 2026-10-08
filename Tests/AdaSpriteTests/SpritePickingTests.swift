import AdaECS
@_spi(Internal) @testable import AdaRender
@testable import AdaSprite
import AdaTransform
import AdaUtils
import Foundation
import Math
import Testing

@Suite("Sprite picking")
@MainActor
struct SpritePickingTests {
    @Test("Alpha masks retain source alpha and reject malformed data")
    func alphaFormats() throws {
        let bytes = Data([0, 0, 0, 0, 255, 255, 255, 128])
        for format in [Image.Format.rgba8, .bgra8, .bgra8_sRGB] {
            let mask = try #require(TextureAlphaMask(image: Image(width: 2, height: 1, data: bytes, format: format)))
            #expect(mask.alpha(at: [0.25, 0.5]) == 0)
            #expect(mask.alpha(at: [0.75, 0.5]) == Float(128) / 255)
            #expect(mask.alpha(at: [.nan, 0]) == nil)
        }
        let rgb = try #require(TextureAlphaMask(image: Image(width: 1, height: 1, data: Data([0, 0, 0]), format: .rgb8)))
        #expect(rgb.alpha(at: .zero) == 1)
        #expect(TextureAlphaMask(image: Image(width: 1, height: 1, data: Data())) == nil)
    }

    @Test("Transparent texels and tint let picking reach the lower sprite")
    func alphaAndDepth() throws {
        try setupRenderer()
        let texture = makeTexture(alpha: [0, 255], width: 2, height: 1)
        let front = SpritePickingCandidate(entityID: 2, sprite: Sprite(texture: texture, size: Size(width: 20, height: 10)), worldTransform: Transform3D(translation: [0, 0, 2]))
        let back = SpritePickingCandidate(entityID: 1, sprite: Sprite(size: Size(width: 20, height: 10)), worldTransform: .identity)
        #expect(SpritePicker.pick(at: [55, 70], camera: camera(), candidates: [back, front]).map(\.entityID) == [1])
        #expect(SpritePicker.pick(at: [65, 70], camera: camera(), candidates: [back, front]).map(\.entityID) == [2])
        let passing = SpritePickingCandidate(
            entityID: 3,
            sprite: Sprite(size: Size(width: 20, height: 10)),
            worldTransform: Transform3D(translation: [0, 0, 3]),
            pickable: SpritePickable(blocksLower: false)
        )
        #expect(SpritePicker.pick(at: [65, 70], camera: camera(), candidates: [back, front, passing]).map(\.entityID) == [3, 2])
        let transparentTint = SpritePickingCandidate(entityID: 4, sprite: Sprite(tintColor: Color(1, 1, 1, 0), size: Size(width: 20, height: 10)), worldTransform: .identity)
        #expect(SpritePicker.hitTest(transparentTint, ray: ray(at: .zero)) == nil)
    }

    @Test("Fit margins, fill cropping, tiling and flips use the rendered UVs")
    func imageModes() throws {
        try setupRenderer()
        let texture = makeTexture(alpha: [255, 0, 0, 0], width: 4, height: 1)
        var sprite = Sprite(texture: texture, size: Size(width: 10, height: 10), imageMode: .fit)
        #expect(hit(sprite, at: [-4, 4]) == nil)
        #expect(hit(sprite, at: [-4, 0]) != nil)
        sprite.imageMode = .fill
        #expect(hit(sprite, at: [-4, 0]) == nil)
        sprite.imageMode = .stretch
        sprite.flipX = true
        #expect(hit(sprite, at: [4, 0]) != nil)
        #expect(hit(sprite, at: [-4, 0]) == nil)

        sprite = Sprite(texture: makeTexture(alpha: [0, 255], width: 2, height: 1), size: Size(width: 5, height: 2), anchor: .bottomLeft, imageMode: .tiled())
        #expect(hit(sprite, at: [0.5, 0.5]) == nil)
        #expect(hit(sprite, at: [1.5, 0.5]) != nil)
        #expect(hit(sprite, at: [3.5, 1.5]) != nil)
        #expect(hit(sprite, at: [4.5, 0.5]) == nil)
    }

    @Test("Nine-slice alpha follows preserved corners and asymmetric flips")
    func slicedAlpha() throws {
        try setupRenderer()
        var alpha = [UInt8](repeating: 0, count: 20 * 10)
        for y in 0..<3 {
            for x in 0..<2 { alpha[y * 20 + x] = 255 }
        }
        var sprite = Sprite(
            texture: makeTexture(alpha: alpha, width: 20, height: 10),
            size: Size(width: 60, height: 30),
            anchor: .bottomLeft,
            imageMode: .sliced(SpriteSliceBorder(top: 3, left: 2, bottom: 1, right: 5))
        )
        #expect(hit(sprite, at: [1, 29]) != nil)
        #expect(hit(sprite, at: [30, 29]) == nil)
        sprite.flipX = true
        sprite.flipY = true
        #expect(hit(sprite, at: [59, 1]) != nil)
        #expect(hit(sprite, at: [1, 29]) == nil)
    }

    @Test("Grid and named atlas slices share CPU masks, including proxies and animated frames")
    func atlasAndFrames() throws {
        try setupRenderer()
        let image = image(alpha: [255, 255, 0, 255], width: 4, height: 1)
        let atlas = TextureAtlas(from: image, size: [2, 1])
        let slice = try #require(atlas.textureSlice(in: RectInt(x: 2, y: 0, width: 2, height: 1)))
        let sprite = Sprite(texture: slice, size: Size(width: 20, height: 10))
        #expect(hit(sprite, at: [-5, 0]) == nil)
        #expect(hit(sprite, at: [5, 0])?.textureCoordinate.x == 0.875)
        let proxy = Texture2DProxy(source: slice)
        #expect(hit(Sprite(texture: proxy, size: sprite.size), at: [-5, 0]) == nil)
        let region = AtlasRegion(
            key: "sprite",
            atlasOrigin: [2, 0],
            atlasSize: [2, 1],
            uvMin: [0.5, 0],
            uvMax: [1, 1],
            originalSize: [2, 1],
            contentOriginInAtlas: [2, 0]
        )
        let named = NamedTextureAtlas(texture: Texture2D(image: image), entriesByKey: ["sprite": region])
        let namedSlice = try #require(named["sprite"])
        #expect(hit(Sprite(texture: namedSlice, size: sprite.size), at: [-5, 0]) == nil)
        #expect(hit(Sprite(texture: namedSlice, size: sprite.size), at: [5, 0]) != nil)
        let animation = AnimatedTexture()
        animation.framesCount = 2
        animation[0] = slice
        animation[1] = .whiteTexture
        #expect(hit(Sprite(texture: animation, size: sprite.size), at: [-5, 0]) == nil)
        animation.currentFrame = 1
        #expect(hit(Sprite(texture: animation, size: sprite.size), at: [-5, 0]) != nil)
        proxy.replaceSource(with: .whiteTexture)
        #expect(hit(Sprite(texture: proxy, size: sprite.size), at: [-5, 0]) != nil)
        slice.invalidatePickingAlphaMask()
        #expect(atlas.pickingAlphaMask == nil)
        #expect(slice.pickingAlphaMask == nil)
        #expect(hit(sprite, at: [-5, 0]) != nil)
        let ignored = SpritePickingCandidate(entityID: 1, sprite: sprite, worldTransform: .identity, pickable: SpritePickable(alphaFallback: .ignore))
        #expect(SpritePicker.hitTest(ignored, ray: ray(at: [-5, 0])) == nil)
    }

    @Test("Anchors and composed rotated/reflected transforms are inverted before alpha sampling")
    func worldTransforms() throws {
        try setupRenderer()
        let sprite = Sprite(texture: makeTexture(alpha: [0, 255], width: 2, height: 1), size: Size(width: 20, height: 10), anchor: .bottomLeft)
        let matrix = Transform(rotation: Quat(axis: [0, 0, 1], angle: .pi / 3), scale: [-2, 3, 1], position: [5, 8, 2]).matrix
            * Transform(position: [3, 4, 0]).matrix
        let point = (matrix * Vector4(15, 5, 0, 1)).xyz.xy
        let candidate = SpritePickingCandidate(entityID: 1, sprite: sprite, worldTransform: matrix)
        let picked = try #require(SpritePicker.hitTest(candidate, ray: ray(at: point)))
        #expect(abs(picked.localPosition.x - 15) < 0.0001)
        #expect(abs(picked.localPosition.y - 5) < 0.0001)
        #expect(SpritePicker.hitTest(SpritePickingCandidate(entityID: 1, sprite: sprite, worldTransform: Transform3D(scale: .zero)), ray: ray(at: point)) == nil)
    }

    @Test("Camera viewport offsets, clipping and invalid geometry reject hits")
    func cameraBoundaries() throws {
        let view = camera()
        let center = try #require(view.ray(at: [60, 70]))
        #expect(abs(center.ray.origin.x) < 0.0001)
        #expect(abs(center.ray.origin.y) < 0.0001)
        #expect(view.ray(at: [9, 70]) == nil)
        #expect(view.ray(at: [110, 70]) == nil)
        #expect(view.ray(at: [.nan, 70]) == nil)
        let outOfClip = SpritePickingCandidate(entityID: 1, sprite: Sprite(size: Size(width: 20, height: 10)), worldTransform: Transform3D(translation: [0, 0, 110]))
        #expect(SpritePicker.pick(at: [60, 70], camera: view, candidates: [outOfClip]).isEmpty)
    }

    private func camera() -> SpritePickingCamera {
        SpritePickingCamera(
            entityID: 42,
            viewport: Rect(x: 10, y: 20, width: 100, height: 100),
            projection: Transform3D.orthographic(left: -50, right: 50, top: 50, bottom: -50, zNear: 0, zFar: 100),
            worldTransform: Transform3D(translation: [0, 0, -10])
        )
    }

    private func hit(_ sprite: Sprite, at point: Point) -> SpritePickHit? {
        SpritePicker.hitTest(SpritePickingCandidate(entityID: 1, sprite: sprite, worldTransform: .identity), ray: ray(at: point))
    }

    private func ray(at point: Point) -> Ray { Ray(origin: Vector3(point.x, point.y, -10), direction: [0, 0, 1]) }

    private func makeTexture(alpha: [UInt8], width: Int, height: Int) -> Texture2D {
        Texture2D(image: image(alpha: alpha, width: width, height: height))
    }

    private func image(alpha: [UInt8], width: Int, height: Int) -> Image {
        Image(width: width, height: height, data: Data(alpha.flatMap { [UInt8(255), 255, 255, $0] }))
    }

    private func setupRenderer() throws {
        guard unsafe RenderEngine.shared == nil else {
            return
        }
        unsafe RenderEngine.configurations.preferredBackend = .headless
        try RenderEngine.setupRenderEngine()
    }
}
