@_spi(Internal) @testable import AdaApp
@_spi(AdaEngine) import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Math
import Testing

@testable import AdaEditor

@Suite("Model preview navigation and lighting", .serialized)
@MainActor
struct EditorModelPreviewNavigationTests {
    init() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        GLTFLoaderResolver.shared.setLoader(NativeGLTFLoader())
    }

    @Test("Middle drag and Shift-left drag pan without rotating the model", arguments: [MouseButton.middle, .left])
    func panInput(button: MouseButton) {
        let camera = makeCamera()
        let before = camera.cameraTransform()
        let modifiers: KeyModifier = button == .left ? .shift : []
        camera.handleInput(mouse(button, .began, at: Point(100, 100), modifiers: modifiers))
        camera.handleInput(mouse(button, .changed, at: Point(160, 140), modifiers: modifiers))
        camera.handleInput(mouse(button, .ended, at: Point(160, 140), modifiers: modifiers))
        #expect(camera.target.squaredLength > 0)
        #expect(camera.cameraTransform().position != before.position)
        #expect((camera.cameraTransform().matrix[2].xyz - before.matrix[2].xyz).squaredLength < 0.00001)
        camera.reset()
        #expect(camera.cameraTransform() == before)
    }

    @Test("Right drag looks around from a fixed position")
    func freeLook() {
        let camera = makeCamera()
        let before = camera.cameraTransform()
        camera.handleInput(mouse(.right, .began, at: Point(100, 100)))
        camera.handleInput(mouse(.right, .changed, at: Point(160, 125)))
        let after = camera.cameraTransform()
        #expect((after.position - before.position).squaredLength < 0.00001)
        #expect((after.matrix[2].xyz - before.matrix[2].xyz).squaredLength > 0.01)
    }

    @Test("Flight keys move in camera space and stop when right drag ends", arguments: [KeyCode.w, .a, .s, .d, .q, .e])
    func flight(key: KeyCode) {
        let camera = makeCamera()
        let before = camera.cameraTransform()
        camera.handleInput(self.key(key, .down))
        camera.update(deltaTime: 1 / 60)
        #expect(camera.cameraTransform() == before)
        camera.handleInput(mouse(.right, .began, at: Point(100, 100)))
        camera.handleInput(self.key(key, .down))
        camera.update(deltaTime: 1 / 60)
        let after = camera.cameraTransform()
        let expected: Vector3
        switch key {
        case .w: expected = before.matrix[2].xyz
        case .s: expected = -before.matrix[2].xyz
        case .d: expected = before.matrix[0].xyz
        case .a: expected = -before.matrix[0].xyz
        case .e: expected = .up
        default: expected = -.up
        }
        #expect((after.position - before.position).dot(expected) > 0)
        camera.handleInput(mouse(.right, .ended, at: Point(100, 100)))
        camera.update(deltaTime: 1 / 60)
        #expect(camera.cameraTransform() == after)
    }

    @Test("Shift accelerates flight and cancelled gestures clear held keys")
    func accelerationAndCancellation() {
        let camera = makeCamera()
        camera.handleInput(mouse(.right, .began, at: .zero))
        camera.handleInput(key(.w, .down))
        let start = camera.cameraTransform().position
        camera.update(deltaTime: 1 / 60)
        let slow = camera.cameraTransform().position
        camera.handleInput(key(.shift, .down))
        camera.update(deltaTime: 1 / 60)
        let fast = camera.cameraTransform().position
        #expect(abs((fast - slow).length / (slow - start).length - 4) < 0.001)
        camera.handleInput(mouse(.right, .cancelled, at: .zero))
        camera.handleInput(mouse(.right, .began, at: .zero))
        camera.update(deltaTime: 1 / 60)
        #expect(camera.cameraTransform().position == fast)
        camera.zoom(by: 100)
        #expect(camera.zoom == 0.02)
        camera.reset()
        #expect(camera.target == .zero && camera.zoom == 1)
    }

    @Test("Real asset preview loads bundled IBL and creates two opposing lights")
    func previewLighting() async throws {
        let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let model = EditorModelAssetPreviewModel()
        model.load(path: engine.appendingPathComponent("Tests/AdaAssetsTests/Fixtures/TwoBoneRibbon.glb").path)
        defer { model.cancel() }
        for _ in 0..<1000 where model.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isLoading)
        #expect(model.error == nil)
        _ = try #require(model.asset)
        let lighting = try #require(model.previewLighting?.asset)
        #expect(lighting.irradiance.width > 0 && lighting.specularLevels == 6)
        let app = AppWorlds(main: World())
        let view = app.main.spawn("SceneView_Camera") { Camera(); Transform() }
        let camera = makeCamera()
        EditorModelPreviewViewport.configure(app, model: model, camera: camera)
        let lights = app.main.getEntities().filter { $0.components[DirectionalLightComponent.self] != nil }
        #expect(lights.count == 2)
        #expect(lights.allSatisfy { $0.components[DirectionalLightComponent.self]?.castShadows == false })
        let first = try #require(lights.first?.components[Transform.self])
        let last = try #require(lights.last?.components[Transform.self])
        #expect(first.matrix[2].xyz.dot(last.matrix[2].xyz) < -0.5)
        let environment = try #require(view.components[Environment3D.self])
        #expect(environment.imageBasedLighting?.asset.asset?.irradiance === lighting.irradiance)
        #expect(!environment.skybox.isEnabled)
        let transforms = app.main.getEntities().filter { $0.id != view.id }.map { ($0.id, $0.components[Transform.self]) }
        camera.pan(by: Point(80, 40))
        camera.look(by: Point(150, 25))
        for (id, transform) in transforms { #expect(app.main.getEntityByID(id)?.components[Transform.self] == transform) }
    }

    private func makeCamera() -> EditorModelPreviewCamera {
        let camera = EditorModelPreviewCamera()
        camera.setViewportSize(Size(width: 800, height: 600))
        return camera
    }

    private func mouse(_ button: MouseButton, _ phase: MouseEvent.Phase, at point: Point, modifiers: KeyModifier = []) -> MouseEvent {
        MouseEvent(window: RID(), button: button, mousePosition: point, phase: phase, modifierKeys: modifiers, time: 0)
    }

    private func key(_ key: KeyCode, _ status: KeyEvent.Status) -> KeyEvent {
        KeyEvent(window: RID(), keyCode: key, modifiers: [], status: status, time: 0, isRepeated: false)
    }
}
