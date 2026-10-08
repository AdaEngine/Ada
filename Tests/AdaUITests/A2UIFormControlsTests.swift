@testable import AdaA2UI
import AdaInput
@testable import AdaPlatform
@testable import AdaUI
import AdaUIDescription
import Foundation
import Math
import Testing

@MainActor @Suite(.serialized)
struct A2UIFormControlsTests {
    init() async throws { try Application.prepareForTest() }

    @Test func realInputsUpdateChoicesAndSliderAndBlockInvalidSubmission() async throws {
        let client = try makeClient()
        let surface = try #require(client.surfaces["form"])
        var events: [A2UIClientEvent] = []
        client.onEvent = { events.append($0) }
        let tester = ViewTester { A2UISurfaceView(client: client, surfaceID: "form").frame(width: 360, height: 420) }
        _ = try tester.containerView.uiTapNode(matching: .accessibilityIdentifier("a2ui.form.submit"))
        surface.scene.context.perform("event:submit")
        #expect(events.isEmpty)
        #expect(containsText(tester, "Name is required."))
        _ = try tester.containerView.uiFocusNode(matching: .accessibilityIdentifier("a2ui.form.name"))
        tester.sendKeyEvent(.a, modifiers: [.control]).sendTextInput("Ada Guide")
        for _ in 0..<4 { await Task.yield() }
        tester.performLayout()
        _ = try tester.containerView.uiTapNode(matching: .accessibilityIdentifier("a2ui.form.role.option.merchant"))
        for _ in 0..<4 { await Task.yield() }
        tester.performLayout()
        _ = try tester.containerView.uiTapNode(matching: .accessibilityIdentifier("a2ui.form.health"))
        for _ in 0..<4 { await Task.yield() }
        tester.performLayout()
        #expect(try A2UIPointer("/npc/role").read(surface.dataModel) == .string("merchant"))
        #expect(try A2UIPointer("/npc/health").read(surface.dataModel) == .number(51))
        #expect(!containsText(tester, "Name is required."))
        _ = try tester.containerView.uiTapNode(matching: .accessibilityIdentifier("a2ui.form.submit"))
        #expect(events.count == 1)
        let action = try #require(events.first?.envelope.objectFields()["action"]).objectFields()
        #expect(action["context"] == .object(["name": .string("Ada Guide"), "role": .string("merchant"), "health": .number(51)]))
    }

    @Test func outOfRangeValuesAreEditableAndValidationSurvivesSnapshotRestore() async throws {
        let client = try makeClient()
        try client.receive(json: #"{"version":"v0.9.1","updateDataModel":{"surfaceId":"form","value":{"npc":{"name":"Ada","role":"guide","health":200}}}}"#)
        let surface = try #require(client.surfaces["form"])
        let document = try UISceneDocument.decode(surface.snapshot().encodedYAML())
        let context = UIBindingContext()
        var count = 0
        context.on("generate") { _ in count += 1 }
        let scene = try UISceneInstance(document: document, context: context)
        let tester = ViewTester { scene.render().frame(width: 360, height: 420) }
        #expect(containsText(tester, "Health must be 1...100."))
        _ = try tester.containerView.uiTapNode(matching: .accessibilityIdentifier("a2ui.form.submit"))
        #expect(count == 0)
        context.set(try A2UIPointer("/npc/health").bindingName, to: .number(100))
        for _ in 0..<4 { await Task.yield() }
        tester.performLayout()
        #expect(!containsText(tester, "Health must be 1...100."))
        _ = try tester.containerView.uiTapNode(matching: .accessibilityIdentifier("a2ui.form.submit"))
        #expect(count == 1)
        #expect(document.root.children.contains { $0.type == "ChoicePicker" })
        #expect(document.root.children.contains { $0.type == "Slider" })
    }

    @Test func malformedOptionsBoundsAndFunctionsAreRejectedAtomically() throws {
        let client = try makeClient()
        let surface = try #require(client.surfaces["form"])
        let previous = surface.scene.document
        for component in [
            #"{"id":"role","component":"ChoicePicker","value":{"path":"/npc/role"},"options":[{"label":"A","value":"same"},{"label":"B","value":"same"}]}"#,
            #"{"id":"health","component":"Slider","value":{"path":"/npc/health"},"min":100,"max":1}"#,
            #"{"id":"health","component":"Slider","value":{"path":"/npc/health"},"min":1,"max":100,"step":0}"#,
            #"{"id":"name","component":"TextField","text":{"path":"/npc/name"},"checks":[{"condition":{"call":"eval","args":{"value":"code"}},"message":"No"}]}"#
        ] {
            #expect(throws: A2UIValidationError.self) {
                try client.receive(json: "{\"version\":\"v0.9.1\",\"updateComponents\":{\"surfaceId\":\"form\",\"components\":[" + component + "]}}")
            }
            #expect(surface.scene.document == previous)
        }
    }

    private func containsText<Content: View>(_ tester: ViewTester<Content>, _ text: String) -> Bool {
        func visit(_ node: ViewNode) -> Bool {
            if let content = node.content as? Text, content.storage.text.text.contains(text) {
                return true
            }
            if let root = node as? ViewRootNode {
                return visit(root.contentNode)
            }
            if let container = node as? ViewContainerNode {
                return container.nodes.contains(where: visit)
            }
            if let modifier = node as? ViewModifierNode {
                return visit(modifier.contentNode)
            }
            return false
        }
        return visit(tester.containerView.viewTree.rootNode)
    }

    private func makeClient() throws -> A2UIClient {
        let client = A2UIClient()
        try client.receive(json: "{\"version\":\"v0.9.1\",\"createSurface\":{\"surfaceId\":\"form\",\"catalogId\":\"" + A2UIClient.catalogID + "\",\"sendDataModel\":true}}")
        try client.receive(json: #"""
        {
          "version": "v0.9.1",
          "updateComponents": {
            "surfaceId": "form",
            "components": [
              {
                "id": "root",
                "component": "Column",
                "children": [
                  "name",
                  "role",
                  "health",
                  "submit"
                ]
              },
              {
                "id": "name",
                "component": "TextField",
                "text": {
                  "path": "/npc/name"
                },
                "checks": [
                  {
                    "condition": {
                      "call": "required",
                      "args": {
                        "value": {
                          "path": "/npc/name"
                        }
                      }
                    },
                    "message": "Name is required."
                  }
                ]
              },
              {
                "id": "role",
                "component": "ChoicePicker",
                "label": "Role",
                "value": {
                  "path": "/npc/role"
                },
                "options": [
                  {
                    "label": "Guide",
                    "value": "guide"
                  },
                  {
                    "label": "Merchant",
                    "value": "merchant"
                  }
                ]
              },
              {
                "id": "health",
                "component": "Slider",
                "value": {
                  "path": "/npc/health"
                },
                "min": 1,
                "max": 100,
                "step": 1
              },
              {
                "id": "submit",
                "component": "Button",
                "text": "Generate",
                "action": {
                  "event": {
                    "name": "generate",
                    "context": {
                      "name": {
                        "path": "/npc/name"
                      },
                      "role": {
                        "path": "/npc/role"
                      },
                      "health": {
                        "path": "/npc/health"
                      }
                    }
                  }
                },
                "checks": [
                  {
                    "condition": {
                      "call": "required",
                      "args": {
                        "value": {
                          "path": "/npc/name"
                        }
                      }
                    },
                    "message": "Name is required."
                  },
                  {
                    "condition": {
                      "call": "range",
                      "args": {
                        "value": {
                          "path": "/npc/health"
                        },
                        "min": 1,
                        "max": 100
                      }
                    },
                    "message": "Health must be 1...100."
                  }
                ]
              }
            ]
          }
        }
        """#)
        try client.receive(json: #"{"version":"v0.9.1","updateDataModel":{"surfaceId":"form","value":{"npc":{"name":"","role":"guide","health":10}}}}"#)
        return client
    }
}
