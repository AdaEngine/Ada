@_spi(AdaEngine) import AdaEngine
// swiftlint:disable:next duplicate_imports
@_spi(Internal) import AdaEngine
import Foundation
import Math
import Testing

@testable import AdaEditor

@Suite("Editor sprite picking")
@MainActor
struct EditorSpritePickingTests {
    @Test("Transparent front texels select the lower sprite through the viewport input path")
    func alphaClickThrough() throws {
        try setupRenderer()
        let texture = Texture2D(image: Image(width: 2, height: 1, data: Data([255, 255, 255, 0, 255, 255, 255, 255])))
        let world = World()
        world.spawn("SceneView_Camera") { Camera(); Transform() }
        let back = world.spawn { Sprite(size: Size(width: 20, height: 10)); Transform() }
        let front = world.spawn { Sprite(texture: texture, size: Size(width: 20, height: 10)); Transform(position: [0, 0, 2]) }
        let viewport = viewport(world: world, entries: [back.id: "back", front.id: "front"])
        #expect(viewport.pick2D(at: [45, 50]) == "back")
        #expect(viewport.pick2D(at: [55, 50]) == "front")
        var selection: String?
        viewport.onSelectEntity = { selection = $0 }
        viewport.setActiveTool(.select)
        let window = RID()
        #expect(viewport.handleInput(MouseEvent(window: window, button: .left, mousePosition: [45, 50], phase: .began, modifierKeys: [], time: 0)))
        #expect(viewport.handleInput(MouseEvent(window: window, button: .left, mousePosition: [45, 50], phase: .ended, modifierKeys: [], time: 0.1)))
        #expect(selection == "back")
    }

    @Test("Picking composes parent rotations and respects anchor/fit before propagation")
    func parentAndLayout() throws {
        try setupRenderer()
        let world = World()
        world.spawn("SceneView_Camera") { Camera(); Transform() }
        let parent = world.spawn { Transform(rotation: Quat(axis: [0, 0, 1], angle: .pi / 2), scale: [2, 3, 1], position: [5, 0, 2]) }
        let sprite = world.spawn {
            Sprite(texture: Texture2D(image: Image(width: 2, height: 1, color: .white)), size: Size(width: 10, height: 10), anchor: .bottomLeft, imageMode: .fit)
            Transform()
        }
        parent.addChild(sprite)
        let viewport = viewport(world: world, entries: [sprite.id: "sprite"])
        let matrix = try #require(EditorPicking.worldMatrix(for: sprite))
        let center = (matrix * Vector4(5, 5, 0, 1)).xyz
        let point = try #require(viewport.project(center, size: viewport.viewportSize))
        #expect(viewport.pick2D(at: point) == "sprite")
        let margin = (matrix * Vector4(5, 1, 0, 1)).xyz
        let marginPoint = try #require(viewport.project(margin, size: viewport.viewportSize))
        #expect(viewport.pick2D(at: marginPoint) == nil)
        #expect(sprite.components[GlobalTransform.self]?.matrix == .identity)
        sprite.components[Visibility.self] = .hidden
        #expect(viewport.pick2D(at: point) == nil)
    }

    @Test("Scene sprite decoding preserves layout fields used by shared picking")
    func decodedLayout() throws {
        let sprite = Sprite(size: Size(width: 10, height: 20), anchor: .bottomCenter, imageMode: .sliced(SpriteSliceBorder(2)))
        let payload = try JSONDecoder().decode(EditorComponentPayload.self, from: JSONEncoder().encode(sprite))
        let decoded = try #require(try EditorComponentRegistry.decode(typeName: EditorBuiltInComponentType.sprite, payload: payload) as? Sprite)
        #expect(decoded.anchor == .bottomCenter)
        #expect(decoded.imageMode == sprite.imageMode)
    }

    private func viewport(world: World, entries: [Entity.ID: String]) -> EditorSceneViewportModel {
        let viewport = EditorSceneViewportModel()
        viewport.attachSceneWorld(world, loadResult: .init(
            entityCount: entries.count,
            warnings: [],
            entitiesByEditorID: Dictionary(uniqueKeysWithValues: entries.map { ($0.value, $0.key) }),
            editorIDsByEntityID: entries
        ))
        viewport.twoDZoom = 1
        viewport.setViewportSize(Size(width: 100, height: 100))
        viewport.setDisplayMode(.twoD)
        return viewport
    }

    private func setupRenderer() throws {
        guard unsafe RenderEngine.shared == nil else {
            return
        }
        unsafe RenderEngine.configurations.preferredBackend = .headless
        RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "EditorSpritePickingTests")))
    }
}
