import AdaEngine
import Foundation
import Observation

/// A shared, revisioned IK draft. UI, agent and developer Tool edits use this same history.
@Observable
@MainActor
final class EditorAnimationModifierDocument {
    let url: URL
    let relativePath: String
    private(set) var stack: AnimationModifierStack
    private(set) var revision = UUID().uuidString
    private(set) var isDirty: Bool
    private(set) var isDiscarded = false
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let resourceRoot: URL
    @ObservationIgnored private var savedBytes: Data?
    @ObservationIgnored private var savedStack: AnimationModifierStack?
    @ObservationIgnored private var undoStack: [AnimationModifierStack] = []
    @ObservationIgnored private var redoStack: [AnimationModifierStack] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isReadOnly: Bool { FileManager.default.fileExists(atPath: url.path) && !FileManager.default.isWritableFile(atPath: url.path) }

    init(url: URL, relativePath: String, stack: AnimationModifierStack, savedBytes: Data?, resourceRoot: URL) throws {
        try stack.validate()
        self.url = url
        self.relativePath = relativePath
        self.stack = stack
        self.savedBytes = savedBytes
        self.savedStack = savedBytes == nil ? nil : stack
        self.isDirty = savedBytes == nil
        self.resourceRoot = resourceRoot
    }

    func checkRevision(_ expected: String, editable: Bool = false) throws {
        guard !isDiscarded, expected == revision else { throw conflict("IK draft changed; inspect its latest revision and retry.") }
        try checkLocation()
        guard !editable || !isReadOnly else { throw conflict("IK resource is read-only.") }
    }

    func commit(_ candidate: AnimationModifierStack, expectedRevision: String) throws {
        try checkRevision(expectedRevision, editable: true)
        try candidate.validate()
        guard candidate.id == stack.id, candidate.binding == stack.binding else { throw conflict("Remap the IK rig explicitly instead of replacing its binding.") }
        guard candidate != stack else { return }
        undoStack.append(stack)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll(keepingCapacity: true)
        adopt(candidate)
    }

    func undo(expectedRevision: String) throws {
        try checkRevision(expectedRevision, editable: true)
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(stack)
        adopt(previous)
    }

    func redo(expectedRevision: String) throws {
        try checkRevision(expectedRevision, editable: true)
        guard let next = redoStack.popLast() else { return }
        undoStack.append(stack)
        adopt(next)
    }

    func save(expectedRevision: String) throws {
        try checkRevision(expectedRevision, editable: true)
        if let savedBytes { guard try matchesDisk(savedBytes) else { throw conflict("IK file changed on disk; reload before saving.") } }
        else if FileManager.default.fileExists(atPath: url.path) { throw conflict("IK destination already exists.") }
        let data = try stack.encodedData()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try checkLocation()
        try data.write(to: url, options: .atomic)
        savedBytes = data
        savedStack = stack
        isDirty = false
        onChange?()
    }

    func requireSavedSnapshot() throws {
        try checkLocation()
        guard !isDirty, let savedBytes, try matchesDisk(savedBytes) else { throw conflict("Save the current IK resource before binding it to a scene.") }
    }

    func reload(_ data: Data, expectedRevision: String, discardChanges: Bool) throws {
        try checkRevision(expectedRevision)
        guard !isDirty || discardChanges else { throw conflict("Reload would discard local IK edits; request discardChanges explicitly.") }
        let candidate = try AnimationModifierStack.decode(data)
        guard isDirty || data != savedBytes else { return }
        savedStack = candidate
        savedBytes = data
        undoStack.removeAll(); redoStack.removeAll()
        adopt(candidate)
    }

    func discard() { isDiscarded = true; onChange = nil }

    private func adopt(_ candidate: AnimationModifierStack) {
        stack = candidate
        revision = UUID().uuidString
        isDirty = stack != savedStack
        onChange?()
    }

    private func checkLocation() throws {
        guard resourceRoot.resolvingSymlinksInPath().standardizedFileURL == resourceRoot,
              EditorAnimationAuthoringService.canonicalDestination(url) == url, url.path.hasPrefix(resourceRoot.path + "/") else {
            throw conflict("IK resource location changed; reopen a project-owned path.")
        }
    }

    private func matchesDisk(_ bytes: Data) throws -> Bool {
        guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == bytes.count else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: bytes.count + 1) == bytes
    }

    private func conflict(_ message: String) -> AnimationAuthoringError { .init(.conflict, itemID: relativePath, message: message) }
}
