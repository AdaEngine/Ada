//
//  ViewVisibilityTests.swift
//
//
//  Created by vladislav.prusakov on 11.08.2024.
//

import Testing
@testable import AdaUI
@testable import AdaPlatform
import AdaInput
import AdaUtils
import Math

@MainActor
struct ViewVisibilityTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func onAppear_calledWhenViewAddedToTree() async {
        var appeared = false
        _ = ViewTester {
            Color.blue
                .frame(width: 50, height: 50)
                .onAppear { appeared = true }
        }
        await flushLifecycleActions()
        #expect(appeared)
    }

    @Test
    func onAppear_calledOnce_onMultipleLayouts() async {
        var count = 0
        let tester = ViewTester {
            Color.blue
                .frame(width: 50, height: 50)
                .onAppear { count += 1 }
        }
        await flushLifecycleActions()
        tester.performLayout()
        tester.performLayout()
        #expect(count == 1)
    }

    @Test
    func onDisappear_calledWhenNodeDetachedFromTree() async {
        var disappeared = false
        let tester = ViewTester {
            Color.blue
                .frame(width: 50, height: 50)
                .onDisappear { disappeared = true }
        }
        await flushLifecycleActions()
        #expect(!disappeared)

        let contentNode = tester.containerView.viewTree.rootNode.contentNode
        contentNode.parent = nil
        await flushLifecycleActions()

        #expect(disappeared)
    }

    @Test
    func onDisappear_notCalled_whenNeverAppeared() {
        var disappeared = false
        let inputs = _ViewInputs(parentNode: nil, environment: EnvironmentValues())
        let colorView = Color.blue
        let contentNode = Color._makeView(_ViewGraphNode(value: colorView), inputs: inputs).node
        let node = VisibilityViewNode(contentNode: contentNode, content: colorView)
        node.onDisappear = { disappeared = true }

        node.parent = nil
        #expect(!disappeared)
    }

    @Test
    func onAppearAndOnDisappear_bothFire_forSameView() async {
        var appeared = false
        var disappeared = false

        let tester = ViewTester {
            Color.blue
                .frame(width: 50, height: 50)
                .onAppear { appeared = true }
                .onDisappear { disappeared = true }
        }
        await flushLifecycleActions()

        #expect(appeared)
        #expect(!disappeared)

        let contentNode = tester.containerView.viewTree.rootNode.contentNode
        contentNode.parent = nil
        await flushLifecycleActions()

        #expect(disappeared)
    }

    @Test
    func onAppear_firesAgain_onReInsertion() async {
        final class Model {
            var isVisible = true
        }

        let model = Model()
        var appearCount = 0
        var disappearCount = 0

        let tester = ViewTester(rootView: ConditionalVisibilityHost(
            isVisible: Binding(
                get: { model.isVisible },
                set: { model.isVisible = $0 }
            ),
            onAppear: { appearCount += 1 },
            onDisappear: { disappearCount += 1 }
        ))
        await flushLifecycleActions()

        #expect(appearCount == 1)
        #expect(disappearCount == 0)

        model.isVisible = false
        tester.invalidateContent()
        await flushLifecycleActions()

        #expect(disappearCount == 1)

        model.isVisible = true
        tester.invalidateContent()
        await flushLifecycleActions()

        #expect(appearCount == 2)
    }

    @Test
    func onDisappear_firesOnTabSwitch() async {
        final class Model {
            var selected: Int = 0
        }

        let model = Model()
        var tabAAppeared = false
        var tabADisappeared = false
        var tabBAppeared = false

        let tester = ViewTester {
            TabView(
                selection: Binding(
                    get: { model.selected },
                    set: { model.selected = $0 }
                )
            ) {
                Tab("", value: 0) {
                    Color.red
                        .frame(width: 100, height: 100)
                        .onAppear { tabAAppeared = true }
                        .onDisappear { tabADisappeared = true }
                }
                Tab("", value: 1) {
                    Color.blue
                        .frame(width: 100, height: 100)
                        .onAppear { tabBAppeared = true }
                }
            }
        }
        .setSize(Size(width: 400, height: 200))
        .performLayout()
        await flushLifecycleActions()

        #expect(tabAAppeared)
        #expect(!tabADisappeared)
        #expect(!tabBAppeared)

        model.selected = 1
        tester.invalidateContent()
        await flushLifecycleActions()

        #expect(!tabADisappeared)
        #expect(tabBAppeared)
        tester.advanceFrame(deltaTime: 0.3)
        await flushLifecycleActions()
        #expect(tabADisappeared)
    }

    @Test
    func onAppear_stateMutationIsDeferredUntilAfterTreeAttachment() async {
        let recorder = LifecycleMutationRecorder()
        let tester = ViewTester(rootView: LifecycleStateMutationHost(recorder: recorder))

        #expect(recorder.appearCount == 0)
        #expect(recorder.value == 0)

        await flushLifecycleActions()
        tester.performLayout()

        #expect(recorder.appearCount == 1)
        #expect(recorder.value == 1)
    }

    @Test
    func onAppear_notCalledWhenDetachedBeforeLifecycleFlush() async {
        var appeared = false
        let tester = ViewTester {
            Color.blue
                .frame(width: 50, height: 50)
                .onAppear { appeared = true }
        }

        tester.containerView.viewTree.rootNode.contentNode.parent = nil
        await flushLifecycleActions()

        #expect(!appeared)
    }

    @Test
    func onAppear_notCalledWhenAncestorDetachedBeforeLifecycleFlush() async {
        var appeared = false
        let tester = ViewTester {
            VStack {
                Color.blue
                    .frame(width: 50, height: 50)
                    .onAppear { appeared = true }
            }
        }

        tester.containerView.viewTree.rootNode.contentNode.parent = nil
        await flushLifecycleActions()

        #expect(!appeared)
    }

    @Test
    func task_startsWhenViewAppears() async {
        let recorder = TaskLifecycleRecorder()
        _ = ViewTester {
            Color.blue
                .frame(width: 50, height: 50)
                .task {
                    await recorder.runUntilCancelled()
                }
        }

        await flushLifecycleActions()
        await waitForTaskStart(recorder)
        #expect(await recorder.startCount == 1)
    }

    @Test
    func task_cancelsWhenViewDisappears() async {
        let recorder = TaskLifecycleRecorder()
        let tester = ViewTester {
            Color.blue
                .frame(width: 50, height: 50)
                .task {
                    await recorder.runUntilCancelled()
                }
        }
        await flushLifecycleActions()

        tester.containerView.viewTree.rootNode.contentNode.parent = nil
        await waitForTaskCancellation(recorder)

        #expect(await recorder.cancellationCount == 1)
    }

    @Test
    func task_doesNotStartWhenDetachedBeforeLifecycleFlush() async {
        let recorder = TaskLifecycleRecorder()
        let tester = ViewTester {
            Color.blue
                .frame(width: 50, height: 50)
                .task {
                    await recorder.runUntilCancelled()
                }
        }

        tester.containerView.viewTree.rootNode.contentNode.parent = nil
        await flushLifecycleActions()

        #expect(await recorder.startCount == 0)
    }

    @Test
    func task_restartsOnReInsertion() async {
        final class Model {
            var isVisible = true
        }

        let model = Model()
        let recorder = TaskLifecycleRecorder()
        let tester = ViewTester(rootView: ConditionalTaskHost(
            isVisible: Binding(
                get: { model.isVisible },
                set: { model.isVisible = $0 }
            ),
            recorder: recorder
        ))
        await flushLifecycleActions()
        await waitForTaskStart(recorder)

        #expect(await recorder.startCount == 1)

        model.isVisible = false
        tester.invalidateContent()
        await waitForTaskCancellation(recorder)

        #expect(await recorder.cancellationCount == 1)

        model.isVisible = true
        tester.invalidateContent()
        await flushLifecycleActions()
        await waitForTaskStart(recorder, count: 2)

        #expect(await recorder.startCount == 2)
    }
}

private func flushLifecycleActions() async {
    await Task.yield()
}

private func waitForTaskCancellation(_ recorder: TaskLifecycleRecorder) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
        if await recorder.cancellationCount > 0 {
            return
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

private func waitForTaskStart(_ recorder: TaskLifecycleRecorder, count: Int = 1) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
        if await recorder.startCount >= count {
            return
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

private final class LifecycleMutationRecorder {
    var appearCount = 0
    var value = 0
}

private struct LifecycleStateMutationHost: View {
    let recorder: LifecycleMutationRecorder

    @State private var value = 0

    var body: some View {
        let _ = recorder.value = value
        Text("\(value)")
            .onAppear {
                recorder.appearCount += 1
                value = 1
            }
    }
}

private struct ConditionalVisibilityHost: View {
    let isVisible: Binding<Bool>
    let onAppear: () -> Void
    let onDisappear: () -> Void

    var body: some View {
        if isVisible.wrappedValue {
            Color.blue
                .frame(width: 50, height: 50)
                .onAppear(perform: onAppear)
                .onDisappear(perform: onDisappear)
        } else {
            EmptyView()
        }
    }
}

private actor TaskLifecycleRecorder {
    private(set) var startCount = 0
    private(set) var cancellationCount = 0

    func runUntilCancelled() async {
        startCount += 1

        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                break
            }
        }

        cancellationCount += 1
    }
}

private struct ConditionalTaskHost: View {
    let isVisible: Binding<Bool>
    let recorder: TaskLifecycleRecorder

    var body: some View {
        if isVisible.wrappedValue {
            Color.blue
                .frame(width: 50, height: 50)
                .task {
                    await recorder.runUntilCancelled()
                }
        } else {
            EmptyView()
        }
    }
}
