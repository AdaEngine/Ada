import Foundation
import Testing

@testable import AdaEditor

private func makeEditorStoreTemporaryDirectory(named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func removeEditorStoreTemporaryDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

@Suite("Editor file drop")
@MainActor
struct EditorFileDropTests {
    @Test("Folder click selects the copy destination; files and folders are copied without replacing existing files")
    func copiesIntoSelectedDirectory() throws {
        let root = try makeEditorStoreTemporaryDirectory(named: "FileDrop")
        defer { removeEditorStoreTemporaryDirectory(root) }
        let store = EditorProjectStore(storageURL: root.appendingPathComponent("projects.json"))
        let project = try store.createProject(named: "Drop Game", at: root)
        let projectURL = URL(fileURLWithPath: project.path)
        let assets = projectURL.appendingPathComponent("Assets")
        let destination = assets.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("note.txt")
        try "new".write(to: source, atomically: true, encoding: .utf8)
        try "existing".write(to: destination.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let sourceFolder = root.appendingPathComponent("Images")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: sourceFolder.appendingPathComponent("image.png"))

        let model = EditorViewModel(project: project)
        let folder = try #require(model.projectSidebar.items.first { $0.relativePath == "Assets/Nested" })
        model.openProjectItem(folder)
        #expect(model.projectSidebar.selectedItem?.id == folder.id)
        #expect(model.importDroppedFiles(from: [source, sourceFolder]))
        #expect(try String(contentsOf: destination.appendingPathComponent("note.txt"), encoding: .utf8) == "existing")
        #expect(try String(contentsOf: destination.appendingPathComponent("note-2.txt"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: source, encoding: .utf8) == "new")
        #expect(try Data(contentsOf: destination.appendingPathComponent("Images/image.png")) == Data([1, 2, 3]))
        #expect(FileManager.default.fileExists(atPath: sourceFolder.path))
        #expect(model.projectSidebar.selectedItem?.id == folder.id)
        #expect(!model.projectSidebar.isCollapsed(folder))
        #expect(model.projectSidebar.visibleItems.contains { $0.relativePath == "Assets/Nested/note-2.txt" })
        #expect(model.toolbar.searchableItems.contains { $0.relativePath == "Assets/Nested/Images/image.png" })
    }

    @Test("Selected file uses its parent; empty selection uses project root; partial failures still refresh files")
    func destinationAndPartialFailure() throws {
        let root = try makeEditorStoreTemporaryDirectory(named: "FileDropSelection")
        defer { removeEditorStoreTemporaryDirectory(root) }
        let project = try EditorProjectStore(storageURL: root.appendingPathComponent("projects.json"))
            .createProject(named: "Drop Game", at: root)
        let sources = URL(fileURLWithPath: project.path).appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "// main".write(to: sources.appendingPathComponent("Main.ada"), atomically: true, encoding: .utf8)
        let model = EditorViewModel(project: project)
        let file = try #require(model.projectSidebar.items.first { $0.relativePath == "Sources/Main.ada" })
        model.projectSidebar.select(file)
        let source = root.appendingPathComponent("helper.ada")
        try "// script".write(to: source, atomically: true, encoding: .utf8)
        #expect(model.importDroppedFiles(from: [root.appendingPathComponent("missing.txt"), source]))
        #expect(model.projectSidebar.items.contains { $0.relativePath == "Sources/helper.ada" })
        for index in model.projectSidebar.items.indices { model.projectSidebar.items[index].isActive = false }
        #expect(model.importDroppedFiles(from: [source]))
        #expect(FileManager.default.fileExists(atPath: project.path + "/helper.ada"))
    }

    @Test("Reject directory recursion and destinations escaping through a symbolic link")
    func rejectsInvalidDestinations() throws {
        let root = try makeEditorStoreTemporaryDirectory(named: "FileDropInvalid")
        defer { removeEditorStoreTemporaryDirectory(root) }
        let project = try EditorProjectStore(storageURL: root.appendingPathComponent("projects.json"))
            .createProject(named: "Drop Game", at: root)
        let outside = root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let escapePath = project.path + "/Escape"
        try FileManager.default.createDirectory(atPath: escapePath, withIntermediateDirectories: true)
        let model = EditorViewModel(project: project)
        let assets = try #require(model.projectSidebar.items.first { $0.relativePath == "Assets" })
        model.projectSidebar.select(assets)
        #expect(!model.importDroppedFiles(from: [URL(fileURLWithPath: project.path)]))
        let escape = try #require(model.projectSidebar.items.first { $0.relativePath == "Escape" })
        model.projectSidebar.select(escape)
        // The selected directory can change externally before a drop arrives.
        try FileManager.default.removeItem(atPath: escapePath)
        try FileManager.default.createSymbolicLink(atPath: escapePath, withDestinationPath: outside.path)
        let source = root.appendingPathComponent("sample.txt")
        try "sample".write(to: source, atomically: true, encoding: .utf8)
        #expect(!model.importDroppedFiles(from: [source]))
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("sample.txt").path))
        #expect(!model.importDroppedFiles(from: []))
    }
}

#if canImport(AppKit) && os(macOS)
    import AppKit

    @Suite("Editor file drop AppKit bridge")
    @MainActor
    struct EditorFileDropBridgeTests {
        @Test("Native drop overlay forwards mouse input to the view beneath it")
        func forwardsMouseInput() throws {
            _ = NSApplication.shared
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let content = try #require(window.contentView)
            let underlying = MouseReceiver(frame: content.bounds)
            content.addSubview(underlying)
            let overlay = EditorProjectFileDropTarget.FileDropView(isEnabled: true, onDrop: { _ in true })
            overlay.frame = content.bounds
            content.addSubview(overlay)
            let event = try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: NSPoint(x: 50, y: 50),
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )
            )
            #expect(content.hitTest(NSPoint(x: 50, y: 50)) === overlay)
            overlay.mouseDown(with: event)
            #expect(underlying.clickCount == 1)
            #expect(content.hitTest(NSPoint(x: 50, y: 50)) === overlay)
        }

        @Test("File pasteboard accepts multiple file URLs and rejects text")
        func readsFileURLs() {
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let urls = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.ada")]
            // swiftlint:disable:next legacy_objc_type
            pasteboard.writeObjects(urls.map { $0 as NSURL })
            #expect(EditorProjectFileDropTarget.FileDropView.fileURLs(from: pasteboard) == urls)
            pasteboard.clearContents()
            pasteboard.setString("https://example.com", forType: .string)
            #expect(EditorProjectFileDropTarget.FileDropView.fileURLs(from: pasteboard).isEmpty)
        }

        private final class MouseReceiver: NSView {
            var clickCount = 0
            override func mouseDown(with _: NSEvent) { clickCount += 1 }
        }
    }
#endif
