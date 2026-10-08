//
//  ViewStoragesTests.swift
//
//
//  Created by vladislav.prusakov on 12.08.2024.
//

import Testing
import AdaUtils
import Observation
@testable import AdaUI
@testable import AdaPlatform

@MainActor
struct ViewStoragesTests {

    init() async throws {
        try Application.prepareForTest()
    }

    /// Verifies `@State` survives node updates and explicit recompose.
    ///
    /// Why this test exists:
    /// `ViewNode.update(from:)` replaces `content` and rebinds storages.
    /// If state storage is kept weakly, old content deallocation drops the only
    /// strong reference and state is recreated from its initial value.
    ///
    /// Regression protected:
    /// - old `StateStorage` is not strongly retained by `ViewStateContainer`;
    /// - rebind by the same storage key recreates storage from initial value.
    @Test
    func stateStorage_isRetainedAcrossRecompose() {
        let container = ViewStateContainer()
        let key = ViewStatePropertyKey(
            ordinal: 0,
            label: "_value",
            valueType: ObjectIdentifier(Int.self)
        )

        let firstState = State(wrappedValue: 0)
        firstState.bind(to: container, key: key)
        firstState.wrappedValue = 42

        let reboundState = State(wrappedValue: 0)
        reboundState.bind(to: container, key: key)

        #expect(reboundState.wrappedValue == 42)
    }

    @Test
    func stateStorageKey_requiresMatchingOrdinalLabelAndValueType() {
        let container = ViewStateContainer()
        let key = ViewStatePropertyKey(
            ordinal: 0,
            label: "_value",
            valueType: ObjectIdentifier(Int.self)
        )

        let firstState = State(wrappedValue: 0)
        firstState.bind(to: container, key: key)
        firstState.wrappedValue = 42

        let sameKeyState = State(wrappedValue: 0)
        sameKeyState.bind(to: container, key: key)
        #expect(sameKeyState.wrappedValue == 42)

        let differentOrdinalState = State(wrappedValue: 0)
        differentOrdinalState.bind(
            to: container,
            key: ViewStatePropertyKey(
                ordinal: 1,
                label: "_value",
                valueType: ObjectIdentifier(Int.self)
            )
        )
        #expect(differentOrdinalState.wrappedValue == 0)

        let differentLabelState = State(wrappedValue: 0)
        differentLabelState.bind(
            to: container,
            key: ViewStatePropertyKey(
                ordinal: 0,
                label: "_renamedValue",
                valueType: ObjectIdentifier(Int.self)
            )
        )
        #expect(differentLabelState.wrappedValue == 0)

        let stringState = State(wrappedValue: "fresh")
        stringState.bind(
            to: container,
            key: ViewStatePropertyKey(
                ordinal: 0,
                label: "_value",
                valueType: ObjectIdentifier(String.self)
            )
        )
        stringState.wrappedValue = "changed"

        let reboundIntState = State(wrappedValue: 0)
        reboundIntState.bind(to: container, key: key)
        #expect(reboundIntState.wrappedValue == 42)
    }

    @Test
    func stateInitialValue_isLazyUntilStateStorageIsRead() {
        StateInitialValueProbe.initialValueEvaluations = 0

        _ = StateInitialValueProbe()

        #expect(StateInitialValueProbe.initialValueEvaluations == 0)
    }

    @Test
    func stateMacro_infersTypeFromConstructorInitialValue() {
        _ = ConstructedStateInitialValueProbe()
    }

    @Test
    func multipleStatesInOneView_doNotSwapAfterRebuild() {
        let recorder = StateIdentityRecorder()
        let tester = ViewTester(rootView: MultipleStateHost(recorder: recorder))

        recorder.bindings["first"]?.wrappedValue = 11
        recorder.bindings["second"]?.wrappedValue = 22
        tester.invalidateContent().performLayout()

        #expect(recorder.values["first"] == 11)
        #expect(recorder.values["second"] == 22)
    }

    @Test
    func nestedViews_keepSameNamedStatesIndependentAfterRebuild() {
        let recorder = StateIdentityRecorder()
        let tester = ViewTester(rootView: NestedStateHost(recorder: recorder))

        recorder.bindings["parent"]?.wrappedValue = 7
        recorder.bindings["child"]?.wrappedValue = 17
        tester.invalidateContent().performLayout()

        #expect(recorder.values["parent"] == 7)
        #expect(recorder.values["child"] == 17)
    }

    @Test
    func siblingInstances_keepSameNamedStatesIndependentAfterRebuild() {
        let recorder = StateIdentityRecorder()
        let tester = ViewTester(rootView: SiblingStateHost(recorder: recorder))

        recorder.bindings["first"]?.wrappedValue = 31
        tester.invalidateContent().performLayout()

        #expect(recorder.values["first"] == 31)
        #expect(recorder.values["second"] == 0)
    }

    @Test
    func conditionalBranches_doNotTransferSameNamedStateAfterRebuild() {
        let showsFirst = BindingBox(true)
        let recorder = StateIdentityRecorder()
        let tester = ViewTester(rootView: ConditionalStateHost(showsFirst: showsFirst.binding, recorder: recorder))

        recorder.bindings["first"]?.wrappedValue = 51
        showsFirst.value = false
        tester.invalidateContent().performLayout()

        #expect(recorder.values["second"] == 0)
    }

    @Test
    func observedDetachedContainer_isNotRetainedByObservationCallback() {
        let model = ObservationRetentionModel()
        weak var weakNode: ViewNode?

        do {
            let view = ObservationRetentionView(model: model)
            let inputs = _ViewInputs(parentNode: nil, environment: EnvironmentValues())
            let output = ObservationRetentionView._makeView(
                _ViewGraphNode(value: view),
                inputs: inputs
            )
            weakNode = output.node
        }

        #expect(weakNode == nil)
    }
}

private final class StateIdentityRecorder {
    var bindings: [String: Binding<Int>] = [:]
    var values: [String: Int] = [:]

    func record(label: String, value: Int, binding: Binding<Int>) {
        bindings[label] = binding
        values[label] = value
    }
}

private final class BindingBox<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }

    var binding: Binding<Value> {
        Binding(
            get: { self.value },
            set: { self.value = $0 }
        )
    }
}

private struct StateInitialValueProbe: View {
    static var initialValueEvaluations = 0

    @State private var value: Int = makeInitialValue()

    static func makeInitialValue() -> Int {
        initialValueEvaluations += 1
        return 42
    }

    var body: some View {
        Text("\(value)")
    }
}

private struct ConstructedStateValue {
    var count = 0
}

private struct ConstructedStateInitialValueProbe: View {
    @State private var value = ConstructedStateValue()

    var body: some View {
        Text("\(value.count)")
    }
}

private struct MultipleStateHost: View {
    let recorder: StateIdentityRecorder

    @State private var first = 0
    @State private var second = 100

    var body: some View {
        let _ = recorder.record(label: "first", value: first, binding: $first)
        let _ = recorder.record(label: "second", value: second, binding: $second)
        Text("\(first):\(second)")
    }
}

private struct NestedStateHost: View {
    let recorder: StateIdentityRecorder

    @State private var value = 0

    var body: some View {
        let _ = recorder.record(label: "parent", value: value, binding: $value)
        VStack {
            NestedStateChild(recorder: recorder)
        }
    }
}

private struct NestedStateChild: View {
    let recorder: StateIdentityRecorder

    @State private var value = 100

    var body: some View {
        let _ = recorder.record(label: "child", value: value, binding: $value)
        Text("\(value)")
    }
}

private struct SiblingStateHost: View {
    let recorder: StateIdentityRecorder

    var body: some View {
        VStack {
            StatefulStorageProbe(label: "first", recorder: recorder)
            StatefulStorageProbe(label: "second", recorder: recorder)
        }
    }
}

private struct ConditionalStateHost: View {
    let showsFirst: Binding<Bool>
    let recorder: StateIdentityRecorder

    var body: some View {
        if showsFirst.wrappedValue {
            StatefulStorageProbe(label: "first", recorder: recorder)
        } else {
            StatefulStorageProbe(label: "second", recorder: recorder)
        }
    }
}

private struct StatefulStorageProbe: View {
    let label: String
    let recorder: StateIdentityRecorder

    @State private var value = 0

    var body: some View {
        let _ = recorder.record(label: label, value: value, binding: $value)
        Text("\(label):\(value)")
    }
}

@Observable
private final class ObservationRetentionModel {
    var counter = 0
}

private struct ObservationRetentionView: View {
    let model: ObservationRetentionModel

    var body: some View {
        let _ = model.counter
        EmptyView()
    }
}
