import AdaGeometry
import Foundation

public enum MeshTerrainSessionError: Error, Sendable {
    case busy, invalidTransaction, historyBudgetExceeded, previewFailed
}

/// One document's provisional interaction and committed Undo/Redo history.
/// Hosts publish each returned immutable generation at their world boundary.
public actor MeshTerrainAuthoringSession {
    private struct Revision {
        let asset: MeshTerrainDocumentAsset
        let bytes: Int
    }
    private var committed: Revision
    private var provisional: Revision?
    private var transactionID: UUID?
    private var activeToken = UUID()
    private var worker: Task<MeshTerrainDocumentAsset, any Error>?
    private var latestFailed = false
    private var undoHistory: [Revision] = []
    private var redoHistory: [Revision] = []
    private var historyBytes = 0
    private let maximumHistoryBytes: Int
    private let evaluator = MeshTerrainEvaluator()

    public init(asset: MeshTerrainDocumentAsset, maximumHistoryBytes: Int = 64 * 1_024 * 1_024) throws {
        _ = try asset.acceptedCompiledProduct()
        guard (0...512 * 1_024 * 1_024).contains(maximumHistoryBytes) else { throw MeshTerrainSessionError.historyBudgetExceeded }
        let bytes = try asset.encodedData().count * 2
        guard bytes <= maximumHistoryBytes else { throw MeshTerrainSessionError.historyBudgetExceeded }
        committed = .init(asset: asset, bytes: bytes)
        self.maximumHistoryBytes = maximumHistoryBytes
    }

    public var canUndo: Bool { transactionID == nil && !undoHistory.isEmpty }
    public var canRedo: Bool { transactionID == nil && !redoHistory.isEmpty }
    public var accepted: MeshTerrainDocumentAsset { provisional?.asset ?? committed.asset }

    public func begin() throws -> UUID {
        guard transactionID == nil else { throw MeshTerrainSessionError.busy }
        let id = UUID(); transactionID = id; provisional = nil; latestFailed = false
        return id
    }

    /// Cancels superseded work. A late result cannot replace a later preview or
    /// a cancelled interaction. Geometry/population preparation runs off the host UI actor.
    public func preview(_ candidate: MeshTerrainDocumentAsset, transaction: UUID) async throws -> MeshTerrainDocumentAsset {
        guard transactionID == transaction, candidate.document.id == committed.asset.document.id else { throw MeshTerrainSessionError.invalidTransaction }
        worker?.cancel()
        let token = UUID(); activeToken = token; latestFailed = false
        let evaluator = evaluator
        let task = Task { try await candidate.compiling(using: evaluator) }
        worker = task
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard transactionID == transaction, activeToken == token else { throw CancellationError() }
            let bytes = try result.encodedData().count * 2
            guard bytes <= maximumHistoryBytes else { throw MeshTerrainSessionError.historyBudgetExceeded }
            provisional = .init(asset: result, bytes: bytes); worker = nil
            return result
        } catch {
            if activeToken == token { worker = nil; latestFailed = true }
            throw error
        }
    }

    public func commit(transaction: UUID) throws -> MeshTerrainDocumentAsset {
        guard transactionID == transaction else { throw MeshTerrainSessionError.invalidTransaction }
        guard worker == nil else { throw MeshTerrainSessionError.busy }
        guard !latestFailed else { throw MeshTerrainSessionError.previewFailed }
        if let provisional, try provisional.asset.authoringKey() != committed.asset.authoringKey() {
            historyBytes -= redoHistory.reduce(0) { $0 + $1.bytes }; redoHistory = []
            undoHistory.append(committed); historyBytes += committed.bytes
            committed = provisional
            trimHistory()
        }
        provisional = nil; transactionID = nil
        return committed.asset
    }

    public func cancel(transaction: UUID) throws -> MeshTerrainDocumentAsset {
        guard transactionID == transaction else { throw MeshTerrainSessionError.invalidTransaction }
        worker?.cancel(); worker = nil; activeToken = UUID()
        provisional = nil; transactionID = nil; latestFailed = false
        return committed.asset
    }

    public func undo() throws -> MeshTerrainDocumentAsset {
        guard transactionID == nil else { throw MeshTerrainSessionError.busy }
        guard let revision = undoHistory.popLast() else { return committed.asset }
        historyBytes -= revision.bytes
        redoHistory.append(committed); historyBytes += committed.bytes
        committed = revision; trimHistory()
        return committed.asset
    }

    public func redo() throws -> MeshTerrainDocumentAsset {
        guard transactionID == nil else { throw MeshTerrainSessionError.busy }
        guard let revision = redoHistory.popLast() else { return committed.asset }
        historyBytes -= revision.bytes
        undoHistory.append(committed); historyBytes += committed.bytes
        committed = revision; trimHistory()
        return committed.asset
    }

    private func trimHistory() {
        while historyBytes > maximumHistoryBytes || undoHistory.count + redoHistory.count > 64 {
            if !undoHistory.isEmpty { historyBytes -= undoHistory.removeFirst().bytes }
            else if !redoHistory.isEmpty { historyBytes -= redoHistory.removeFirst().bytes }
            else { break }
        }
    }
}
