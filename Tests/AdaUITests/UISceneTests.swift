import AdaECS
@testable import AdaPlatform
import AdaRender
@testable import AdaUI
import AdaUtils
import Foundation
import Math
import Testing

@MainActor
struct UISceneTests {
    init() async throws { try Application.prepareForTest() }

    @Test func gridUsesNativeLayoutAndOrderedModifiers() throws {
        let root = UINodeDescription(type: "Grid", arguments: ["columns": .init(value: .number(2)), "horizontalSpacing": .init(value: .number(10))], children: [
            tile("a"), tile("b"), tile("c")
        ])
        let session = try UISceneInstance(document: .init(root: root))
        let container = UIContainerView(rootView: UISceneView(session: session))
        container.frame = Rect(x: 0, y: 0, width: 300, height: 300)
        container.layoutSubviews()
        let nodes = flatten(container.uiTreeRoots())
        let a = try #require(nodes.first { $0.sceneNodeID == "a" })
        let b = try #require(nodes.first { $0.sceneNodeID == "b" })
        let c = try #require(nodes.first { $0.sceneNodeID == "c" })
        #expect(a.absoluteFrame.minY == b.absoluteFrame.minY)
        #expect(b.absoluteFrame.minX > a.absoluteFrame.minX)
        #expect(c.absoluteFrame.minY > a.absoluteFrame.minY)
    }

    @Test func invalidUpdateKeepsLastWorkingDocument() throws {
        let document = UISceneDocument(root: tile("a"))
        let session = try UISceneInstance(document: document)
        #expect(!session.update(.init(root: .init(type: "Missing.View"))))
        #expect(session.document == document)
        #expect(session.diagnostic?.contains("Missing.View") == true)
    }

    @Test func invalidReloadDoesNotRedirectMountedBindings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var captured: [Binding<UIValue>] = []
        let catalog = try UICatalog.standard.adding(views: [.init(signature: .init(id: "Capture", name: "Capture", parameters: [.init("text", type: .string, isBinding: true)])) { inputs in
            if let binding = inputs.bindings["text"] { captured.append(binding) }
            return AnyView(EmptyView())
        }])
        let child = UISceneDocument(root: .init(type: "Capture", arguments: ["text": .init(binding: "text")]), inputs: [.init("text", type: .string)])
        try child.encodedYAML().write(to: root.appendingPathComponent("Child.ui"), atomically: true, encoding: .utf8)
        let context = UIBindingContext(values: ["old": .string("Old"), "new": .string("New")])
        let include = UINodeDescription(id: "child", type: "UI", arguments: ["path": .init(value: .string("Child.ui")), "text": .init(binding: "old")])
        let document = UISceneDocument(root: .init(type: "VStack", children: [include]))
        let session = try UISceneInstance(document: document, context: context, catalog: catalog, resources: UISceneResources(rootURL: root))
        let mounted = try #require(captured.first)
        var invalid = document
        invalid.root.children[0].arguments["text"] = .init(binding: "new")
        invalid.root.children.append(.init(type: "Missing"))
        #expect(!session.update(invalid))
        mounted.wrappedValue = .string("Edited")
        #expect(context.value("old") == .string("Edited"))
        #expect(context.value("new") == .string("New"))
    }

    @Test func nativeFactoryReceivesBindingsActionsAndOrderedModifiers() throws {
        var rendered: [String] = []
        let context = UIBindingContext(values: ["title": .string("Before")])
        var tapped = 0
        context.on("save") { _ in tapped += 1 }
        let custom = UINativeViewDescriptor(signature: .init(id: "Game.Input", name: "Input", parameters: [.init("text", type: .string, isBinding: true)], actions: [.init("save")])) { inputs in
            inputs.bindings["text"]?.wrappedValue = .string("After")
            inputs.perform("save")
            return AnyView(Text(inputs.string("text")))
        }
        let modifier = UINativeModifierDescriptor(signature: .init(id: "Game.Record", name: "Record", parameters: [.init("label", type: .string)])) { view, inputs in
            rendered.append(inputs.string("label")); return view
        }
        let catalog = try UICatalog.standard.adding(views: [custom], modifiers: [modifier])
        let node = UINodeDescription(type: "Game.Input", arguments: ["text": .init(binding: "title")], actions: ["save": "save"], modifiers: [
            .init(type: "Game.Record", arguments: ["label": .init(value: .string("first"))]),
            .init(type: "Game.Record", arguments: ["label": .init(value: .string("second"))])
        ])
        _ = try UISceneInstance(document: .init(root: node), context: context, catalog: catalog)
        #expect(context.value("title") == .string("After"))
        #expect(tapped == 1)
        #expect(rendered == ["first", "second"])
    }

    @Test func forEachRejectsDuplicateIDsAndReadsParentBindings() throws {
        let context = UIBindingContext(values: ["items": .array([.object(["id": .string("a")]), .object(["id": .string("a")])]), "title": .string("Shared")])
        let node = UINodeDescription(type: "ForEach", arguments: ["items": .init(binding: "items")], children: [.init(type: "Text", arguments: ["text": .init(binding: "title")])])
        #expect(throws: UIDiagnostic.self) { try UISceneInstance(document: .init(root: node), context: context) }
        context.set("items", to: .array([.object(["id": .string("a")])]))
        _ = try UISceneInstance(document: .init(root: node), context: context)
    }

    @Test func conditionsSelectTheRequestedBranch() throws {
        var labels: [String] = []
        let catalog = try UICatalog.standard.adding(views: [.init(signature: .init(id: "Record", name: "Record", parameters: [.init("label", type: .string)])) {
            labels.append($0.string("label")); return AnyView(EmptyView())
        }])
        let context = UIBindingContext(values: ["visible": .bool(true)])
        let node = UINodeDescription(type: "If", arguments: ["condition": .init(binding: "visible")], children: [
            .init(type: "Record", arguments: ["label": .init(value: .string("true"))]),
            .init(type: "Record", arguments: ["label": .init(value: .string("false"))])
        ])
        let session = try UISceneInstance(document: .init(root: node), context: context, catalog: catalog)
        context.set("visible", to: .bool(false)); _ = session.render()
        #expect(labels == ["true", "false"])
    }

    @Test func nestedResourcesRejectCyclesAndEscape() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = UISceneDocument(root: .init(type: "UI", arguments: ["path": .init(value: .string("Loop.ui"))]))
        let url = root.appendingPathComponent("Loop.ui")
        try document.encodedYAML().write(to: url, atomically: true, encoding: .utf8)
        let resources = UISceneResources(rootURL: root)
        #expect(throws: UIDiagnostic.self) { try UISceneInstance(document: document, resources: resources, sourceURL: url) }
        #expect(throws: UIDiagnostic.self) { try resources.resolve("../Escape.ui") }
    }

    @Test func componentSourceRoundTripAndSwiftViewCodingFailure() throws {
        let component = UIComponent(source: .init(path: "HUD.ui"))
        let decoded = try JSONDecoder().decode(UIComponent.self, from: JSONEncoder().encode(component))
        #expect(decoded.source == component.source)
        let swift = UIComponent(view: Text("Native"), behaviour: .overlay)
        #expect(throws: EncodingError.self) { try JSONEncoder().encode(swift) }
    }

    @Test func sceneIdentityDoesNotReplaceAccessibilityIdentifier() throws {
        let session = try UISceneInstance(document: .init(root: .init(id: "node", type: "Text", modifiers: [
            .init(type: "accessibilityIdentifier", arguments: ["value": .init(value: .string("Game.Label"))])
        ])))
        let container = UIContainerView(rootView: UISceneView(session: session))
        container.frame = Rect(x: 0, y: 0, width: 100, height: 50)
        container.layoutSubviews()
        #expect(!container.uiFindNodes(matching: .accessibilityIdentifier("Game.Label")).isEmpty)
        #expect(flatten(container.uiTreeRoots()).contains { $0.sceneNodeID == "node" })
    }

    @Test func repeatedViewsRetainIndependentStateWhenReordered() throws {
        var counts: [String: Int] = [:]
        let catalog = try UICatalog.standard.adding(views: [.init(signature: .init(id: "Counter", name: "Counter", parameters: [.init("name", type: .string)])) { inputs in
            let name = inputs.string("name")
            return AnyView(Counter(name: name, record: { counts[name] = $0 }))
        }])
        let itemA = UIValue.object(["id": .string("a"), "name": .string("A")])
        let itemB = UIValue.object(["id": .string("b"), "name": .string("B")])
        let context = UIBindingContext(values: ["items": .array([itemA, itemB])])
        let document = UISceneDocument(root: .init(type: "VStack", children: [
            .init(type: "ForEach", arguments: ["items": .init(binding: "items")], children: [
                .init(type: "Counter", arguments: ["name": .init(binding: "item.name")])
            ])
        ]))
        let session = try UISceneInstance(document: document, context: context, catalog: catalog)
        let container = UIContainerView(rootView: UISceneView(session: session))
        container.frame = Rect(x: 0, y: 0, width: 300, height: 200)
        container.layoutSubviews()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("counter.A"))
        container.layoutSubviews()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("counter.B"))
        context.set("items", to: .array([itemB, itemA]))
        container.viewTree.rootNode.invalidateContent()
        container.layoutSubviews()
        let a = try container.uiNode(matching: .accessibilityIdentifier("counter.A"))
        let b = try container.uiNode(matching: .accessibilityIdentifier("counter.B"))
        #expect(b.absoluteFrame.minY < a.absoluteFrame.minY)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("counter.A"))
        #expect(counts == ["A": 2, "B": 1])
    }

    private struct Counter: View {
        let name: String
        let record: (Int) -> Void
        @State private var count = 0
        var body: some View {
            Button(name) { count += 1; record(count) }
                .frame(width: 80, height: 30)
                .accessibilityIdentifier("counter.\(name)")
        }
    }

    private func tile(_ id: String) -> UINodeDescription {
        .init(id: id, type: "Rectangle", modifiers: [.init(type: "frame", arguments: ["width": .init(value: .number(30)), "height": .init(value: .number(20))])])
    }
    private func flatten(_ roots: [UINodeSnapshot]) -> [UINodeSnapshot] { roots.flatMap { [$0] + flatten($0.children) } }
}
