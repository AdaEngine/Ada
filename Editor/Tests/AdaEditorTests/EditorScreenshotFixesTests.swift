@_spi(Internal) import AdaApp
@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Testing

@testable import AdaEditor

@Suite("Editor screenshot fixes")
@MainActor
struct EditorScreenshotFixesTests {
    @Test("pinch zoom preserves the world point under the fingers and uses cumulative scale")
    func pinchAnchorsAndClampsZoom() {
        let model = EditorSceneViewportModel()
        model.setViewportSize(Size(width: 800, height: 600))
        let point = Point(600, 200)
        let window = RID()
        func event(_ phase: PinchEvent.Phase, _ scale: Float) -> PinchEvent {
            PinchEvent(window: window, location: point, scale: scale, phase: phase, time: 0)
        }
        #expect(model.handleInput(event(.began, 1)))
        #expect(model.handleInput(event(.changed, 2)))
        #expect(model.twoDZoom == 2)
        #expect(model.worldToScreen(Vector2(200, 100), size: model.viewportSize) == point)
        #expect(model.handleInput(event(.changed, 3)))
        #expect(model.twoDZoom == 3)
        #expect(model.handleInput(event(.ended, 3)))
        #expect(model.twoDZoom == 3)
        #expect(!model.handleInput(event(.changed, 4)))
        #expect(model.handleInput(event(.began, 1)))
        #expect(model.handleInput(event(.changed, 100)))
        #expect(model.twoDZoom == 24)
        #expect(!model.handleInput(event(.changed, .nan)))
        #expect(model.handleInput(event(.cancelled, 100)))
        #expect(model.handleInput(event(.began, 1)))
        #expect(model.handleInput(event(.ended, 0.0001)))
        #expect(model.twoDZoom == 0.08)
    }

    @Test("ruler tick positions follow camera pan and zoom")
    func rulerTracksCamera() throws {
        let model = EditorSceneViewportModel()
        let size = Size(width: 800, height: 600)
        model.setViewportSize(size)
        model.pan2D(byScreenDelta: Vector2(70, 40))
        model.zoom2D(by: 2)
        let ruler = model.coordinateRuler(in: size)
        let x = try #require(ruler.labels.first { $0.axis == .x && $0.value == 0 })
        let y = try #require(ruler.labels.first { $0.axis == .y && $0.value == 0 })
        let origin = model.worldToScreen(.zero, size: size)
        #expect(x.position.x == origin.x)
        #expect(y.position.y == origin.y)
    }

    @Test("runtime worlds separate game logs from editor logs including child tasks")
    func runtimeLogSources() async {
        let store = RuntimeLogStore(capacity: 10)
        store.setEnabled(true)
        let app = AppWorlds(main: World(name: "Log routing test"))
        app.runtimeLogSource = "Game"
        await app.withExecutionContext {
            await Task {
                store.append(level: "info", label: "Test", message: "Game message")
            }
            .value
        }
        store.append(level: "warning", label: "Test", message: "Editor message")
        let model = EditorViewModel(outputLines: [])
        model.collectRuntimeLogs(store: store)
        #expect(model.gameLogLines.map(\.text) == ["INFO [Test] Game message"])
        #expect(model.outputLines.map(\.text) == ["WARNING [Test] Editor message"])
        model.collectRuntimeLogs(store: store)
        #expect(model.gameLogLines.count == 1)
        #expect(model.outputLines.count == 1)
        let logs = EditorToolStripItem(identifier: "logs", title: "Logs", icon: "")
        model.toolStrip.selectLeftBottomTool(logs)
        model.showBottomPanel = true
        model.activeOutputTab = "Problems"
        model.activateLeftBottomTool(logs)
        #expect(model.activeOutputTab == "Output")
        #expect(model.showBottomPanel)
    }

    @Test("footer reads unborn, switched, detached and missing repositories")
    func gitFooterReadsRealRepository() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await GitRepositoryService.currentBranchFooter(projectURL: root) == nil)
        let runner = EditorProcessRunner()
        func git(_ arguments: [String]) async throws {
            let result = await runner.run(EditorProcessCommand(executablePath: "/usr/bin/git", arguments: arguments, workingDirectory: root))
            #expect(result.succeeded, "\(result.combinedOutput)")
        }
        try await git(["init", "-b", "screenshot-test"])
        #expect(await GitRepositoryService.currentBranchFooter(projectURL: root) == "Git: screenshot-test")
        try await git(["-c", "user.name=Editor Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "Fixture"])
        try await git(["checkout", "-b", "changed-branch"])
        #expect(await GitRepositoryService.currentBranchFooter(projectURL: root) == "Git: changed-branch")
        try await git(["checkout", "--detach"])
        #expect(await GitRepositoryService.currentBranchFooter(projectURL: root) == "Git: Detached HEAD")
    }
}
