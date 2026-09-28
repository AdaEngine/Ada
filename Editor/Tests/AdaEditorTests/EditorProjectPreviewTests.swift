@testable import AdaEditor
import AdaEngine
import Foundation
import Testing

#if canImport(CoreGraphics) && canImport(ImageIO)
struct EditorProjectPreviewTests {
    @Test
    func thumbnailPersistsAndReloadsWithBoundedSizeAndCorrectColors() async throws {
        let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: projectURL) }
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let store = EditorProjectPreviewStore(projectURL: projectURL)
        #expect(store.load() == nil)
        let image = Image(width: 1_280, height: 640, color: .red, format: .bgra8)
        try await store.save(image)

        let reloaded = try #require(EditorProjectPreviewStore(projectURL: projectURL).load())
        #expect(reloaded.width == 640)
        #expect(reloaded.height == 320)
        #expect(reloaded.getPixel(x: 320, y: 160).red > 0.95)
        #expect(reloaded.getPixel(x: 320, y: 160).blue < 0.05)

        try await store.save(Image(width: 32, height: 16, color: .blue))
        let updated = try #require(store.load())
        #expect(updated.getPixel(x: 16, y: 8).blue > 0.95)
    }

    @Test
    func invalidCapturePreservesPreviewAndDeletedProjectIsNotRecreated() async throws {
        let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: projectURL) }
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let store = EditorProjectPreviewStore(projectURL: projectURL)
        let image = Image(width: 8, height: 8, color: .red)
        try await store.save(image)
        let saved = try Data(contentsOf: store.imageURL)
        await #expect(throws: EditorProjectPreviewStore.Failure.invalidImage) { try await store.save(Image()) }
        #expect(try Data(contentsOf: store.imageURL) == saved)
        try FileManager.default.removeItem(at: projectURL)
        await #expect(throws: EditorProjectPreviewStore.Failure.projectUnavailable) { try await store.save(image) }
        #expect(!FileManager.default.fileExists(atPath: projectURL.path))
    }
}
#endif
