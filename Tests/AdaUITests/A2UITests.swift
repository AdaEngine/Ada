@testable import AdaA2UI
import AdaInput
@testable import AdaPlatform
@testable import AdaUI
import AdaUIDescription
import Foundation
import Math
import Testing

@MainActor
struct A2UITests {
    init() async throws { try Application.prepareForTest() }

    @Test func outOfOrderDefinitionsRenderProgressively() throws {
        let client = try makeClient()
        try components(client, #"[{"id":"name","component":"Text","text":{"path":"/npc/name"}}]"#)
        #expect(client.surfaces["form"]?.scene.document.root.type == "EmptyView")
        try components(client, #"[{"id":"root","component":"Column","children":["name","later"]}]"#)
        let surface = try #require(client.surfaces["form"])
        #expect(surface.scene.document.root.children.map(\.type) == ["Text", "EmptyView"])
        try components(client, #"[{"id":"later","component":"Text","text":"Arrived"}]"#)
        #expect(surface.scene.document.root.children.map(\.type) == ["Text", "Text"])
        #expect(surface.scene.document.root.children.map(\.id) == ["name", "later"])
    }

    @Test func invalidMessageKeepsTheLastWorkingSurfaceAndEmitsAnError() throws {
        let client = try formClient()
        let surface = try #require(client.surfaces["form"])
        let previous = surface.scene.document
        var events: [A2UIClientEvent] = []
        client.onEvent = { events.append($0) }
        #expect(throws: A2UIValidationError.self) {
            try components(client, #"[{"id":"title","component":"Unknown"}]"#)
        }
        #expect(surface.scene.document == previous)
        #expect(client.lastError?.surfaceID == "form")
        #expect(client.lastError?.path == "/components/0/component")
        #expect(events.count == 1)
        let envelope = try JSONDecoder().decode([String: [String: String]].self, from: JSONEncoder().encode(events[0].envelope))
        #expect(envelope["error"]?["code"] == "VALIDATION_FAILED")
        try components(client, #"[{"id":"title","component":"Text","text":"Recovered"}]"#)
        #expect(client.lastError == nil)
        #expect(surface.scene.document.root.children[0].arguments["text"]?.value == .string("Recovered"))
    }

    @Test func rejectsCyclesDuplicatesAndUnknownPropertiesAtomically() throws {
        let client = try formClient()
        let previous = try #require(client.surfaces["form"]).scene.document
        for values in [
            #"[{"id":"root","component":"Column","children":["root"]}]"#,
            #"[{"id":"title","component":"Text","text":"A"},{"id":"title","component":"Text","text":"B"}]"#,
            #"[{"id":"title","component":"Text","text":"A","execute":"something"}]"#,
            #"[{"id":"root","component":"Column","children":["title","title"]}]"#,
            #"[{"id":"unreachable","component":"Column","children":["unreachable"]}]"#,
            #"[{"id":"title","component":"Text","text":{"call":"eval","args":{}}}]"#
        ] {
            #expect(throws: A2UIValidationError.self) { try components(client, values) }
            #expect(client.surfaces["form"]?.scene.document == previous)
        }
    }

    @Test func inputFocusSelectionAndLocalEditsSurviveAComponentUpdate() async throws {
        let client = try formClient()
        let tester = ViewTester { A2UISurfaceView(client: client, surfaceID: "form").frame(width: 360, height: 260) }
        _ = try tester.containerView.uiFocusNode(matching: .accessibilityIdentifier("a2ui.form.name"))
        tester.sendKeyEvent(.a, modifiers: [.control]).sendTextInput("Local edit")
        let surface = try #require(client.surfaces["form"])
        #expect(try A2UIPointer("/npc/name").read(surface.dataModel) == .string("Local edit"))
        let focused = tester.containerView.focusManager.focusedNode
        tester.sendKeyEvent(.a, modifiers: [.control])
        try components(client, #"[{"id":"title","component":"Text","text":"New title"}]"#)
        for _ in 0..<3 { await Task.yield() }
        tester.performLayout()
        #expect(tester.containerView.focusManager.focusedNode === focused)
        tester.sendTextInput("Replacement")
        #expect(try A2UIPointer("/npc/name").read(surface.dataModel) == .string("Replacement"))
        #expect(tester.findNodeByAccessibilityIdentifier("a2ui.form.name") != nil)
    }

    @Test func typingUpdatesAnotherBoundLabelWithoutSendingAnAction() async throws {
        let client = try formClient()
        var events: [A2UIClientEvent] = []
        client.onEvent = { events.append($0) }
        let tester = ViewTester { A2UISurfaceView(client: client, surfaceID: "form").frame(width: 360, height: 260) }
        _ = try tester.containerView.uiFocusNode(matching: .accessibilityIdentifier("a2ui.form.name"))
        tester.sendKeyEvent(.a, modifiers: [.control]).sendTextInput("Ada")
        for _ in 0..<3 { await Task.yield() }
        tester.performLayout()
        let node = try #require(tester.findNodeByAccessibilityIdentifier("a2ui.form.echo"))
        #expect((node.content as? Text)?.storage.text.text == "Ada")
        #expect(events.isEmpty)
    }

    @Test func buttonAndToggleUseRealUIEventsAndCurrentModelValues() async throws {
        let client = try formClient(sendDataModel: true)
        var events: [A2UIClientEvent] = []
        client.onEvent = { events.append($0) }
        let tester = ViewTester { A2UISurfaceView(client: client, surfaceID: "form").frame(width: 360, height: 260) }
        _ = try tester.containerView.uiFocusNode(matching: .accessibilityIdentifier("a2ui.form.name"))
        tester.sendKeyEvent(.a, modifiers: [.control]).sendTextInput("Edited")
        for _ in 0..<3 { await Task.yield() }
        tester.performLayout()
        _ = try tester.containerView.uiTapNode(matching: .accessibilityIdentifier("a2ui.form.enabled"))
        for _ in 0..<3 { await Task.yield() }
        tester.performLayout()
        #expect(try A2UIPointer("/npc/enabled").read(try #require(client.surfaces["form"]).dataModel) == .bool(true))
        _ = try tester.containerView.uiTapNode(matching: .accessibilityIdentifier("a2ui.form.submit"))
        #expect(events.count == 1)
        let event = try #require(events.first)
        let envelope = try event.envelope.objectFields()
        let action = try #require(envelope["action"]).objectFields()
        #expect(action["name"] == .string("save"))
        #expect(action["surfaceId"] == .string("form"))
        #expect(action["sourceComponentId"] == .string("submit"))
        #expect(action["timestamp"]?.string != nil)
        #expect(action["context"] == .object(["name": .string("Edited"), "enabled": .bool(true)]))
        #expect(event.metadata == .object(["a2uiClientDataModel": .object(["surfaces": .object(["form": try #require(client.surfaces["form"]).dataModel])])]))
    }

    @Test func serverDataUpdatesDoNotReplaceUnrelatedLocalValues() throws {
        let client = try formClient()
        let surface = try #require(client.surfaces["form"])
        try data(client, #""path":"/npc/name","value":"Local""#)
        try data(client, #""path":"/npc/enabled","value":true"#)
        #expect(try A2UIPointer("/npc/name").read(surface.dataModel) == .string("Local"))
        let previous = surface.dataModel
        #expect(throws: A2UIValidationError.self) { try data(client, #""path":"/npc/name","value":42"#) }
        #expect(surface.dataModel == previous)
        try data(client, #""path":"/npc/name""#)
        #expect(try A2UIPointer("/npc/name").read(surface.dataModel) == nil)
        #expect(surface.scene.context.value(try A2UIPointer("/npc/name").bindingName) == .string(""))
    }

    @Test func snapshotsRoundTripIntoTheOrdinarySceneRuntime() throws {
        let client = try formClient()
        let snapshot = try #require(client.surfaces["form"]).snapshot()
        let decoded = try UISceneDocument.decode(snapshot.encodedYAML())
        let context = UIBindingContext()
        context.on("save") { _ in }
        let scene = try UISceneInstance(document: decoded, context: context)
        #expect(scene.document == snapshot)
        #expect(snapshot.actions.map(\.name) == ["save"])
        #expect(snapshot.inputs.contains { $0.defaultValue == .string("Guide") })
        #expect(snapshot.root.children.contains { $0.type == "Toggle" })
    }

    @Test func deletionAndRecreationCannotReuseOldBindingsOrActions() throws {
        let client = try formClient()
        let old = try #require(client.surfaces["form"])
        let binding = old.scene.context.binding(try A2UIPointer("/npc/name").bindingName)
        var events: [A2UIClientEvent] = []
        client.onEvent = { events.append($0) }
        try client.receive(json: #"{"version":"v0.9.1","deleteSurface":{"surfaceId":"form"}}"#)
        #expect(client.surfaces.isEmpty)
        try create(client)
        let recreated = try #require(client.surfaces["form"])
        #expect(old.generation != recreated.generation)
        binding.wrappedValue = .string("Stale")
        old.scene.context.perform("event:submit")
        #expect(events.isEmpty)
        #expect(recreated.dataModel == .object([:]))
    }

    @Test func enforcesCatalogVersionAndSessionLimits() throws {
        let client = A2UIClient(maximumComponents: 1, maximumSurfaces: 1)
        try create(client)
        #expect(throws: A2UIValidationError.self) { try create(client) }
        #expect(throws: A2UIValidationError.self) {
            try client.receive(json: #"{"version":"v0.9.1","createSurface":{"surfaceId":"other","catalogId":"https://adaengine.org/a2ui/catalogs/forms/v1"}}"#)
        }
        #expect(throws: A2UIValidationError.self) {
            try components(client, #"[{"id":"a","component":"Text","text":"A"},{"id":"b","component":"Text","text":"B"}]"#)
        }
        #expect(throws: A2UIValidationError.self) { try client.receive(json: #"{"version":"v0.8","deleteSurface":{"surfaceId":"form"}}"#) }
        #expect(throws: A2UIValidationError.self) {
            try A2UIClient().receive(json: #"{"version":"v0.9.1","createSurface":{"surfaceId":"form","catalogId":"basic"}}"#)
        }
        #expect(throws: A2UIValidationError.self) {
            try client.receive(json: #"{"version":"v0.9.1","deleteSurface":{"surfaceId":"form"},"updateDataModel":{"surfaceId":"form"}}"#)
        }
        #expect(throws: A2UIValidationError.self) { try A2UIClient().receive(json: #"{"version":"v0.9.1","updateDataModel":{"surfaceId":"missing","value":{}}}"#) }
    }

    @Test func surfaceModelsAndActionMetadataStayIsolated() throws {
        let client = try formClient(sendDataModel: true)
        try client.receive(json: """
        {"version":"v0.9.1","createSurface":{"surfaceId":"private","catalogId":"\(A2UIClient.catalogID)"}}
        """)
        try client.receive(json: #"{"version":"v0.9.1","updateDataModel":{"surfaceId":"private","value":{"secret":"other session data"}}}"#)
        var events: [A2UIClientEvent] = []
        client.onEvent = { events.append($0) }
        try #require(client.surfaces["form"]).scene.context.perform("event:submit")
        let metadata = try #require(events.first).metadata.objectFields()
        let modelMetadata = try #require(metadata["a2uiClientDataModel"]).objectFields()
        let models = try #require(modelMetadata["surfaces"]).objectFields()
        #expect(Set(models.keys) == ["form"])
        #expect(client.surfaces["private"]?.dataModel == .object(["secret": .string("other session data")]))
    }

    @Test func componentIDsWithSlashesCannotCollideWithNestedIdentityPaths() throws {
        let client = try makeClient()
        try components(client, #"[{"id":"root","component":"Column","children":["a/b","a"]},{"id":"a/b","component":"Button","text":"Direct","action":{"event":{"name":"direct"}}},{"id":"a","component":"Column","children":["b"]},{"id":"b","component":"Button","text":"Nested","action":{"event":{"name":"nested"}}}]"#)
        let snapshot = try #require(client.surfaces["form"]).snapshot()
        #expect(snapshot.root.children[0].id == "a%2Fb")
        #expect(snapshot.root.children[1].children[0].id == "b")
        #expect(Set(snapshot.actions.map(\.name)) == ["direct", "nested"])
        #expect(snapshot.root.children[0].actions["action"] == "direct")
    }

    @Test func oversizedEnvelopesAreRejectedBeforeSurfaceCreation() throws {
        let client = A2UIClient(maximumMessageBytes: 16)
        #expect(throws: A2UIValidationError.self) { try create(client) }
        #expect(client.surfaces.isEmpty)
        #expect(client.lastError?.message.contains("byte limit") == true)
    }

    private func makeClient() throws -> A2UIClient {
        let client = A2UIClient()
        try create(client)
        return client
    }

    private func create(_ client: A2UIClient, sendDataModel: Bool = false) throws {
        try client.receive(json: """
        {"version":"v0.9.1","createSurface":{"surfaceId":"form","catalogId":"\(A2UIClient.catalogID)","sendDataModel":\(sendDataModel)}}
        """)
    }

    private func formClient(sendDataModel: Bool = false) throws -> A2UIClient {
        let client = A2UIClient()
        try create(client, sendDataModel: sendDataModel)
        try components(client, #"[{"id":"root","component":"Column","spacing":12,"children":["title","name","echo","enabled","submit"]},{"id":"title","component":"Text","text":"Form"},{"id":"name","component":"TextField","text":{"path":"/npc/name"}},{"id":"echo","component":"Text","text":{"path":"/npc/name"}},{"id":"enabled","component":"Toggle","label":"Enabled","value":{"path":"/npc/enabled"}},{"id":"submit","component":"Button","text":"Save","action":{"event":{"name":"save","context":{"name":{"path":"/npc/name"},"enabled":{"path":"/npc/enabled"}}}}}]"#)
        try data(client, #""value":{"npc":{"name":"Guide","enabled":false}}"#)
        return client
    }

    private func components(_ client: A2UIClient, _ values: String) throws {
        try client.receive(json: """
        {"version":"v0.9.1","updateComponents":{"surfaceId":"form","components":\(values)}}
        """)
    }

    private func data(_ client: A2UIClient, _ fields: String) throws {
        try client.receive(json: """
        {"version":"v0.9.1","updateDataModel":{"surfaceId":"form",\(fields)}}
        """)
    }
}
