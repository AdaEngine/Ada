import AdaAssets
import Foundation
import Synchronization

struct TerrainSourceCaptured: Sendable {
    let current: [TerrainRegionCoordinate: TerrainRegionAsset]
    var overrides: [TerrainRegionCoordinate: TerrainRegionOverride]
}

struct TerrainSourceSaveSnapshot: Sendable {
    let storage: TerrainHeightStorage
    let revision: UInt64
    let payloads: [TerrainRegionCoordinate: TerrainRegionAsset]
    let baselines: [TerrainRegionCoordinate: TerrainRegionAsset]
    let regions: [TerrainRegionAsset]
    let removing: [TerrainRegionReference]
}

extension TerrainSourceResidency {
    func capturedOverrides(_ storage: TerrainHeightStorage) throws -> TerrainSourceCaptured {
        let current = try Self.export(storage)
        var overrides = overrides
        for coordinate in Set(current.keys).union(baseline.keys) {
            let currentPages = current[coordinate]?.pages ?? [], baselinePages = baseline[coordinate]?.pages ?? []
            let currentTiles = current[coordinate]?.tiles ?? [], baselineTiles = baseline[coordinate]?.tiles ?? []
            let currentInstances = current[coordinate]?.instances ?? [], baselineInstances = baseline[coordinate]?.instances ?? []
            let currentSurface = current[coordinate]?.surface ?? [], baselineSurface = baseline[coordinate]?.surface ?? []
            let currentMasks = current[coordinate]?.ruleMasks ?? [], baselineMasks = baseline[coordinate]?.ruleMasks ?? []
            if currentPages != baselinePages || currentTiles != baselineTiles || currentInstances != baselineInstances
                || currentSurface != baselineSurface || currentMasks != baselineMasks {
                overrides[coordinate] = .init(
                    pages: currentPages,
                    tiles: currentTiles != baselineTiles ? currentTiles : overrides[coordinate]?.tiles,
                    instances: currentInstances,
                    surface: currentSurface,
                    ruleMasks: currentMasks
                )
            }
        }
        return .init(current: current, overrides: overrides)
    }

    private func payload(
        at coordinate: TerrainRegionCoordinate,
        captured: TerrainSourceCaptured,
        evictedBaseline: TerrainRegionAsset? = nil
    ) -> TerrainRegionAsset {
        if captured.overrides[coordinate] == nil, captured.current[coordinate] == nil,
            !visible.contains(coordinate), let evictedBaseline {
            return evictedBaseline
        }
        let local = captured.overrides[coordinate]
        let tiles = local?.tiles ?? (visible.contains(coordinate) ? captured.current[coordinate]?.tiles ?? [] : layouts[coordinate] ?? [])
        return .init(
            x: Int32(coordinate.x),
            z: Int32(coordinate.z),
            tiles: tiles,
            pages: local?.pages ?? captured.current[coordinate]?.pages ?? [],
            instances: local?.instances ?? captured.current[coordinate]?.instances ?? [],
            surface: local?.surface ?? captured.current[coordinate]?.surface ?? [],
            ruleMasks: local?.ruleMasks ?? captured.current[coordinate]?.ruleMasks ?? []
        )
    }

    func saveSnapshot(_ request: Terrain3DSave) throws -> TerrainSourceSaveSnapshot {
        let captured = try capturedOverrides(request.storage)
        guard request.storage.revision == request.expectedRevision else { throw TerrainSourceSaveError.staleRevision }
        let references = Dictionary(uniqueKeysWithValues: cache.manifest.heightRegions.map { (TerrainRegionCoordinate(x: Int($0.x), z: Int($0.z)), $0) })
        var payloads: [TerrainRegionCoordinate: TerrainRegionAsset] = [:]
        var baselines: [TerrainRegionCoordinate: TerrainRegionAsset] = [:]
        var regions: [TerrainRegionAsset] = []
        var removing: [TerrainRegionReference] = []
        for coordinate in captured.overrides.keys.sorted() {
            let value = payload(at: coordinate, captured: captured)
            payloads[coordinate] = value
            // A clean Undo may return to this older nonzero data and then be evicted while
            // the immutable save is in flight. Keep that logical baseline for acknowledgment.
            baselines[coordinate] = .init(
                x: value.x,
                z: value.z,
                tiles: visible.contains(coordinate) ? baseline[coordinate]?.tiles ?? [] : layouts[coordinate] ?? [],
                pages: baseline[coordinate]?.pages ?? [],
                instances: baseline[coordinate]?.instances ?? [],
                surface: baseline[coordinate]?.surface ?? [],
                ruleMasks: baseline[coordinate]?.ruleMasks ?? []
            )
            if value.tiles.isEmpty && value.pages.isEmpty && value.instances.isEmpty && value.surface.isEmpty && value.ruleMasks.isEmpty {
                if let reference = references[coordinate] { removing.append(reference) }
            } else {
                regions.append(value)
            }
        }
        return .init(storage: request.storage, revision: request.expectedRevision, payloads: payloads, baselines: baselines, regions: regions, removing: removing)
    }

    /// Only bytes equal to the committed snapshot become clean. Later low-level writes remain dirty.
    func acknowledging(_ snapshot: TerrainSourceSaveSnapshot, cache: TerrainRegionCache) throws -> TerrainSourceResidency {
        var captured = try capturedOverrides(snapshot.storage)
        var layouts = layouts
        for (coordinate, saved) in snapshot.payloads {
            let current = payload(at: coordinate, captured: captured, evictedBaseline: snapshot.baselines[coordinate])
            if current.pages == saved.pages && current.tiles == saved.tiles && current.instances == saved.instances
                && current.surface == saved.surface && current.ruleMasks == saved.ruleMasks {
                captured.overrides.removeValue(forKey: coordinate)
            } else {
                captured.overrides[coordinate] = .init(
                    pages: current.pages,
                    tiles: current.tiles,
                    instances: current.instances,
                    surface: current.surface,
                    ruleMasks: current.ruleMasks
                )
            }
            layouts[coordinate] = saved.tiles
        }
        return .init(
            cache: cache,
            visible: visible,
            baseline: captured.current,
            overrides: captured.overrides,
            layouts: layouts,
            heightBudget: heightBudget,
            regionBudget: regionBudget,
            materialMaps: materialMaps,
            prototypes: prototypes,
            knownRegions: knownRegions,
            volume: volume
        )
    }
}

enum TerrainSourceSaveOutcome: Sendable {
    case saved(TerrainRegionCache)
    case failed(String)
    case cancelled
}

final class TerrainSourceSaveBox: Sendable {
    let outcome = Mutex<TerrainSourceSaveOutcome?>(nil)
}

/// A per-source immutable snapshot, owning its cancellable filesystem task without retaining ECS objects.
final class TerrainSourceSaveJob: Sendable {
    let request: Terrain3DSave
    let key: TerrainSourceKey
    let snapshot: TerrainSourceSaveSnapshot
    let box: TerrainSourceSaveBox
    private let task: Task<Void, Never>

    init(request: Terrain3DSave, key: TerrainSourceKey, snapshot: TerrainSourceSaveSnapshot, cache: TerrainRegionCache) {
        self.request = request
        self.key = key
        self.snapshot = snapshot
        let box = TerrainSourceSaveBox()
        self.box = box
        request.receipt.start()
        task = Task {
            let outcome: TerrainSourceSaveOutcome
            do {
                let next = try await cache.saveChanges(
                    snapshot.regions,
                    removing: snapshot.removing,
                    maximumBytes: request.maximumStagedBytes,
                    onProgress: request.onProgress
                )
                outcome = .saved(next)
            } catch is CancellationError { outcome = .cancelled } catch { outcome = .failed(error.localizedDescription) }
            box.outcome.withLock { $0 = outcome }
            let phase: TerrainSavePhase
            let message: String?
            switch outcome {
            case .saved: phase = .saved; message = nil
            case .cancelled: phase = .cancelled; message = nil
            case let .failed(error): phase = .failed; message = error
            }
            request.receipt.complete(.init(id: request.id, phase: phase, savedRevision: phase == .saved ? snapshot.revision : nil, error: message))
        }
    }

    var result: TerrainSourceSaveOutcome? { box.outcome.withLock { $0 } }
    func cancel() { task.cancel() }
    deinit { task.cancel() }
}
