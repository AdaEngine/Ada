import AdaScriptCompilerCore
import Testing

@Suite("AdaScript asset lowering")
struct AdaScriptAssetsLowererTests {
    @Test("Passes the declared asset type to the runtime bridge")
    func typedLoad() {
        let source = """
        var sprite: Texture2D = Assets.load("@res://Textures/player.png");
        var scene: Scene = Assets.preload("@res://Scenes/Main.ascn");
        """

        let lowered = AdaScriptAssetsLowerer.lower(source: source)

        #expect(lowered.contains(#"__adaAssets.perform(["loadTyped", "Texture2D", "@res://Textures/player.png"])"#))
        #expect(lowered.contains(#"__adaAssets.perform(["loadTyped", "Scene", "@res://Scenes/Main.ascn"])"#))
        #expect(!lowered.contains(": Texture2D"))
    }

    @Test("Leaves dynamically inferred calls unchanged")
    func dynamicLoad() {
        let source = #"var sprite = Assets.load("@res://Textures/player.png");"#
        #expect(AdaScriptAssetsLowerer.lower(source: source) == #"var sprite = __adaAssets.perform(["load", "@res://Textures/player.png"]);"#)
    }
}
