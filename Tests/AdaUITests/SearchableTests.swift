//
//  SearchableTests.swift
//  AdaEngine
//

import Testing
@testable import AdaUI
@testable import AdaPlatform
import AdaUtils
import Math

@MainActor
struct SearchableTests {

    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func searchBar_rendersStandaloneTextFieldAndUsesBinding() {
        final class Model {
            var query = "Ada"
        }

        let model = Model()
        let tester = ViewTester {
            SearchBar(
                text: Binding(
                    get: { model.query },
                    set: { model.query = $0 }
                ),
                prompt: "Search projects",
                width: 280
            )
        }
        .setSize(Size(width: 320, height: 80))
        .performLayout()

        let hitNode = tester.click(at: Point(160, 40))
        let textFieldNode = hitNode as? TextFieldViewNode

        #expect(textFieldNode != nil)
        #expect(textFieldNode?.text == "Ada")
        #expect(textFieldNode?.environment._textFieldDrawsBackground == false)
    }

    @Test
    func searchBar_plainStyleRendersTextFieldAndClearActionClearsQuery() {
        final class Model {
            var query = "Ada"
        }

        let model = Model()
        let tester = ViewTester {
            SearchBar(
                text: Binding(
                    get: { model.query },
                    set: { model.query = $0 }
                ),
                prompt: "Search projects",
                width: 280
            )
            .searchBarStyle(PlainSearchBarStyle())
        }
        .setSize(Size(width: 320, height: 80))
        .performLayout()

        let hitNode = tester.click(at: Point(160, 40))
        let textFieldNode = hitNode as? TextFieldViewNode

        #expect(textFieldNode != nil)
        #expect(textFieldNode?.text == "Ada")
        #expect(textFieldNode?.environment._textFieldDrawsBackground == false)

        guard let clearPoint = tester.findHitPoint(
            forAccessibilityIdentifier: "AdaUI.SearchBar.clearButton",
            in: Rect(x: 0, y: 0, width: 320, height: 80),
            step: 2
        ) else {
            Issue.record("Expected clear button to be hittable")
            return
        }

        tester.sendMouseEvent(at: clearPoint, phase: .began)
        tester.sendMouseEvent(at: clearPoint, phase: .ended)

        #expect(model.query == "")
    }

    @Test
    func searchBarStyleConfigurationCanBeUsedByCustomStyles() {
        struct TestSearchBarStyle: SearchBarStyle {
            func makeBody(configuration: Configuration) -> some View {
                HStack(spacing: 0) {
                    configuration.label
                    Button(action: configuration.clear) {
                        Text(configuration.isEmpty ? "empty" : "clear")
                    }
                    .accessibilityIdentifier("TestSearchBarStyle.clearButton")
                    .frame(width: 80, height: 40)
                }
            }
        }

        final class Model {
            var query = "Ada"
        }

        let model = Model()
        let tester = ViewTester {
            SearchBar(
                text: Binding(
                    get: { model.query },
                    set: { model.query = $0 }
                ),
                prompt: "Search projects",
                width: 280
            )
            .searchBarStyle(TestSearchBarStyle())
        }
        .setSize(Size(width: 320, height: 80))
        .performLayout()

        #expect(tester.click(at: Point(80, 40)) is TextFieldViewNode)
        #expect(model.query == "Ada")
    }

    @Test
    func searchable_modifierAPIAcceptsSupportedPlacements() {
        final class Model {
            var query = ""
        }

        let model = Model()
        let binding = Binding(
            get: { model.query },
            set: { model.query = $0 }
        )

        _ = Text("Content")
            .searchable(text: binding, prompt: "Find")
        _ = Text("Content")
            .searchable(text: binding, placement: .bottom, prompt: "Find")
        _ = Color.clear
            .frame(width: 320, height: 120)
            .searchable(text: binding, placement: .overlay(alignment: .topLeading), prompt: "Find")

        #expect(SearchBarDefaults.height == 32)
        #expect(SearchBarDefaults.modifierWidth == 280)
        #expect(SearchFieldPlacement.bottom == .bottom)
    }
}
