//
//  TimelineViewTests.swift
//  AdaEngineTests
//
//  Created by AdaEngine on 28.05.2026.
//

@testable import AdaPlatform
@testable import AdaUI
import Foundation
import Testing

@MainActor
struct TimelineViewTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func animationScheduleRebuildsContentOnUpdate() {
        let recorder = TimelineRecorder()
        let tester = ViewTester {
            TimelineView(.animation) { context in
                TimelineRecorderView(date: context.date, cadence: context.cadence, recorder: recorder)
            }
        }

        #expect(recorder.dates.count == 1)

        tester.containerView.update(1.0 / 60.0)

        #expect(recorder.dates.count == 2)
        #expect(recorder.dates[1] >= recorder.dates[0])
        #expect(recorder.cadences == [.live, .live])
    }

    @Test
    func animationClockKeepsAdvancingAfterParentReconciliation() {
        let recorder = TimelineRecorder()
        let tester = ViewTester {
            TimelineView(.animation) { context in
                TimelineRecorderView(date: context.date, cadence: context.cadence, recorder: recorder)
            }
        }
        tester.invalidateContent().performLayout()
        recorder.dates.removeAll()
        recorder.cadences.removeAll()
        tester.containerView.update(1.0 / 60.0)
        tester.containerView.update(1.0 / 60.0)
        #expect(recorder.dates.count == 2)
        #expect(recorder.dates[1] > recorder.dates[0])
    }

    @Test
    func pausedAnimationScheduleDoesNotRebuildAfterInitialContent() {
        let recorder = TimelineRecorder()
        let tester = ViewTester {
            TimelineView(.animation(paused: true)) { context in
                TimelineRecorderView(date: context.date, cadence: context.cadence, recorder: recorder)
            }
        }

        tester.containerView.update(1)
        tester.containerView.update(1)

        #expect(recorder.dates.count == 1)
    }

    @Test
    func periodicScheduleUsesSecondCadenceAndWaitsForNextEntry() {
        let recorder = TimelineRecorder()
        let tester = ViewTester {
            TimelineView(.periodic(from: Date.distantFuture, by: 2)) { context in
                TimelineRecorderView(date: context.date, cadence: context.cadence, recorder: recorder)
            }
        }

        tester.containerView.update(1)

        #expect(recorder.dates.count == 1)
        #expect(recorder.cadences == [.seconds])
    }

    @Test
    func everyMinuteScheduleUsesMinuteCadence() {
        let recorder = TimelineRecorder()
        _ = ViewTester {
            TimelineView(.everyMinute) { context in
                TimelineRecorderView(date: context.date, cadence: context.cadence, recorder: recorder)
            }
        }

        #expect(recorder.cadences == [.minutes])
    }
}

@MainActor
private final class TimelineRecorder {
    var dates: [Date] = []
    var cadences: [TimelineCadence] = []

    func record(date: Date, cadence: TimelineCadence) {
        dates.append(date)
        cadences.append(cadence)
    }
}

private struct TimelineRecorderView: View, ViewNodeBuilder {
    typealias Body = Never

    let date: Date
    let cadence: TimelineCadence
    let recorder: TimelineRecorder

    var body: Never {
        fatalError("A test leaf builds its node directly.")
    }

    func buildViewNode(in context: BuildContext) -> ViewNode {
        recorder.record(date: date, cadence: cadence)
        return context.makeNode(from: EmptyView())
    }
}
