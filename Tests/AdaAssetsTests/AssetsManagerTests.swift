@testable @_spi(AdaEngine) import AdaAssets
import AdaUtils
import Foundation
import Math
import Testing

// TODO: We should fix tests

@Suite("AssetsManager Tests", .serialized, .tags(.assets))
struct AssetsManagerTests: Sendable {

    @AssetActor
    init() throws {
        // Set up test environment
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("AssetsManagerTests")

        try? FileManager.default.removeItem(at: testDirectory)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        
        // Initialize AssetsManager with test directory
        try AssetsManager.setAssetDirectory(testDirectory)
        AssetsManager.registerAssetType(TestAsset.self)
    }

    @Test("Resource URLs resolve under the active asset directory")
    @AssetActor
    func resourceURLsResolveUnderAssetDirectory() throws {
        let assetDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Assets")
        try AssetsManager.setAssetDirectory(assetDirectory)

        let resolved = AssetsManager.resolveAssetURL(at: "@res://Textures/player.png")

        #expect(resolved == assetDirectory.appendingPathComponent("Textures/player.png"))
    }

    @Test("Writable asset URLs resolve under their configured directories")
    @AssetActor
    func writableURLsResolveUnderConfiguredDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let assets = root.appendingPathComponent("Assets", isDirectory: true)
        let user = root.appendingPathComponent("User", isDirectory: true)
        let cache = root.appendingPathComponent("Cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        AssetsManager.setProjectDirectories(
            ProjectDirectories(
                source: root,
                assetsDirectory: assets,
                userDataDirectory: user,
                cacheDirectory: cache
            )
        )

        #expect(AssetsManager.resolveAssetURL(at: "@user://Saves/slot.txt") == user.appendingPathComponent("Saves/slot.txt"))
        #expect(AssetsManager.resolveAssetURL(at: "@cache://Images/thumb.png") == cache.appendingPathComponent("Images/thumb.png"))
    }

    @Test("Save accepts a complete writable resource path")
    @AssetActor
    func saveAtCompleteWritablePath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let user = root.appendingPathComponent("User", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        AssetsManager.setProjectDirectories(
            ProjectDirectories(
                source: root,
                assetsDirectory: root.appendingPathComponent("Assets", isDirectory: true),
                userDataDirectory: user,
                cacheDirectory: root.appendingPathComponent("Cache", isDirectory: true)
            )
        )

        try await AssetsManager.save(TestAsset(testData: "saved"), at: "@user://Saves/slot.txt")
        let loaded = try await AssetsManager.load(TestAsset.self, at: "@user://Saves/slot.txt")

        #expect(loaded.asset.testData == "saved")
    }

    @Test("Virtual asset paths cannot escape their roots")
    @AssetActor
    func rejectsEscapingVirtualPaths() async {
        await #expect(throws: AssetError.self) {
            try await AssetsManager.save(TestAsset(testData: "unsafe"), at: "@user://../outside.txt")
        }
    }

    @Test("Type-erased synchronous loading preserves the typed handle")
    func typeErasedSynchronousLoad() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await AssetsManager.setAssetDirectory(root)
        AssetsManager.registerAssetType(TestAsset.self)
        try await AssetsManager.save(TestAsset(testData: "erased"), at: "@res://value.txt")

        let handle = try AssetsManager.loadErasedSync(TestAsset.self, at: "@res://value.txt")

        #expect((handle.untypedAsset as? TestAsset)?.testData == "erased")
    }

    @Test("Explicit bundled asset root controls resource URL mapping")
    @AssetActor
    func bundledAssetRootControlsResourceURLMapping() throws {
        let assetsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("WebBundle")
            .appendingPathComponent("Assets")

        try AssetsManager.initialize(filePath: #filePath, assetBundleResourceURL: assetsURL)

        let resolved = AssetsManager.resolveAssetURL(at: "@res://sprites/hero.png")

        #expect(resolved == assetsURL.appendingPathComponent("sprites/hero.png"))
    }

    @Test("Asset scopes isolate resource roots and caches")
    func assetScopesIsolateResourceRootsAndCaches() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssetsManagerScopes-\(UUID().uuidString)", isDirectory: true)
        let editorAssetsURL = rootURL.appendingPathComponent("EditorAssets", isDirectory: true)
        let runtimeAssetsURL = rootURL.appendingPathComponent("RuntimeAssets", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let editorScopeID = UUID()
        let runtimeScopeID = UUID()
        try AssetsManager.initialize(filePath: #filePath, assetBundleResourceURL: editorAssetsURL, scopeID: editorScopeID)
        try AssetsManager.initialize(filePath: #filePath, assetBundleResourceURL: runtimeAssetsURL, scopeID: runtimeScopeID)

        try await AssetsManager.withScope(editorScopeID) {
            try await AssetsManager.save(TestAsset(testData: "editor"), at: "@res://", name: "icon.txt")
        }
        try await AssetsManager.withScope(runtimeScopeID) {
            try await AssetsManager.save(TestAsset(testData: "runtime"), at: "@res://", name: "icon.txt")
        }

        let editorHandle = try await AssetsManager.withScope(editorScopeID) {
            #expect(AssetsManager.resolveAssetURL(at: "@res://icon.txt") == editorAssetsURL.appendingPathComponent("icon.txt"))
            return try await AssetsManager.load(TestAsset.self, at: "@res://icon.txt")
        }
        let runtimeHandle = try await AssetsManager.withScope(runtimeScopeID) {
            #expect(AssetsManager.resolveAssetURL(at: "@res://icon.txt") == runtimeAssetsURL.appendingPathComponent("icon.txt"))
            return try await AssetsManager.load(TestAsset.self, at: "@res://icon.txt")
        }
        let editorHandleAgain = try await AssetsManager.withScope(editorScopeID) {
            try await AssetsManager.load(TestAsset.self, at: "@res://icon.txt")
        }

        #expect(editorHandle.asset.testData == "editor")
        #expect(runtimeHandle.asset.testData == "runtime")
        #expect(editorHandle === editorHandleAgain)
        #expect(editorHandle !== runtimeHandle)
    }

    // FIXME: Im tired to fix it right now
    
    // @Test("Loading non-existent asset should throw error")
    // func testLoadNonExistentAsset() async throws {
    //     // Test loading a non-existent asset
    //     await #expect(throws: AssetError.self) {
    //         _ = try await AssetsManager.load(TestAsset.self, at: "@res://non_existent.txt")
    //     }
    // }
    
    // @Test("Loading same asset twice should return cached instance")
    // func testLoadAndCacheAsset() async throws {
    //     // Create a test asset
    //     let testPath = "@res://test_texture.txt"
    //     let testData = TestAsset(testData: "1234") // Sample image data
        
    //     // Save test asset
    //     try await AssetsManager.save(testData, at: "@res://", name: "test_texture.txt")
        
    //     // Verify asset is not in cache initially
    //     let isExists = await AssetsManager.isAssetExistsInCache(TestAsset.self, at: testPath)
    //     #expect(!isExists, "Asset should not be in cache initially")
        
    //     // Load asset first time
    //     let handle1 = try await AssetsManager.load(TestAsset.self, at: testPath)
        
    //     // Verify asset is in cache after first load
    //     let isExistsAfterLoad = await AssetsManager.isAssetExistsInCache(TestAsset.self, at: testPath)
    //     #expect(isExistsAfterLoad, "Asset should be in cache after first load")
        
    //     // Load asset second time (should use cache)
    //     let handle2 = try await AssetsManager.load(TestAsset.self, at: testPath)
        
    //     // Verify both handles point to the same instance
    //     #expect(handle1.asset === handle2.asset, "Cached asset should return the same instance")
    // }
    
    // @Test("Synchronous loading should work")
    // func testLoadSync() async throws {
    //     // Create a test asset
    //     let testPath = "@res://test_texture_sync.txt"
    //     let testData = TestAsset(testData: "12345") // Sample image data
        
    //     // Save test asset
    //     try await AssetsManager.save(testData, at: "@res://", name: "test_texture_sync.txt")
        
    //     // Verify asset is not in cache initially
    //     let isExists = await AssetsManager.isAssetExistsInCache(TestAsset.self, at: testPath)
    //     #expect(!isExists, "Asset should not be in cache initially")
        
    //     // Load asset synchronously
    //     let asset = try AssetsManager.loadSync(TestAsset.self, at: testPath)
        
    //     // Verify asset is in cache after sync load
    //     let isExistsAfterLoadSync = await AssetsManager.isAssetExistsInCache(TestAsset.self, at: testPath)
    //     #expect(isExistsAfterLoadSync, "Asset should be in cache after sync load")
    //     print(asset)
    // }
    
    // @Test("Saving asset should work")
    // func testSaveAsset() async throws {
    //     // Create a test asset
    //     let testPath = "@res://test_save.txt"
    //     let testAsset = TestAsset(testData: "save") // Create with empty image for testing
        
    //     // Save asset
    //     try await AssetsManager.save(testAsset, at: "@res://", name: "test_save.txt")
        
    //     // Verify asset exists
    //     let fileURL = AssetsManager.getFilePath(at: testPath)
    //     #expect(FileManager.default.fileExists(atPath: fileURL.path), "Saved asset should exist")
        
    //     // Verify asset is not in cache initially
    //     let isExists = await AssetsManager.isAssetExistsInCache(TestAsset.self, at: testPath)
    //     #expect(!isExists, "Asset should not be in cache initially")
        
    //     // Load saved asset
    //     let asset = try await AssetsManager.load(TestAsset.self, at: testPath)
        
    //     // Verify asset is in cache after load
    //     let isExistsAfterLoad = await AssetsManager.isAssetExistsInCache(TestAsset.self, at: testPath)
    //     #expect(isExistsAfterLoad, "Asset should be in cache after load")
    //     print(asset)
    // }
    
    // @Test("Hot reloading should work")
    // func testHotReloading() async throws {
    //     // Create a test asset
    //     let testPath = "@res://test_hot_reload.txt"
    //     let testData = TestAsset(testData: "1234")// Sample image data
        
    //     // Save test asset
    //     try await AssetsManager.save(testData, at: "@res://", name: "test_hot_reload.txt")
        
    //     // Verify asset is not in cache initially
    //     let isExists = await AssetsManager.isAssetExistsInCache(TestAsset.self, at: testPath)
    //     #expect(!isExists, "Asset should not be in cache initially")
        
    //     // Load asset with hot reloading enabled
    //     let asset = try await AssetsManager.load(TestAsset.self, at: testPath, handleChanges: true)
        
    //     // Verify initial asset data
    //     #expect(asset.asset.testData == "1234", "Initial asset data should be '1234'")
        
    //     // Verify asset is in cache after load
    //     let isExistsAfterLoad = await AssetsManager.isAssetExistsInCache(TestAsset.self, at: testPath)
    //     #expect(isExistsAfterLoad, "Asset should be in cache after load")
        
    //     // Modify the asset file
    //     let newData = TestAsset(testData: "12345")
    //     try await AssetsManager.save(newData, at: "@res://", name: "test_hot_reload.txt")
        
    //     // Wait for file watcher to detect the change (latency is 0.1 seconds, but we wait longer to be safe)
    //     try await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
        
    //     // Process hot reload changes (normally done by AssetsProcessSystem)
    //     // This needs to be called to actually process the changes detected by FileWatcher
    //     try await AssetsManager.processResources()
        
    //     // Verify asset is still in cache after hot reload
    //     let isExistsAfterHotReloading = await AssetsManager.isAssetExistsInCache(TestAsset.self, at: testPath)
    //     #expect(isExistsAfterHotReloading, "Asset should still be in cache after hot reload")
        
    //     // Verify asset data was updated via hot reload
    //     #expect(asset.asset.testData == "12345", "Asset data should be updated to '12345' after hot reload")
    // }
} 

private extension AssetsManager {
    static func getFilePath(at path: String) -> URL {
        self.getFilePath(
            from: AssetMetaInfo(
                assetId: RID(),
                assetPath: path,
                assetName: "",
                bundlePath: nil
            )
        ).url
    }
}

final class TestAsset: Asset, @unchecked Sendable {
    
    let testData: String
    
    init(testData: String) {
        self.testData = testData
    }
    
    init(from assetDecoder: any AssetDecoder) throws {
        self.testData = try assetDecoder.decode(String.self)
    }
    
    func encodeContents(with assetEncoder: any AssetEncoder) throws {
        try assetEncoder.encode(self.testData)
    }
    
    static func extensions() -> [String] {
        ["txt"]
    }
    
    var assetMetaInfo: AssetMetaInfo?
}

extension Tag {
  @Tag static var assets: Self
}
