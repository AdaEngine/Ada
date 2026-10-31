import Foundation
import Testing

@testable import AdaEditor

@Suite("Lore source control", .enabled(if: EditorSourceControlProvider.lore.isAvailable))
struct LoreRepositoryTests {
    @Test("Create, stage, commit, review and switch branches in a real Lore repository")
    func repositoryLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Lore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LoreRepositoryService()
        let created = await service.execute(.initializeRepository, projectURL: root)
        try #require(created.succeeded, "\(created.combinedOutput)")
        #expect(try await service.history(projectURL: root, head: nil, offset: 0).get().commits.isEmpty)
        #expect(EditorSourceControlProvider.load(in: root) == .lore)
        #expect(await service.currentBranchFooter(projectURL: root) == "Lore: main")
        let file = root.appendingPathComponent("hello world.txt")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        let untracked = await service.snapshot(projectURL: root)
        try #require(untracked.succeeded, "\(untracked.statusResult.combinedOutput)")
        #expect(untracked.snapshot.untrackedFiles.contains { $0.path == "hello world.txt" })
        #expect(untracked.snapshot.provider == .lore)
        try #require(await service.execute(.stage(paths: ["hello world.txt"]), projectURL: root).succeeded)
        let staged = await service.snapshot(projectURL: root)
        let firstFile = try #require(staged.snapshot.diffFiles.first { $0.path == "hello world.txt" })
        #expect(firstFile.comparison == .staged)
        #expect(firstFile.statistics.additions == 1)
        let initialPatch = try await service.patch(rootURL: root, file: firstFile).get()
        #expect(initialPatch.hunks.flatMap(\.lines).contains { $0.text == "one" && $0.kind == .addition })
        let firstCommit = await service.execute(.commit(message: "First"), projectURL: root)
        try #require(firstCommit.succeeded, "\(firstCommit.combinedOutput)")
        try "two\n".write(to: file, atomically: true, encoding: .utf8)
        try #require(await service.execute(.stage(paths: ["hello world.txt"]), projectURL: root).succeeded)
        // Lore includes edits made after staging in the next commit.
        try "three\n".write(to: file, atomically: true, encoding: .utf8)
        let pending = await service.snapshot(projectURL: root)
        #expect(pending.snapshot.stagedFiles.filter { $0.path == "hello world.txt" }.count == 1)
        #expect(!pending.snapshot.changedFiles.contains { $0.path == "hello world.txt" })
        try #require(await service.execute(.unstage(paths: ["hello world.txt"]), projectURL: root).succeeded)
        #expect(await service.snapshot(projectURL: root).snapshot.stagedFiles.isEmpty)
        try #require(await service.execute(.stage(paths: ["hello world.txt"]), projectURL: root).succeeded)
        try #require(await service.execute(.commit(message: "Second"), projectURL: root).succeeded)
        let history = try await service.history(projectURL: root, head: nil, offset: 0).get()
        #expect(history.commits.map(\.subject) == ["Second", "First"])
        let latest = try #require(history.commits.first)
        let review = try await service.review(projectURL: root, commit: latest).get()
        let changed = try #require(review.files.first { $0.path == "hello world.txt" })
        let patch = try await service.patch(rootURL: root, file: changed).get()
        #expect(patch.hunks.flatMap(\.lines).contains { $0.text == "three" && $0.kind == .addition })
        let firstReview = try await service.review(projectURL: root, commit: #require(history.commits.last)).get()
        let firstPatch = try await service.patch(rootURL: root, file: #require(firstReview.files.first { $0.path == "hello world.txt" })).get()
        #expect(firstPatch.hunks.flatMap(\.lines).contains { $0.text == "one" && $0.kind == .addition })
        try #require(await service.execute(.createBranch(name: "feature"), projectURL: root).succeeded)
        #expect(await service.snapshot(projectURL: root).snapshot.branchName == "feature")
        try #require(await service.execute(.checkout(branch: "main"), projectURL: root).succeeded)
        #expect(await service.snapshot(projectURL: root).snapshot.branchName == "main")
    }

    @Test("Binary files can be committed and reviewed")
    func binaryFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Lore-binary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LoreRepositoryService()
        try #require(await service.execute(.initializeRepository, projectURL: root).succeeded)
        let fileURL = root.appendingPathComponent("texture.bin")
        try Data([0, 255, 1]).write(to: fileURL)
        try #require(await service.execute(.stage(paths: ["texture.bin"]), projectURL: root).succeeded)
        #expect(await service.snapshot(projectURL: root).snapshot.diffFiles.first { $0.path == "texture.bin" }?.statistics.isBinary == true)
        try #require(await service.execute(.commit(message: "Binary"), projectURL: root).succeeded)
        try Data([0, 254, 2]).write(to: fileURL)
        try #require(await service.execute(.stage(paths: ["texture.bin"]), projectURL: root).succeeded)
        try #require(await service.execute(.commit(message: "Change binary"), projectURL: root).succeeded)
        let commit = try #require(try await service.history(projectURL: root, head: nil, offset: 0).get().commits.first)
        let review = try await service.review(projectURL: root, commit: commit).get()
        let file = try #require(review.files.first { $0.path == "texture.bin" })
        let patch = try await service.patch(rootURL: root, file: file).get()
        #expect(patch.hunks.isEmpty)
        #expect(patch.message == "Binary file changed")
    }

    @Test("Provider preference overrides discovery and survives reopening")
    func providerPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Lore-choice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".lore"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(EditorSourceControlProvider.load(in: root) == .lore)
        try EditorSourceControlProvider.git.save(in: root)
        #expect(EditorSourceControlProvider.load(in: root) == .git)
        try EditorSourceControlProvider.lore.save(in: root)
        #expect(EditorSourceControlProvider.load(in: root) == .lore)
    }
}
