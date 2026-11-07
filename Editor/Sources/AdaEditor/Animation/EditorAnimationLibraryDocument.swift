import AdaEngine
import Foundation
import Observation

/// Shared resource state for Animator, agent requests and developer Tool jobs.
/// Edits change a draft; Save is explicit and checks the original bytes on disk.
@Observable
@MainActor
final class EditorAnimationLibraryDocument {
    let url: URL
    let relativePath: String
    private(set) var library: AnimationLibrary
    private(set) var revision = UUID().uuidString
    private(set) var isDirty: Bool
    private(set) var error: String?
    private(set) var isDiscarded = false
    var selectedClipID: String?
    var previewTime: Double = 0
    var previewSerial: UInt64 = 0
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var savedBytes: Data?
    @ObservationIgnored private var savedLibrary: AnimationLibrary?
    @ObservationIgnored private let resourceRoot: URL?
    @ObservationIgnored private var undoStack: [AnimationLibrary] = []
    @ObservationIgnored private var redoStack: [AnimationLibrary] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isReadOnly: Bool { FileManager.default.fileExists(atPath: url.path) && !FileManager.default.isWritableFile(atPath: url.path) }

    init(url: URL, relativePath: String, library: AnimationLibrary, savedBytes: Data?, resourceRoot: URL? = nil) throws {
        try library.validate()
        self.url = url
        self.relativePath = relativePath
        self.library = library
        self.resourceRoot = resourceRoot
        self.savedBytes = savedBytes
        self.savedLibrary = savedBytes == nil ? nil : library
        self.isDirty = savedBytes == nil
    }

    func checkRevision(_ expected: String) throws {
        guard !isDiscarded else { throw diskConflict() }
        try checkLocation()
        guard expected == revision else {
            throw AnimationAuthoringError(.conflict, itemID: relativePath, message: "Animation resource changed; inspect its latest revision and retry.")
        }
    }

    func checkEditableRevision(_ expected: String) throws {
        try checkRevision(expected)
        guard !isReadOnly else {
            throw AnimationAuthoringError(.conflict, itemID: relativePath, message: "Animation resource is read-only.")
        }
    }

    func apply(_ operations: [AnimationEdit], expectedRevision: String) throws {
        try checkEditableRevision(expectedRevision)
        var draft = library
        try draft.apply(operations)
        try commit(draft, expectedRevision: expectedRevision)
    }

    func commit(_ draft: AnimationLibrary, expectedRevision: String) throws {
        try checkEditableRevision(expectedRevision)
        try draft.validate()
        guard draft != library else { return }
        undoStack.append(library)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        adopt(draft)
    }

    func undo(expectedRevision: String) throws {
        try checkEditableRevision(expectedRevision)
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(library)
        adopt(previous)
    }

    func redo(expectedRevision: String) throws {
        try checkEditableRevision(expectedRevision)
        guard let next = redoStack.popLast() else { return }
        undoStack.append(library)
        adopt(next)
    }

    func save(expectedRevision: String) throws {
        try checkEditableRevision(expectedRevision)
        if let savedBytes {
            guard try matchesDisk(savedBytes) else { throw diskConflict() }
        } else if FileManager.default.fileExists(atPath: url.path) { throw diskConflict() }
        let data = try library.encodedData()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try checkLocation()
        try data.write(to: url, options: .atomic)
        savedBytes = data
        savedLibrary = library
        isDirty = false
        error = nil
        onChange?()
    }

    func requireSavedSnapshot() throws {
        try checkLocation()
        guard !isDirty, let savedBytes, try matchesDisk(savedBytes) else { throw diskConflict() }
    }

    private func checkLocation() throws {
        guard let resourceRoot else { return }
        guard resourceRoot.resolvingSymlinksInPath().standardizedFileURL.path == resourceRoot.path,
            EditorAnimationAuthoringService.canonicalDestination(url).path == url.path, url.path.hasPrefix(resourceRoot.path + "/") else {
            throw AnimationAuthoringError(.conflict, itemID: relativePath, message: "Animation resource location changed; discard the draft and reopen a project-owned path.")
        }
    }

    private func matchesDisk(_ saved: Data) throws -> Bool {
        guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == saved.count else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: saved.count + 1) == saved
    }

    func reload(_ data: Data, expectedRevision: String, discardChanges: Bool) throws {
        try checkRevision(expectedRevision)
        guard !isDirty || discardChanges else {
            throw AnimationAuthoringError(.conflict, itemID: relativePath, message: "Reload would discard local edits. Request discardChanges explicitly.")
        }
        let fresh = try AnimationLibrary.decode(data)
        guard isDirty || data != savedBytes else { return }
        savedBytes = data; savedLibrary = fresh
        undoStack = []; redoStack = []
        if !fresh.clips.contains(where: { $0.id == selectedClipID }) { selectedClipID = fresh.clips.first?.id }
        adopt(fresh)
    }

    func discard() { isDiscarded = true; onChange = nil }

    @discardableResult
    func save() -> Bool {
        do { try save(expectedRevision: revision); return true }
        catch { self.error = error.localizedDescription; onChange?(); return false }
    }

    private func adopt(_ value: AnimationLibrary) {
        library = value
        revision = UUID().uuidString
        isDirty = value != savedLibrary
        error = nil
        onChange?()
    }

    private func diskConflict() -> AnimationAuthoringError {
        .init(.conflict, itemID: relativePath, message: "Animation file changed on disk. Reload before saving over external changes.")
    }
}
