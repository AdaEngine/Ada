import AdaAssets
import AdaGeometry
import Foundation
import Math
import Testing

@Suite(.enabled(if: TriangleMeshBoolean.isAvailable)) struct MeshTerrainSessionTests {
    @Test func dragCommitsAsOneUndoAndCancelRestoresAcceptedGeometry() async throws {
        let ground = try TriangleSurface.ground(size: [12, 8], cells: 6)
        let rock = try TriangleSurface.box(minimum: [-1, -1, -1], maximum: [1, 2, 1])
        let modifier = MeshTerrainModifier(sourceID: 1, operation: .union, surface: rock)
        let initial = try await MeshTerrainDocumentAsset(document: .init(sections: [.init(surface: ground, closure: .ground(bottomHeight: -4))],
                                                                       modifiers: [modifier])).compiling()
        let session = try MeshTerrainAuthoringSession(asset: initial)
        let transaction = try await session.begin()
        var candidate = initial.document
        for x: Float in [1, 2, 3] {
            candidate.modifiers[0].transform = .init(translation: [x, 0, 0])
            _ = try await session.preview(.init(document: candidate), transaction: transaction)
        }
        let moved = try await session.commit(transaction: transaction)
        #expect(moved.document.modifiers[0].transform.origin.x == 3)
        let undone = try await session.undo()
        #expect(undone.document == initial.document)
        #expect(try undone.acceptedCompiledProduct() == initial.acceptedCompiledProduct())
        let redone = try await session.redo()
        #expect(redone.document == moved.document)
        let cancelled = try await session.begin()
        candidate.modifiers[0].transform = .init(translation: [-3, 0, 0])
        _ = try await session.preview(.init(document: candidate), transaction: cancelled)
        #expect(try await session.cancel(transaction: cancelled).document == moved.document)
    }
}
