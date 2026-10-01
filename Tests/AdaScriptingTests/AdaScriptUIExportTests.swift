import AdaScriptCompilerCore
@testable import AdaScripting
@testable import AdaUI
import Testing

@MainActor @Suite(.serialized)
struct AdaScriptUIExportTests {
    @Test("Script exports with scalar bindings remain unavailable")
    func rejectsScalarBindingExport() {
        let sources = [AdaScriptSource(path: "Export.ada", source: """
        @view
        class ExportView {
            var title = "Initial";
            func body() {
                Button(title) { title = "Updated"; }.accessibilityIdentifier("export.button");
            }
        }
        """)]
        let export = AdaScriptUIExport(source: "Export.ada", identifier: "ExportView", signature: .init(id: "Game.Export", name: "Export", parameters: [.init("title", type: .string, isBinding: true)]))
        #expect(throws: AdaScriptSchemaError.invalid(
            path: "Export.ada",
            message: "AdaUI views in AdaScript are temporarily unavailable."
        )) {
            try UICatalog.standard.adding(script: export, sources: sources)
        }
    }

    @Test("Script exports with object bindings remain unavailable")
    func rejectsObjectBindingExport() {
        let sources = [AdaScriptSource(path: "Object.ada", source: """
        @view
        class ObjectView {
            var item = ["name": "Initial", "count": 0];
            func body() {
                Button(item["name"]) { item["count"] = item["count"] + 1; }.accessibilityIdentifier("object.button");
            }
        }
        """)]
        let export = AdaScriptUIExport(source: "Object.ada", identifier: "ObjectView", signature: .init(id: "Game.Object", name: "Object", parameters: [.init("item", type: .object, isBinding: true)]))
        #expect(throws: AdaScriptSchemaError.invalid(
            path: "Object.ada",
            message: "AdaUI views in AdaScript are temporarily unavailable."
        )) {
            try UICatalog.standard.adding(script: export, sources: sources)
        }
    }

    @Test("Disabled script views do not invoke host catalog factories")
    func rejectsNativeViewWithoutCallingHostFactory() throws {
        var values: [String] = []
        let catalog = try UICatalog.standard.adding(views: [.init(signature: .init(id: "Game.Label", name: "Label", parameters: [.init("text", type: .string)])) { inputs in
            values.append(inputs.string("text")); return AnyView(Text(inputs.string("text")))
        }])
        let sources = [AdaScriptSource(path: "Native.ada", source: """
        @view
        class NativeViewExample {
            func body() { NativeView("Game.Label", text: "Hello").padding(4).background("#ffffff").padding(8); }
        }
        """)]
        #expect(throws: AdaScriptError.invalidManifest("AdaUI views in AdaScript are temporarily unavailable.")) {
            try AdaScriptView(sources: sources, identifier: "NativeViewExample", catalog: catalog)
        }
        #expect(values.isEmpty)
    }
}
