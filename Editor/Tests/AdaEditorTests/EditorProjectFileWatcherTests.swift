#if os(macOS)
    @testable import AdaEditor
    import Foundation
    import Testing

    @Suite("Project filesystem watching")
    @MainActor
    struct EditorProjectFileWatcherTests {
        @Test("External create, rename and delete update the tree while preserving selection and collapsed folders")
        func observesExternalChanges() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectWatch-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets/Existing"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = EditorViewModel(project: EditorProjectReference(name: "Watch", path: root.path), autosaveDelay: .seconds(60))
            let assets = try #require(model.projectSidebar.items.first { $0.relativePath == "Assets" })
            let existing = try #require(model.projectSidebar.items.first { $0.relativePath == "Assets/Existing" })
            model.projectSidebar.select(assets)
            model.projectSidebar.collapsedFolderIDs.insert(existing.id)
            model.startProjectFileWatching()
            defer {
                model.stopProjectFileWatching()
                model.autosaveTasks.values.forEach { $0.cancel() }
            }
            try await Task.sleep(for: .milliseconds(350))

            let nested = root.appendingPathComponent("Assets/New/Nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try "external".write(to: nested.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
            try await waitUntil("create nested file") { model.projectSidebar.items.contains { $0.relativePath == "Assets/New/Nested/file.txt" } }
            #expect(model.projectSidebar.selectedItem?.id == assets.id)
            #expect(model.projectSidebar.isCollapsed(existing))
            #expect(model.toolbar.searchableItems.contains { $0.relativePath == "Assets/New/Nested/file.txt" })

            try FileManager.default.moveItem(at: root.appendingPathComponent("Assets/New"), to: root.appendingPathComponent("Assets/Renamed"))
            try await waitUntil("rename folder") {
                model.projectSidebar.items.contains { $0.relativePath == "Assets/Renamed/Nested/file.txt" }
                    && !model.projectSidebar.items.contains { $0.relativePath == "Assets/New" }
            }
            try FileManager.default.removeItem(at: root.appendingPathComponent("Assets/Renamed"))
            try await waitUntil("delete folder") { !model.projectSidebar.items.contains { $0.relativePath.hasPrefix("Assets/Renamed") } }

            model.stopProjectFileWatching()
            try "stopped".write(to: root.appendingPathComponent("after-stop.txt"), atomically: true, encoding: .utf8)
            try await Task.sleep(for: .milliseconds(700))
            #expect(!model.projectSidebar.items.contains { $0.relativePath == "after-stop.txt" })
            model.startProjectFileWatching()
            #expect(model.projectSidebar.items.contains { $0.relativePath == "after-stop.txt" })
        }

        @Test("External edits reload clean documents without overwriting unsaved edits")
        func reloadsCleanDocuments() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectWatchText-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("note.txt")
            try "original".write(to: file, atomically: true, encoding: .utf8)
            let model = EditorViewModel(project: EditorProjectReference(name: "Watch", path: root.path), autosaveDelay: .seconds(60))
            let item = try #require(model.projectSidebar.items.first { $0.relativePath == "note.txt" })
            model.openProjectItem(item)
            let document = try #require(textDocument(in: model))
            model.startProjectFileWatching()
            defer {
                model.stopProjectFileWatching()
                model.autosaveTasks.values.forEach { $0.cancel() }
            }
            try await Task.sleep(for: .milliseconds(350))
            try "external".write(to: file, atomically: true, encoding: .utf8)
            try await waitUntil { textDocument(in: model)?.content == "external" }
            model.workbench.updateTextDocument(id: document.id) {
                $0.content = "unsaved"
                $0.isDirty = true
            }
            try "another external edit".write(to: file, atomically: true, encoding: .utf8)
            try "marker".write(to: root.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
            try await waitUntil { model.projectSidebar.items.contains { $0.relativePath == "marker.txt" } }
            #expect(textDocument(in: model)?.content == "unsaved")
        }

        private func textDocument(in model: EditorViewModel) -> EditorTextDocument? {
            guard case let .text(document)? = model.workbench.activeDocument else {
                return nil
            }
            return document
        }

        private func waitUntil(_ operation: String = "update", _ predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(8)
            while !predicate(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            try #require(predicate(), "Expected a real filesystem event: \(operation)")
        }
    }
#endif
