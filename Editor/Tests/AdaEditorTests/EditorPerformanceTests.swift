@_spi(AdaEngine) import AdaEngine
import AdaMCPCore
@_spi(Internal) import AdaUI
import Foundation
import Math
import MCP
import Testing
import Tracing

@testable import AdaEditor

@Suite(.serialized)
@MainActor
struct EditorPerformanceTests {
    @Test func delayedCaptureUsesPinnedTargetAndChosenDurationWhileHidden() async throws {
        let previous = AppWorldsSession.current
        defer { AppWorldsSession.current = previous }
        let host = AppWorlds(main: World(name: "Editor"))
        let recorder = AdaMCPTraceRecorder(configuration: .init(continuousRecording: false))
        let profiler = AdaMCPProfiler(traceRecorder: recorder)
        host.insertResource(AdaMCPProfilerResource(profiler: profiler))
        AppWorldsSession.current = host
        let id = profiler.performance.register(title: "Game")
        let model = EditorPerformanceModel()
        model.appear()
        defer { model.disappear(); model.cancelScheduledRecording() }
        model.recordingDelaySeconds = 0.05
        model.recordingDurationSeconds = 1
        model.record()
        #expect(model.scheduledTargetID == id)
        #expect(try profiler.captureListPayload().objectValue?["activeCapture"] == .null)
        model.disappear()
        _ = profiler.performance.register(title: "Another game")
        let deadline = ContinuousClock.now + .seconds(3)
        while try profiler.captureListPayload().objectValue?["activeCapture"] == .null, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let active = try #require(profiler.captureListPayload().objectValue?["activeCapture"]?.objectValue)
        #expect(active["targetId"]?.stringValue == id)
        #expect(active["durationMs"]?.intValue == 1000)
        #expect(model.scheduledTargetID == nil)
        AdaTrace.$profileTargetID.withValue(id) {
            let span = recorder.tracer.startSpan("RenderGraph.node.MainPass")
            span.attributes["ada.render.graph"] = "Main"
            span.attributes["ada.render.node"] = "MainPass"
            span.attributes["ada.render.node_type"] = "MainPassNode"
            span.end()
        }
        while try profiler.captureListPayload().objectValue?["activeCapture"] != .null, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        model.selectTarget(id)
        let captureID = try #require(profiler.captureListPayload().objectValue?["captures"]?.arrayValue?.last?.objectValue?["id"]?.stringValue)
        model.selectCapture(captureID)
        let event = try #require(model.timeline?.events.first)
        #expect(event.name == "MainPass")
        #expect(event.category == "render_node")
        #expect(event.graph == "Main")
        #expect(event.typeName == "MainPassNode")
        #expect(model.capture?.objectValue?["manifest"]?.objectValue?["state"]?.stringValue == "completed")
        #expect(!recorder.tracer.isAutomaticRecordingEnabled)
        model.recordingDelaySeconds = 0
        model.record()
        model.stopRecording()
        #expect(model.selectedCaptureID != captureID)
        #expect(model.timeline?.events.isEmpty == true)
    }

    @Test func cancellingOrStoppingScheduledTargetDoesNotRecordAnotherGame() async throws {
        let previous = AppWorldsSession.current
        defer { AppWorldsSession.current = previous }
        let host = AppWorlds(main: World(name: "Editor"))
        let profiler = AdaMCPProfiler(traceRecorder: AdaMCPTraceRecorder())
        host.insertResource(AdaMCPProfilerResource(profiler: profiler))
        AppWorldsSession.current = host
        let id = profiler.performance.register(title: "Game")
        let other = profiler.performance.register(title: "Other")
        let model = EditorPerformanceModel()
        model.appear()
        defer { model.disappear(); model.cancelScheduledRecording() }
        model.selectTarget(id)
        model.recordingDelaySeconds = 0.02
        model.record()
        model.selectTarget(other)
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.scheduledTargetID == nil)
        #expect(try profiler.captureListPayload().objectValue?["activeCapture"] == .null)
        model.selectTarget(id)
        model.record()
        try profiler.stopTarget(id)
        model.refresh()
        #expect(model.errorMessage == "Scheduled game stopped before recording began.")
        try await Task.sleep(for: .milliseconds(50))
        #expect(try profiler.captureListPayload().objectValue?["captures"]?.arrayValue?.isEmpty == true)
        model.selectTarget(other)
        model.record()
        let competing = try profiler.startCapture(arguments: ["targetId": .string(other), "durationMs": .int(5000)])
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.scheduledTargetID == nil)
        #expect(model.errorMessage?.contains("already active") == true)
        #expect(try profiler.captureListPayload().objectValue?["activeCapture"]?.objectValue?["id"] == competing.objectValue?["id"])
        _ = try profiler.stopCapture(arguments: [:])
    }

    @Test func timelinePreservesOrderGraphsAndConcurrentCalls() throws {
        func event(_ name: String, start: Double, duration: Double, graph: String = "Main") -> Value {
            .object(["name": .string(name), "ph": .string("X"), "cat": .string("render_node"),
                     "ts": .double(start), "dur": .double(duration), "args": .object(["ada.render.graph": .string(graph)])])
        }
        let timeline = EditorPerformanceTimeline(trace: .object(["traceEvents": .array([
            event("Pass", start: 1_002_000, duration: 500),
            event("Pass", start: 1_000_000, duration: 4000),
            event("Pass", start: 1_004_000, duration: 1000),
            event("Pass", start: 1_000_000, duration: 1000, graph: "Shadow"),
            event("Invalid", start: .infinity, duration: 1000),
            event("Invalid", start: 0, duration: -1),
            .object(["ph": .string("B"), "name": .string("Incomplete")])
        ])]))
        #expect(timeline.events.map(\.startMs) == [0, 0, 2, 4])
        #expect(timeline.durationMs == 5)
        let lane = try #require(timeline.lanes.first { $0.title == "Main / Pass" })
        #expect(lane.rows.count == 2)
        #expect(lane.rows[0].map(\.startMs) == [0, 4])
        #expect(timeline.lanes.count == 2)
        #expect(EditorPerformanceTimeline.hitTest(events: lane.events, timeMs: 2.25, toleranceMs: 0)?.durationMs == 0.5)
        #expect(EditorPerformanceTimeline.hitTest(events: lane.events, timeMs: 6, toleranceMs: 0) == nil)
    }

    @Test(arguments: [Float(360), 768, 1100])
    func timelineCallSelectionUsesRealInput(width: Float) async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "PerformanceUI")))
        }
        let timeline = EditorPerformanceTimeline(trace: .object(["traceEvents": .array([
            .object(["name": .string("MainPass"), "ph": .string("X"), "cat": .string("render_node"),
                     "ts": .double(1000), "dur": .double(2000), "args": .object(["ada.render.graph": .string("Main")])])
        ])]))
        let container = UIContainerView(rootView: EditorPerformanceTimelineView(timeline: timeline).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: width, height: 500)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        for _ in 0..<4 { try await Task.sleep(for: .milliseconds(10)); container.layoutIfNeeded() }
        let lane = try #require(timeline.lanes.first)
        let selector = UINodeSelector.accessibilityIdentifier("AdaEditor.Performance.Timeline.Row.\(lane.id).0")
        let row = try container.uiNode(matching: selector)
        #expect(row.absoluteFrame.maxX <= width)
        _ = try container.uiTapNode(matching: selector)
        for _ in 0..<4 { try await Task.sleep(for: .milliseconds(10)); container.layoutIfNeeded() }
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Performance.SelectedEvent"))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Performance.Timeline.+"))
        for _ in 0..<4 { try await Task.sleep(for: .milliseconds(10)); container.layoutIfNeeded() }
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Performance.Timeline.Fit"))
    }

    @Test func expandedPerformanceRestoresWorkspaceGeometry() {
        let model = EditorViewModel(project: nil)
        model.showBottomPanel = true
        let resize = EditorWorkspaceResizeState()
        let size = Size(width: 1200, height: 700)
        let original = resize.layout(in: size, viewModel: model)
        #expect(original.showsBottomPanel)
        model.performance.isExpanded = true
        #expect(resize.layout(in: size, viewModel: model).mainPanelHeight == 700)
        model.performance.isExpanded = false
        #expect(resize.layout(in: size, viewModel: model) == original)
    }

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
        model.appear(presentation: .workspace)
        model.disappear()
        #expect(model.isVisible)
        #expect(recorder.tracer.isAutomaticRecordingEnabled)
        model.disappear(presentation: .workspace)
        #expect(!recorder.tracer.isAutomaticRecordingEnabled)
        model.appear()
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
