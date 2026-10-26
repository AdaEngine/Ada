@_spi(Internal) import AdaApp
@_spi(AdaEngine) @testable import AdaAssets
import Foundation
import Testing

@Suite("Persistent application directory identity")
struct ProjectDirectoriesIdentityTests {
    @Test("Explicit identity survives source moves and export resource bundle names")
    func stableRoots() throws {
        let original = URL(fileURLWithPath: "/tmp/OriginalGame")
        let moved = URL(fileURLWithPath: "/tmp/AnotherName/GameResources.bundle")
        let first = try ProjectDirectories(source: original, assetsDirectory: original.appendingPathComponent("Assets"), storageIdentifier: "org.example.game")
        let second = try ProjectDirectories(source: moved, assetsDirectory: moved.appendingPathComponent("GameAssets"), storageIdentifier: "org.example.game")
        let other = try ProjectDirectories(source: original, assetsDirectory: first.assetsDirectory, storageIdentifier: "org.example.other")
        #expect(first.userDataDirectory == second.userDataDirectory)
        #expect(first.cacheDirectory == second.cacheDirectory)
        #expect(first.userDataDirectory != other.userDataDirectory)
        #expect(first.cacheDirectory != other.cacheDirectory)
        #expect(first.userDataDirectory.lastPathComponent == "org.example.game")
        #expect(first.assetsDirectory != second.assetsDirectory)
        let legacy = ProjectDirectories(source: original, assetsDirectory: first.assetsDirectory)
        #expect(legacy.userDataDirectory.lastPathComponent == "OriginalGame")
    }

    @Test("Scoped virtual roots use the explicit application identity")
    func virtualRoots() throws {
        let source = URL(fileURLWithPath: "/tmp/VirtualRootGame")
        let directories = try ProjectDirectories(source: source, assetsDirectory: source.appendingPathComponent("Assets"), storageIdentifier: "org.example.virtual")
        let scope = UUID()
        AssetsManager.initialize(directories: directories, scopeID: scope)
        AppWorldsExecutionContext.$currentID.withValue(scope) {
            #expect(AssetsManager.resolveAssetURL(at: "@user://Saves/slot.txt") == directories.userDataDirectory.appendingPathComponent("Saves/slot.txt"))
            #expect(AssetsManager.resolveAssetURL(at: "@cache://temp.txt") == directories.cacheDirectory.appendingPathComponent("temp.txt"))
        }
    }

    @Test("Invalid explicit identities cannot become filesystem paths")
    func invalidIdentifiers() {
        for identifier in ["", ".", "..", "../other", "a/b", "a\\b", "a b", String(repeating: "x", count: 201)] {
            #expect(throws: ProjectDirectoriesError.self) { try ProjectDirectories.validateStorageIdentifier(identifier) }
        }
    }
}
