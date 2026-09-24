import AdaScriptCompilerCore
import Testing

@Suite("AdaScript async syntax")
struct AdaScriptAsyncLowererTests {
    @Test("Preserves locals and continuation calls")
    func lowersAsyncFunctionAndAwait() throws {
        let source = try AdaScriptAsyncLowerer.lower(source: """
        async func answer(value) {
            var confirmed = await wait_confirmation(value);
            return confirmed;
        }
        """, path: "Answer.ada")
        #expect(source.contains("Fiber.create"))
        #expect(source.contains("__adaAwait(wait_confirmation(value))"))
        #expect(source.contains("__ada_async_impl_answer"))
    }

    @Test("Rejects await outside an async function")
    func rejectsSynchronousAwait() {
        #expect(throws: AdaScriptAsyncSyntaxError.self) {
            try AdaScriptAsyncLowerer.lower(source: "func update() { await Tasks.nextFrame(); }", path: "Invalid.ada")
        }
    }

    @Test("Ordinary method and parameter names carry no suspension policy")
    func allowsOrdinaryNames() throws {
        let lowered = try AdaScriptAsyncLowerer.lower(
            source: "class S { async func update(context) { await Tasks.nextFrame(); } }",
            path: "Ordinary.ada"
        )
        #expect(lowered.contains("__ada_async_impl_update"))
    }

    @Test("Rejects async parameters and receivers with @nonsendable types")
    func rejectsNonSendableTypes() {
        #expect(throws: AdaScriptAsyncSyntaxError.self) {
            try AdaScriptAsyncLowerer.lower(source: """
            @nonsendable class Borrowed {}
            async func hold(value: Borrowed) { await Tasks.nextFrame(); }
            """, path: "Invalid.ada")
        }
        #expect(throws: AdaScriptAsyncSyntaxError.self) {
            try AdaScriptAsyncLowerer.lower(source: "@nonsendable class Borrowed { async func work() {} }", path: "Invalid.ada")
        }
    }

    @Test("Rejects unawaited calls")
    func rejectsUnawaitedCalls() {
        #expect(throws: AdaScriptAsyncSyntaxError.self) {
            try AdaScriptAsyncLowerer.lower(source: """
            async func work() { return 1; }
            func start() { work(); }
            """, path: "Invalid.ada")
        }
    }

    @Test("A typed asset load keeps its type when awaited")
    func lowersTypedAsyncAssetLoad() throws {
        let assets = AdaScriptAssetsLowerer.lower(source: "var item: ShopItem = await Assets.loadAsync(\"@res://shop.item\");")
        let lowered = try AdaScriptAsyncLowerer.lower(
            source: "async func load() { \(assets) }",
            path: "Shop.ada"
        )
        #expect(lowered.contains("loadTypedAsync"))
        #expect(lowered.contains("__adaAwait(__adaTaskFromOperation"))
    }

    @Test("Rejects an unawaited async call imported from another source")
    func rejectsCrossSourceUnawaitedCall() throws {
        let names = try AdaScriptAsyncLowerer.globalFunctionNames(source: "async func loadShop() {}", path: "Shop.ada")
        #expect(names == ["loadShop"])
        #expect(throws: AdaScriptAsyncSyntaxError.self) {
            try AdaScriptAsyncLowerer.lower(source: "func begin() { loadShop(); }", path: "Main.ada", globalAsyncNames: names)
        }
    }
}
