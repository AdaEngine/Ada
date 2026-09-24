@testable import AdaRender
@testable import AdaScripting
@testable import AdaUI
import Math
import Testing

@MainActor
@Suite("Ada Script views", .serialized)
struct AdaScriptViewTests {
    init() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
    }

    @Test("Builds a native AdaUI hierarchy from @view")
    func buildsNativeViewHierarchy() throws {
        let view = try AdaScriptView(
            sources: [
                AdaScriptSource(
                    path: "Views/Welcome.ada",
                    source: """
                    @view
                    class WelcomeView {
                        func body() {
                            VStack(spacing: 12) {
                                Text("Hello from Ada Script").fontSize(28);
                                HStack {
                                    Text("Native AdaUI");
                                    Spacer();
                                    Divider();
                                }
                            }
                            .padding(24)
                            .background("#20232aff")
                            .accessibilityIdentifier("welcome-root");
                        }
                    }
                    """
                )
            ],
            identifier: "WelcomeView"
        )
        let container = UIContainerView(rootView: view)
        container.frame.size = Size(width: 480, height: 320)
        container.layoutSubviews()

        let root = try #require(container.uiTreeRoots().first)
        #expect(flatten(root).contains { $0.accessibilityIdentifier == "welcome-root" })
        #expect(flatten(root).filter { $0.viewType.contains("AdaUI.Text") }.count == 2)
    }

    @Test("Integer and decimal font sizes produce the same laid out text")
    func integerFontSizePreservesTextLayout() throws {
        let view = try AdaScriptView(
            sources: [
                AdaScriptSource(
                    path: "Views/Numeric.ada",
                    source: """
                    @view
                    class NumericView {
                        func body() {
                            VStack(spacing: 12) {
                                Text("Hello").fontSize(28);
                                Text("Hello").fontSize(28.0);
                                Text("Plain");
                            }
                            .padding(24);
                        }
                    }
                    """
                )
            ],
            identifier: "NumericView"
        )
        let container = UIContainerView(rootView: view)
        container.frame.size = Size(width: 280, height: 180)
        container.layoutSubviews()

        let root = try #require(container.uiTreeRoots().first)
        let textNodes = flatten(root).filter { $0.viewType.contains("AdaUI.Text") }
        #expect(textNodes.count == 3)
        guard textNodes.count == 3 else {
            return
        }

        let integerNode = textNodes[0]
        let decimalNode = textNodes[1]
        let plainNode = textNodes[2]
        #expect(integerNode.frame.height > 0)
        #expect(integerNode.absoluteFrame.size == decimalNode.absoluteFrame.size)
        #expect(integerNode.absoluteFrame.height > plainNode.absoluteFrame.height)
        #expect(decimalNode.absoluteFrame.minY > integerNode.absoluteFrame.maxY)
        #expect(plainNode.absoluteFrame.minY > decimalNode.absoluteFrame.maxY)

        let nativeText = try #require(findTextNode(in: container.viewTree.rootNode))
        #expect(nativeText.environment.font?.pointSize == 28)
        let context = UIGraphicsContext()
        nativeText.draw(with: context)
        #expect(context.getDrawCommands().contains { command in
            guard case let .drawGlyph(glyph, _, _) = command else { return false }
            return glyph.position.z > glyph.position.x && glyph.position.w > glyph.position.y
        })
    }

    @Test("Numeric modifiers preserve integer and fractional values", arguments: [false, true])
    func numericModifiersPreserveValues(fractional: Bool) throws {
        func literal(_ value: Int) -> String { "\(value)" + (fractional ? ".5" : "") }
        let sources = [AdaScriptSource(path: "Numeric.ada", source: """
        @view class NumericView {
            func body() {
                VStack(spacing: \(literal(12))) {
                    Text("Hello").fontSize(\(literal(28))).padding(\(literal(24)))
                        .frame(\(literal(120)), \(literal(80))).opacity(\(fractional ? "0.5" : "1"));
                    Spacer(\(literal(16)));
                };
            }
        }
        """)]
        let runtime = try AdaScriptViewModuleRuntime(
            sources: sources,
            views: AdaScriptViewScanner.declarations(in: sources)
        )
        let storage = try runtime.makeStorage(identifier: "NumericView")
        try storage.updateEnvironment([:])
        let model = try #require(storage.model)
        guard case let .vStack(children, spacing) = model.content else {
            Issue.record("Expected a VStack from the script")
            return
        }
        try #require(children.count == 2)
        let fraction: Float = fractional ? 0.5 : 0
        #expect(spacing == 12 + fraction)
        #expect(children[0].style.fontSize == 28 + fraction)
        #expect(children[0].style.padding == 24 + fraction)
        #expect(children[0].style.width == 120 + fraction)
        #expect(children[0].style.height == 80 + fraction)
        #expect(children[0].style.opacity == (fractional ? 0.5 : 1))
        guard case let .spacer(minLength) = children[1].content else {
            Issue.record("Expected a Spacer from the script")
            return
        }
        #expect(minLength == 16 + fraction)
    }

    @Test("Requires body() to return a view value")
    func rejectsInvalidBody() {
        #expect(throws: AdaScriptError.self) {
            try AdaScriptView(
                sources: [
                    AdaScriptSource(
                        path: "Invalid.ada",
                        source: "@view class InvalidView { func body() { return 42; } }"
                    )
                ],
                identifier: "InvalidView"
            )
        }
    }

    @Test("State survives actions and invalidates the native view")
    func stateSurvivesButtonAction() throws {
        let view = try AdaScriptView(
            sources: [
                AdaScriptSource(
                    path: "Counter.ada",
                    source: """
                    @view
                    class CounterView {
                        @state var label = "Before";

                        func body() {
                            VStack {
                                Text(label);
                                Button("Change") {
                                    label = "After";
                                }.accessibilityIdentifier("change-label");
                            };
                        }
                    }
                    """
                )
            ],
            identifier: "CounterView"
        )
        let container = UIContainerView(rootView: view)
        container.frame.size = Size(width: 320, height: 200)
        container.layoutSubviews()

        #expect(textValues(in: container.viewTree.rootNode).contains("Before"))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("change-label"))
        container.layoutSubviews()
        #expect(textValues(in: container.viewTree.rootNode).contains("After"))
    }

    @Test("Struct view state survives actions and invalidates the native view")
    func structViewStateSurvivesButtonAction() throws {
        let view = try AdaScriptView(
            sources: [
                AdaScriptSource(path: "Counter.ada", source: """
                    @view
                    struct CounterView {
                        @state var label = "Before";
                        func body() {
                            VStack {
                                Text(label);
                                Button("Change") { label = "After"; }
                                    .accessibilityIdentifier("change-label");
                            };
                        }
                    }
                    """)
            ],
            identifier: "CounterView"
        )
        let container = UIContainerView(rootView: view)
        container.frame.size = Size(width: 320, height: 200)
        container.layoutSubviews()

        #expect(textValues(in: container.viewTree.rootNode).contains("Before"))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("change-label"))
        container.layoutSubviews()
        #expect(textValues(in: container.viewTree.rootNode).contains("After"))
    }

    @Test("Environment values are rebound before body evaluation")
    func environmentValuesAreBound() throws {
        let view = try AdaScriptView(
            sources: [
                AdaScriptSource(
                    path: "Themed.ada",
                    source: """
                    @view
                    class ThemedView {
                        @environment(colorScheme) var scheme;
                        func body() { Text(scheme); }
                    }
                    """
                )
            ],
            identifier: "ThemedView"
        )
        let container = UIContainerView(rootView: view.preferredColorScheme(.dark))
        container.frame.size = Size(width: 320, height: 200)
        container.layoutSubviews()

        #expect(textValues(in: container.viewTree.rootNode).contains("dark"))
    }

    private func flatten(_ root: UINodeSnapshot) -> [UINodeSnapshot] {
        [root] + root.children.flatMap(flatten)
    }

    private func textValues(in node: ViewNode) -> [String] {
        var values: [String] = []
        if let text = node.content as? Text {
            values.append(text.plainText)
        }
        values += node.transientEnvironmentChildren.flatMap(textValues)
        return values
    }

    private func findTextNode(in node: ViewNode) -> TextViewNode? {
        if let textNode = node as? TextViewNode { return textNode }
        return node.transientEnvironmentChildren.lazy.compactMap { findTextNode(in: $0) }.first
    }
}
