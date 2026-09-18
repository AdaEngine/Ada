@_spi(AdaEngine) import AdaEngine
import AdaMCPCore
@_spi(Internal) import AdaUI
import Math
import MCP
import Testing

@testable import AdaEditor

@Suite(.serialized)
@MainActor
struct EditorPerformanceTests {
    @Test func gameSessionAndPanelShareProfilerLifecycle() throws {
        let previous = AppWorldsSession.current
        defer { AppWorldsSession.current = previous }
        let host = AppWorlds(main: World(name: "Editor"))
        let recorder = AdaMCPTraceRecorder(configuration: .init(continuousRecording: false))
        let profiler = AdaMCPProfiler(traceRecorder: recorder)
        host.insertResource(AdaMCPProfilerResource(profiler: profiler))
        AppWorldsSession.current = host
        let session = EditorGamePerformanceSession()
        let game = AppWorlds(main: World(name: "SceneView"))
        session.attach(game, title: "Test game")
        let id = try #require(session.targetID)
        #expect(game.profilingTargetID == id)
        #expect(game.main.getResource(PhysicsPerformanceMetrics.self) != nil)
        let model = EditorPerformanceModel()
        model.appear()
        #expect(model.target?.id == id)
        #expect(recorder.tracer.isAutomaticRecordingEnabled)
        _ = try profiler.startCapture(arguments: ["targetId": .string(id), "durationMs": .int(5000)])
        model.refresh()
        #expect(model.activeCapture != nil)
        model.disappear()
        #expect(recorder.tracer.isAutomaticRecordingEnabled)
        session.stop()
        #expect(!recorder.tracer.isAutomaticRecordingEnabled)
        model.appear()
        #expect(model.status == "Stopped")
        #expect(model.capture?.objectValue?["manifest"]?.objectValue?["state"]?.stringValue == "completed")
        model.disappear()
        session.attach(AppWorlds(main: World(name: "SceneView")), title: "Next run")
        model.appear()
        #expect(model.target?.id != id)
        #expect(model.selectedCaptureID == nil)
        #expect(model.capture == nil)
        model.disappear()
        session.stop()
    }

    @Test(arguments: [Float(360), 768, 1100])
    func panelFitsAndOffersRecording(width: Float) throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "PerformanceUI")))
        }
        let previous = AppWorldsSession.current
        defer { AppWorldsSession.current = previous }
        let host = AppWorlds(main: World(name: "Editor"))
        let profiler = AdaMCPProfiler(traceRecorder: AdaMCPTraceRecorder())
        host.insertResource(AdaMCPProfilerResource(profiler: profiler))
        AppWorldsSession.current = host
        _ = profiler.performance.register(title: "Game")
        let model = EditorPerformanceModel()
        model.appear()
        defer { model.disappear() }
        let container = UIContainerView(rootView: EditorPerformancePanel(model: model).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: width, height: 360)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let record = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Performance.Record 5 s"))
        #expect(record.absoluteFrame.minX >= 0)
        #expect(record.absoluteFrame.maxX <= width)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Performance.Record 5 s"))
        #expect(try profiler.captureListPayload().objectValue?["activeCapture"] != .null)
        _ = try profiler.stopCapture(arguments: [:])
    }
}
