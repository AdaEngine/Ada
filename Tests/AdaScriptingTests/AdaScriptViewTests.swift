import AdaScriptCompilerCore
@testable import AdaScripting
@testable import AdaUI
import Testing

/// ADR-0016 keeps every AdaScript UI entry point unavailable until the redesign ships.
@MainActor
@Suite("AdaScript views are unavailable", .serialized)
struct AdaScriptViewTests {
    private let diagnostic = "AdaUI views in AdaScript are temporarily unavailable."

    @Test("Class and struct views are rejected by the scanner", arguments: ["class", "struct"])
    func rejectsViewDeclarations(kind: String) {
        let sources = [AdaScriptSource(path: "View.ada", source: """
        @view @previewable
        \(kind) ExampleView {
            @state var label = "Before";
            @environment(colorScheme) var scheme;
            func body() { Text(label).fontSize(28); }
        }
        """)]
        #expect(throws: AdaScriptSchemaError.invalid(path: "View.ada", message: diagnostic)) {
            try AdaScriptViewScanner.declarations(in: sources)
        }
    }

    @Test("The builder lowerer reports the disabled feature at its source location")
    func rejectsViewLowering() {
        #expect(throws: AdaScriptViewBuilderError(path: "View.ada", line: 2, message: diagnostic)) {
            try AdaScriptViewBuilderLowerer.lower(
                source: "// View source\n@view class ExampleView { func body() { Text(\"Hello\"); } }",
                path: "View.ada"
            )
        }
    }

    @Test("Source-backed views and validation reject before compiling script code")
    func rejectsSourceBackedViews() {
        let sources = [AdaScriptSource(path: "View.ada", source: "invalid script that must never be compiled")]
        #expect(throws: AdaScriptError.invalidManifest(diagnostic)) {
            try AdaScriptView(sources: sources, identifier: "ExampleView")
        }
        #expect(throws: AdaScriptError.invalidManifest(diagnostic)) {
            try AdaScriptView.validate(sources: sources, identifier: "ExampleView")
        }
    }

    @Test("Registry entry points remain unavailable even with supplied metadata")
    func rejectsRegistryEntryPoints() {
        let metadata = AdaScriptViewMetadata(className: "ExampleView", identifier: "ExampleView", title: "Example")
        #expect(throws: AdaScriptError.invalidManifest(diagnostic)) {
            try AdaScriptViewRegistry.register(
                views: [metadata],
                sources: [AdaScriptSource(path: "View.ada", source: "invalid script")],
                moduleName: "DisabledViewTest"
            )
        }
        #expect(throws: AdaScriptError.invalidManifest(diagnostic)) {
            try AdaScriptViewRegistry.makeView(identifier: "ExampleView")
        }
        #expect(throws: AdaScriptError.invalidManifest(diagnostic)) {
            try AdaScriptViewRegistry.makeStorage(identifier: "ExampleView")
        }
    }

    @Test("The compatibility view displays the unavailable diagnostic")
    func compatibilityViewDisplaysDiagnostic() throws {
        let text = try #require(AdaScriptView("ExampleView").body as? Text)
        #expect(text.plainText == diagnostic)
    }

    @Test("Script UI components reject before reading a source file")
    func rejectsScriptUIComponent() {
        #expect(throws: UIDiagnostic(diagnostic)) {
            try UIComponent(script: "Missing.ada", identifier: "ExampleView")
        }
    }
}
