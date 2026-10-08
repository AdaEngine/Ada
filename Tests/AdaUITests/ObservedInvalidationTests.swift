@testable import AdaPlatform
@testable import AdaUI
import Foundation
import Math
import Observation
import Testing

@MainActor
@Suite(.serialized)
struct ObservedInvalidationTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func parentAndChildObservationRebuildChildOnce() async throws {
        let model = SharedObservationModel()
        let counts = ObservationBuildCounts()
        let tester = ViewTester { SharedObservationRoot(model: model, counts: counts) }
            .setSize(Size(width: 300, height: 200))
            .performLayout()
        let original = try #require(tester.findNodeByAccessibilityIdentifier("observed-child"))
        counts.childBuilds = 0

        model.value = 1
        for _ in 0..<20 { await Task.yield() }
        tester.performLayout()

        #expect(counts.lastValue == 1)
        #expect(counts.childBuilds == 1)
        #expect(tester.findNodeByAccessibilityIdentifier("observed-child") === original)

        // A fresh observation must still fire after the obsolete callback was discarded.
        counts.childBuilds = 0
        model.value = 2
        for _ in 0..<20 { await Task.yield() }
        tester.performLayout()
        #expect(counts.lastValue == 2)
        #expect(counts.childBuilds == 1)
    }

    @Test
    func independentChildObservationIsNotLost() async {
        let model = SharedObservationModel()
        let counts = ObservationBuildCounts()
        let tester = ViewTester { SharedObservationRoot(model: model, counts: counts) }
            .setSize(Size(width: 300, height: 200))
            .performLayout()

        model.childValue = 42
        for _ in 0..<20 { await Task.yield() }
        tester.performLayout()
        #expect(counts.lastChildValue == 42)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADA_PERFORMANCE_BENCHMARK"] == "1"))
    func measureSharedObservationUpdates() async {
        let model = SharedObservationModel()
        let counts = ObservationBuildCounts()
        let tester = ViewTester { SharedObservationRoot(model: model, counts: counts, rows: 100) }
            .setSize(Size(width: 600, height: 800))
            .performLayout()
        counts.childBuilds = 0
        let clock = ContinuousClock()
        let start = clock.now
        for value in 1...50 {
            model.value = value
            for _ in 0..<20 { await Task.yield() }
            tester.performLayout()
        }
        print("PERFORMANCE observed 100 rows x 50 updates: \(start.duration(to: clock.now)); child builds: \(counts.childBuilds)")
        #expect(counts.lastValue == 50)
    }
}

@MainActor
@Observable
private final class SharedObservationModel {
    var value = 0
    var childValue = 0
}

@MainActor
private final class ObservationBuildCounts {
    var childBuilds = 0
    var lastValue = 0
    var lastChildValue = 0

    func record(_ model: SharedObservationModel) {
        childBuilds += 1
        lastValue = model.value
        lastChildValue = model.childValue
    }
}

private struct SharedObservationRoot: View {
    let model: SharedObservationModel
    let counts: ObservationBuildCounts
    var rows = 1

    var body: some View {
        _ = model.value
        return VStack {
            ForEach(0..<rows, id: \.self) { _ in
                SharedObservationChild(model: model, counts: counts)
            }
        }
    }
}

private struct SharedObservationChild: View {
    let model: SharedObservationModel
    let counts: ObservationBuildCounts

    var body: some View {
        counts.record(model)
        return EmptyView()
            .frame(width: 80, height: 20)
            .accessibilityIdentifier("observed-child")
    }
}
