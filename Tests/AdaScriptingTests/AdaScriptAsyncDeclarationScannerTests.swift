import AdaScriptCompilerCore
import Testing

@Suite("AdaScript async declaration metadata")
struct AdaScriptAsyncDeclarationScannerTests {
    @Test("Records global functions and methods for callback contracts")
    func scansDeclarations() throws {
        let declarations = try AdaScriptAsyncDeclarationScanner.declarations(in: """
        async func fetch(item) { return await Assets.loadAsync(item); }
        class Shop { async func refresh() {} }
        """, path: "Shop.ada")
        #expect(declarations.map(\.name) == ["fetch", "refresh"])
        #expect(declarations.map(\.ownerType) == [nil, "Shop"])
    }

    @Test("Rejects a marked receiver and typed marked parameter")
    func rejectsNonSendableDeclarations() {
        #expect(throws: AdaScriptAsyncSyntaxError.self) {
            try AdaScriptAsyncDeclarationScanner.declarations(in: """
            @nonsendable class Borrowed {}
            async func inspect(value: Borrowed) {}
            """, path: "Invalid.ada")
        }
        #expect(throws: AdaScriptAsyncSyntaxError.self) {
            try AdaScriptAsyncDeclarationScanner.declarations(
                in: "@nonsendable class Borrowed { async func inspect() {} }",
                path: "Invalid.ada"
            )
        }
    }
}
