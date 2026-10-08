@testable import AdaApp
@testable import AdaAssets
import AdaECS
import AdaScripting
import Foundation
import Testing

@Suite("AdaScript assets", .serialized)
struct AdaScriptAssetsTests {
    @Test("Loads, exposes, and saves a typed asset reference")
    @MainActor
    func loadAndSave() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdaScriptAssets-\(UUID().uuidString)", isDirectory: true)
        let assets = root.appendingPathComponent("Assets", isDirectory: true)
        let user = root.appendingPathComponent("User", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        AssetsManager.registerAssetType(AdaScriptTextAsset.self)
        await AssetsManager.setProjectDirectories(
            ProjectDirectories(
                source: root,
                assetsDirectory: assets,
                userDataDirectory: user,
                cacheDirectory: root.appendingPathComponent("Cache", isDirectory: true)
            )
        )
        try await AssetsManager.save(
            AdaScriptTextAsset(value: "hello"),
            at: "@res://Fixtures/message.scriptasset"
        )

        let plugin = try AdaScriptPlugin(
            source: """
            @system(id: "asset.system")
            class AssetSystem {
                func update(context) {
                    var message: AdaScriptTextAsset = Assets.preload("@res://Fixtures/message.scriptasset");
                    Assets.save(message, "@user://Copies/message.scriptasset");
                }
            }
            """,
            name: "AssetRuntime"
        )
        let world = World(name: "AdaScript assets")
        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(.update)

        let saved = try await AssetsManager.load(
            AdaScriptTextAsset.self,
            at: "@user://Copies/message.scriptasset"
        )
        #expect(plugin.diagnostics.isEmpty, Comment(rawValue: plugin.diagnostics.joined(separator: "\n")))
        #expect(saved.asset.value == "hello")
    }

}

private final class AdaScriptTextAsset: Asset, @unchecked Sendable {
    var assetMetaInfo: AssetMetaInfo?
    let value: String

    init(value: String) {
        self.value = value
    }

    init(from assetDecoder: any AssetDecoder) throws {
        value = try assetDecoder.decode(String.self)
    }

    func encodeContents(with assetEncoder: any AssetEncoder) throws {
        try assetEncoder.encode(value)
    }

    static func extensions() -> [String] {
        ["scriptasset"]
    }
}
