//
//  ViewIdentityTests.swift
//  AdaEngine
//
//  Created by Codex on 19.05.2026.
//

import AdaAnimation
@testable import AdaPlatform
@testable import AdaUI
import AdaUtils
import Math
import Testing

@MainActor
struct ViewIdentityTests {

    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func nestedVirtualGroupsPreserveRowsOnFirstUpdate() throws {
        let items = BindingBox(["a", "b", "c"])
        let recorder = IdentityRecorder()
        let tester = ViewTester {
            VStack {
                Text("Components")
                Group {
                    ForEach(items.value, id: \.self) { item in
                        StatefulIdentityRow(label: item, recorder: recorder)
                    }
                    Text("Add Component")
                }
            }
        }
        .setSize(Size(width: 300, height: 400))
        .performLayout()
        let initialRow = try #require(tester.findNodeByAccessibilityIdentifier("row-b"))
        let counter = try #require(recorder.counters["b"])

        counter.wrappedValue = 7
        tester.invalidateContent().performLayout()
        #expect(tester.findNodeByAccessibilityIdentifier("row-b") === initialRow)
        #expect(recorder.values["b"] == 7)

        items.value = ["c", "b", "a"]
        tester.invalidateContent().performLayout()
        #expect(tester.findNodeByAccessibilityIdentifier("row-b") === initialRow)
        #expect(recorder.values["b"] == 7)
    }

    @Test
    func forEachReorderPreservesStateByExplicitID() {
        let items = BindingBox(["a", "b", "c"])
        let recorder = IdentityRecorder()
        let tester = ViewTester(rootView: ForEachIdentityHost(items: items.binding, recorder: recorder))

        guard let counter = recorder.counters["b"] else {
            Issue.record("Expected row b to register its state binding.")
            return
        }

        counter.wrappedValue = 11
        items.value = ["c", "a", "b"]
        tester.invalidateContent().performLayout()

        #expect(recorder.values["a"] == 0)
        #expect(recorder.values["b"] == 11)
        #expect(recorder.values["c"] == 0)
    }

    @Test
    func forEachInsideStackBuildsHittableChildrenOnInitialLayout() {
        let tester = ViewTester(rootView: VStack(spacing: 0) {
            ForEach(["fileTree", "inspector"], id: \.self) { identifier in
                Button(action: {}) {
                    RectangleShape()
                        .fill(Color.blue)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(DefaultButtonStyle())
                .accessibilityIdentifier("tool-\(identifier)")
            }
        })
        .setSize(Size(width: 40, height: 80))
        .performLayout()

        let fileTreeNode = tester.findNodeByAccessibilityIdentifier("tool-fileTree")
        let inspectorNode = tester.findNodeByAccessibilityIdentifier("tool-inspector")

        #expect(fileTreeNode?.absoluteFrame().size == Size(width: 30, height: 30))
        #expect(inspectorNode?.absoluteFrame().size == Size(width: 30, height: 30))
        #expect(tester.findHitPoint(forAccessibilityIdentifier: "tool-fileTree", in: Rect(x: 0, y: 0, width: 40, height: 40), step: 2) != nil)
        #expect(tester.findHitPoint(forAccessibilityIdentifier: "tool-inspector", in: Rect(x: 0, y: 30, width: 40, height: 40), step: 2) != nil)
    }

    @Test
    func unkeyedInsertionInMiddlePreservesSuffixState() {
        let isInserted = BindingBox(false)
        let recorder = IdentityRecorder()
        let tester = ViewTester(rootView: MiddleInsertionHost(isInserted: isInserted.binding, recorder: recorder))

        guard let counter = recorder.counters["b"] else {
            Issue.record("Expected row b to register its state binding.")
            return
        }

        counter.wrappedValue = 7
        isInserted.value = true
        tester.invalidateContent().performLayout()

        #expect(recorder.values["x"] == 0)
        #expect(recorder.values["b"] == 7)
    }

    @Test
    func unkeyedDeletionInMiddlePreservesSuffixState() {
        let isInserted = BindingBox(true)
        let recorder = IdentityRecorder()
        let tester = ViewTester(rootView: MiddleInsertionHost(isInserted: isInserted.binding, recorder: recorder))

        guard let counter = recorder.counters["b"] else {
            Issue.record("Expected row b to register its state binding.")
            return
        }

        counter.wrappedValue = 9
        isInserted.value = false
        tester.invalidateContent().performLayout()

        #expect(recorder.values["b"] == 9)
    }

    @Test
    func mixedKeyedAndUnkeyedInsertionPreservesUnkeyedSuffixState() {
        let isInserted = BindingBox(false)
        let recorder = IdentityRecorder()
        let tester = ViewTester(rootView: MixedIdentityHost(isInserted: isInserted.binding, recorder: recorder))

        guard let counter = recorder.counters["static"] else {
            Issue.record("Expected static row to register its state binding.")
            return
        }

        counter.wrappedValue = 5
        isInserted.value = true
        tester.invalidateContent().performLayout()

        #expect(recorder.values["inserted"] == 0)
        #expect(recorder.values["static"] == 5)
    }

    @Test
    func conditionalBranchesDoNotTransferStateAcrossSameViewType() {
        let showsFirst = BindingBox(true)
        let recorder = IdentityRecorder()
        let tester = ViewTester(rootView: ConditionalIdentityHost(showsFirst: showsFirst.binding, recorder: recorder))

        guard let firstCounter = recorder.counters["first"] else {
            Issue.record("Expected first branch to register its state binding.")
            return
        }

        firstCounter.wrappedValue = 13
        showsFirst.value = false
        tester.invalidateContent().performLayout()

        #expect(recorder.values["second"] == 0)
    }

    @Test
    func focusStaysOnReorderedForEachItem() {
        let items = BindingBox(["a", "b", "c"])
        let model = TextFieldIdentityModel()
        let tester = ViewTester(rootView: FocusIdentityHost(items: items.binding, model: model))
            .setSize(Size(width: 320, height: 180))
            .performLayout()

        guard let point = tester.findHitPoint(
            forAccessibilityIdentifier: "field-b",
            in: Rect(x: 0, y: 0, width: 320, height: 180),
            step: 2
        ) else {
            Issue.record("Expected to find a hittable point for field-b.")
            return
        }

        tester.sendMouseEvent(at: point, phase: .began, time: 0)
        tester.sendMouseEvent(at: point, phase: .ended, time: 0.01)
        let focusedBefore = tester.containerView.inspectionFocusedNode.map(ObjectIdentifier.init)

        items.value = ["c", "a", "b"]
        tester.invalidateContent().performLayout()

        #expect(tester.containerView.inspectionFocusedNode.map(ObjectIdentifier.init) == focusedBefore)
        #expect(tester.containerView.inspectionFocusedNode?.parent != nil)

        tester.sendTextInput("Z", time: 0.02)
        #expect(model.texts["b"] == "Z")
        #expect(model.texts["a"] == "")
        #expect(model.texts["c"] == "")
    }

    @Test
    func animationNodeSurvivesForEachReorder() {
        let items = BindingBox(["a", "b", "c"])
        let recorder = IdentityRecorder()
        let tester = ViewTester(rootView: AnimatedIdentityHost(items: items.binding, recorder: recorder))
            .setSize(Size(width: 320, height: 180))
            .performLayout()

        guard let counter = recorder.counters["b"] else {
            Issue.record("Expected animated row b to register its state binding.")
            return
        }

        counter.wrappedValue = 1
        tester.performLayout()

        guard let animatedBefore = animatedNode(for: "animated-b", in: tester).map(ObjectIdentifier.init) else {
            Issue.record("Expected to find animated node for row b.")
            return
        }

        items.value = ["c", "a", "b"]
        tester.invalidateContent().performLayout()

        #expect(animatedNode(for: "animated-b", in: tester).map(ObjectIdentifier.init) == animatedBefore)
    }

    private func animatedNode<Content: View>(for identifier: String, in tester: ViewTester<Content>) -> ViewNode? {
        var current = tester.findNodeByAccessibilityIdentifier(identifier)
        while let node = current {
            if String(describing: type(of: node)).hasPrefix("AnimatedViewNode") {
                return node
            }
            current = node.parent
        }
        return nil
    }
}

private final class IdentityRecorder {
    var counters: [String: Binding<Int>] = [:]
    var values: [String: Int] = [:]

    func record(label: String, value: Int, counter: Binding<Int>) {
        counters[label] = counter
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

private struct StatefulIdentityRow: View {
    let label: String
    let recorder: IdentityRecorder

    @State private var counter = 0

    var body: some View {
        let _ = recorder.record(label: label, value: counter, counter: $counter)
        Text("\(label):\(counter)")
            .frame(width: 96, height: 24)
            .accessibilityIdentifier("row-\(label)")
    }
}

private struct ForEachIdentityHost: View {
    let items: Binding<[String]>
    let recorder: IdentityRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items.wrappedValue, id: \.self) { item in
                StatefulIdentityRow(label: item, recorder: recorder)
            }
        }
    }
}

private struct MiddleInsertionHost: View {
    let isInserted: Binding<Bool>
    let recorder: IdentityRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            StatefulIdentityRow(label: "a", recorder: recorder)
            if isInserted.wrappedValue {
                StatefulIdentityRow(label: "x", recorder: recorder)
            }
            StatefulIdentityRow(label: "b", recorder: recorder)
        }
    }
}

private struct MixedIdentityHost: View {
    let isInserted: Binding<Bool>
    let recorder: IdentityRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            StatefulIdentityRow(label: "key-a", recorder: recorder)
                .id("key-a")
            if isInserted.wrappedValue {
                StatefulIdentityRow(label: "inserted", recorder: recorder)
            }
            StatefulIdentityRow(label: "static", recorder: recorder)
            StatefulIdentityRow(label: "key-b", recorder: recorder)
                .id("key-b")
        }
    }
}

private struct ConditionalIdentityHost: View {
    let showsFirst: Binding<Bool>
    let recorder: IdentityRecorder

    var body: some View {
        if showsFirst.wrappedValue {
            StatefulIdentityRow(label: "first", recorder: recorder)
        } else {
            StatefulIdentityRow(label: "second", recorder: recorder)
        }
    }
}

private final class TextFieldIdentityModel {
    var texts: [String: String] = [
        "a": "",
        "b": "",
        "c": ""
    ]
}

private struct FocusIdentityHost: View {
    let items: Binding<[String]>
    let model: TextFieldIdentityModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items.wrappedValue, id: \.self) { item in
                TextField(
                    item,
                    text: Binding(
                        get: { model.texts[item] ?? "" },
                        set: { model.texts[item] = $0 }
                    )
                )
                .frame(width: 180, height: 32)
                .accessibilityIdentifier("field-\(item)")
            }
        }
    }
}

private struct AnimatedIdentityHost: View {
    let items: Binding<[String]>
    let recorder: IdentityRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items.wrappedValue, id: \.self) { item in
                AnimatedIdentityRow(label: item, recorder: recorder)
            }
        }
    }
}

private struct AnimatedIdentityRow: View {
    let label: String
    let recorder: IdentityRecorder

    @State private var counter = 0

    var body: some View {
        let _ = recorder.record(label: label, value: counter, counter: $counter)
        Text(label)
            .frame(width: counter == 0 ? 48 : 120, height: 24)
            .animation(Animation.linear(duration: 1), value: counter)
            .accessibilityIdentifier("animated-\(label)")
    }
}
