@_spi(AdaEngine) import AdaEngine
import Foundation

/// Runs worker edits on a private resource; the caller commits its URI through scene history.
@MainActor
enum EditorTerrainSourceAuthoring {
    enum Phase: Sendable {
        case preparing, applying, saving
        case writing(completed: Int, total: Int)
    }
    enum Failure: LocalizedError, Sendable {
        case unavailable, busy, sourceChanged, timedOut, manifestTooLarge
        case failed(String)

        nonisolated var errorDescription: String? {
            switch self {
            case .unavailable: "Terrain is not ready. Select a terrain and wait for it to load."
            case .busy: "Terrain is busy. Wait for the current change to finish."
            case .sourceChanged: "Terrain changed while the edit was being prepared. Try again."
            case .timedOut: "Terrain update timed out. The last valid surface is still visible."
            case .manifestTooLarge: "The terrain resource is too large to edit."
            case let .failed(message): message
            }
        }
    }

    static func applyHeightStroke(
        to owner: Entity,
        application: AppWorlds,
        expectedStorage: TerrainHeightStorage,
        expectedRevision: UInt64,
        brush: TerrainHeightBrushStroke,
        command: EditorTerrainStrokeCommand? = nil,
        assetsRoot: URL,
        isCurrent: () -> Bool = { true },
        onProgress: @escaping @MainActor @Sendable (Phase) -> Void = { _ in },
        commit: (URL) throws -> Void = { _ in },
        nextCommand: (() -> (command: EditorTerrainStrokeCommand?, finished: Bool))? = nil,
        onPublished: (Terrain3DSourceSurface) -> Void = { _ in }
    ) async throws -> URL? {
        try Task.checkCancellation()
        let (original, loadedSurface) = try await application.withWorldAccess {
            guard owner.world === application.main,
                  let original = owner.components[Terrain3DSource.self],
                  let surface = owner.components[Terrain3DSourceSurface.self],
                  surface.storage === expectedStorage, surface.manifest != nil else { throw Failure.unavailable }
            guard expectedStorage.revision == expectedRevision, isCurrent() else { throw Failure.sourceChanged }
            guard owner.components[Terrain3DHeightEdit.self] == nil, owner.components[Terrain3DSave.self] == nil else { throw Failure.busy }
            return (original, surface)
        }
        guard let manifest = loadedSurface.manifest else { throw Failure.unavailable }
        // A completed save can immediately schedule residency/LOD publication. Retain the
        // captured surface and wait for that coherent generation instead of dropping input.
        let _: Bool = try await wait(application: application, owner: owner, source: original, isCurrent: isCurrent) {
            guard owner.components[Terrain3DSourceSurface.self]?.storage === expectedStorage,
                expectedStorage.revision == expectedRevision else { throw Failure.sourceChanged }
            guard let status = owner.components[Terrain3DSourceStatus.self] else {
                return nil
            }
            if let error = status.error { throw Failure.failed(error) }
            return status.isReady && !status.isPreparing ? true : nil
        }
        let url = try EditorTerrainResource.resolve(
            original.source,
            sourceURL: assetsRoot.appendingPathComponent("_editor.ascn"),
            resourceRootURL: assetsRoot
        )
        let fork = try await EditorTerrainAssetFork.make(from: url, expected: manifest)
        let operation = command ?? .height(brush)
        var prepared = original
        prepared.source = fork.path
        var editID: UUID?
        var saveRequest: Terrain3DSave?
        do {
            onProgress(.preparing)
            if operation.changesResource {
                try await EditorTerrainResourceWriter.apply(operation, to: fork, manifest: manifest)
            }
            try await application.withWorldAccess {
                try check(owner: owner, source: original, isCurrent: isCurrent)
                guard expectedStorage.revision == expectedRevision else { throw Failure.sourceChanged }
                owner.components.remove(Terrain3DSourceStatus.self)
                owner.components[Terrain3DSource.self] = prepared
            }
            var surface: Terrain3DSourceSurface = try await wait(application: application, owner: owner, source: prepared, isCurrent: isCurrent) {
                guard let status = owner.components[Terrain3DSourceStatus.self] else {
                    return nil
                }
                if let error = status.error { throw Failure.failed(error) }
                return status.isReady && !status.isPreparing ? owner.components[Terrain3DSourceSurface.self] : nil
            }
            if operation.changesResource {
                try await EditorTerrainAssetFork.verify(url, expected: manifest)
                try await application.withWorldAccess {
                    try check(owner: owner, source: prepared, isCurrent: isCurrent)
                    try commit(fork)
                }
                return fork
            }
            var changed = false
            var once = false
            while true {
                try Task.checkCancellation()
                let input = nextCommand?() ?? (command: once ? nil : operation, finished: true)
                guard let batch = input.command else {
                    if input.finished { break }
                    try await Task.sleep(for: .milliseconds(16))
                    continue
                }
                once = true
                onProgress(.applying)
                    let edit = try await application.withWorldAccess {
                        try check(owner: owner, source: prepared, isCurrent: isCurrent)
                        let edit: Terrain3DHeightEdit
                        switch batch {
                        case let .height(stroke): edit = .init(storage: surface.storage, brush: stroke)
                        case let .surface(stroke): edit = .init(storage: surface.storage, brush: stroke)
                        case let .instances(stroke): edit = .init(storage: surface.storage, brush: stroke)
                        default: throw Failure.unavailable
                        }
                        owner.components[Terrain3DHeightEdit.self] = edit
                        return edit
                    }
                    editID = edit.id
                    let delta: TerrainHeightDelta = try await wait(application: application, owner: owner, source: prepared, isCurrent: isCurrent) {
                        guard let status = owner.components[Terrain3DHeightEditStatus.self], status.id == edit.id else {
                            return nil
                        }
                        switch status.phase {
                        case .pending: return nil
                        case .applied:
                            guard let delta = status.delta else { throw Failure.unavailable }
                            return delta
                        case .cancelled: throw CancellationError()
                        case .failed: throw Failure.failed(status.error ?? "Terrain edit failed")
                        }
                    }
                    try await application.withWorldAccess { owner.components.remove(Terrain3DHeightEdit.self) }
                    editID = nil
                changed = changed || !delta.changes.isEmpty || !delta.instanceChanges.isEmpty || !delta.surfaceChanges.isEmpty || !delta.maskChanges.isEmpty
                surface = try await application.withWorldAccess {
                    guard let value = owner.components[Terrain3DSourceSurface.self] else { throw Failure.unavailable }
                    return value
                }
                onPublished(surface)
                if nextCommand == nil { break }
            }
            guard changed else {
                await cleanup(owner: owner, application: application, original: original, prepared: prepared, fork: fork, editID: nil, save: nil)
                return nil
            }
            onProgress(.saving)
            let save = Terrain3DSave(storage: surface.storage, onProgress: { completed, total in
                await onProgress(.writing(completed: completed, total: total))
            })
            saveRequest = save
            try await application.withWorldAccess {
                try check(owner: owner, source: prepared, isCurrent: isCurrent)
                owner.components[Terrain3DSave.self] = save
            }
            let _: Bool = try await wait(application: application, owner: owner, source: prepared, isCurrent: isCurrent) {
                guard let status = owner.components[Terrain3DSaveStatus.self], status.id == save.id else {
                    return nil
                }
                switch status.phase {
                case .pending: return nil
                case .saved: return true
                case .cancelled: throw CancellationError()
                case .failed: throw Failure.failed(status.error ?? "Terrain save failed")
                }
            }
            try await EditorTerrainAssetFork.verify(url, expected: manifest)
            try await application.withWorldAccess {
                try check(owner: owner, source: prepared, isCurrent: isCurrent)
                if owner.components[Terrain3DSave.self]?.id == save.id { owner.components.remove(Terrain3DSave.self) }
                try commit(fork)
            }
            return fork
        } catch {
            await cleanup(owner: owner, application: application, original: original, prepared: prepared, fork: fork, editID: editID, save: saveRequest)
            throw error
        }
    }

    private static func cleanup(
        owner: Entity,
        application: AppWorlds,
        original: Terrain3DSource,
        prepared: Terrain3DSource,
        fork: URL,
        editID: UUID?,
        save: Terrain3DSave?
    ) async {
        // Cancellation cannot skip the safe point. This scoped task owns only the unpublished
        // fork; it waits for actual filesystem completion before deleting that destination.
        await Task { @MainActor in
            let canDelete = try? await application.withWorldAccess {
                guard application.main.getEntityByID(owner.id) === owner else {
                    return true
                }
                if let editID, owner.components[Terrain3DHeightEdit.self]?.id == editID { owner.components.remove(Terrain3DHeightEdit.self) }
                if let save, owner.components[Terrain3DSave.self]?.id == save.id { owner.components.remove(Terrain3DSave.self) }
                if owner.components[Terrain3DSource.self] == prepared {
                    owner.components[Terrain3DSource.self] = original
                    owner.components.remove(Terrain3DSourceStatus.self)
                }
                return owner.components[Terrain3DSource.self]?.source != fork.path
            }
            guard canDelete == true else {
                return
            }
            if let save, save.hasStartedWriting {
                while save.completion == nil { try? await Task.sleep(for: .milliseconds(10)) }
            }
            try? FileManager.default.removeItem(at: fork)
        }.value
    }

    private static func check(owner: Entity, source: Terrain3DSource, isCurrent: () -> Bool) throws {
        try Task.checkCancellation()
        guard owner.world?.getEntityByID(owner.id) === owner, isCurrent(), owner.components[Terrain3DSource.self] == source else { throw Failure.sourceChanged }
    }

    private static func wait<Value: Sendable>(
        application: AppWorlds,
        owner: Entity,
        source: Terrain3DSource,
        isCurrent: () -> Bool,
        read: () throws -> Value?
    ) async throws -> Value {
        let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(30))
        while true {
            if let value = try await application.withWorldAccess({
                try check(owner: owner, source: source, isCurrent: isCurrent)
                return try read()
            }) {
                return value
            }
            guard clock.now < deadline else { throw Failure.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum EditorTerrainAssetFork {
    @concurrent
    static func make(from source: URL, expected: TerrainManifestAsset) async throws -> URL {
        let data = try checkedData(from: source, expected: expected)
        let destination = source.deletingLastPathComponent().appendingPathComponent("edit-\(UUID().uuidString.lowercased()).aterrain")
        try data.write(to: destination, options: .withoutOverwriting)
        return destination
    }

    @concurrent
    static func verify(_ source: URL, expected: TerrainManifestAsset) async throws {
        _ = try checkedData(from: source, expected: expected)
    }

    private static func checkedData(from source: URL, expected: TerrainManifestAsset) throws -> Data {
        try Task.checkCancellation()
        let maximum = TerrainManifestAsset.maximumEncodedBytes ?? 4 * 1_024 * 1_024
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var data = Data()
        while let bytes = try handle.read(upToCount: min(65_536, maximum - data.count + 1)), !bytes.isEmpty {
            guard bytes.count <= maximum - data.count else { throw EditorTerrainSourceAuthoring.Failure.manifestTooLarge }
            data.append(bytes)
            try Task.checkCancellation()
        }
        let canonical = try TerrainManifestAsset(data: data).encodedData()
        let baseline = try expected.encodedData()
        guard canonical == baseline else { throw EditorTerrainSourceAuthoring.Failure.sourceChanged }
        return baseline
    }
}
