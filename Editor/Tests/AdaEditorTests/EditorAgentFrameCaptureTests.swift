import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite("Agent frame capture", .serialized)
struct EditorAgentFrameCaptureTests {
    @Test("Stopping capture resumes an outstanding frame waiter")
    func stopsPendingFrame() async {
        let capture = EditorProjectPreviewCapture(projectURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let waiter = Task { @MainActor in try await capture.nextFrame() }
        await Task.yield()
        capture.stop()
        switch await waiter.result {
        case .success: Issue.record("Stopped capture returned an image")
        case .failure: break
        }
    }

    @Test("Cancelling a frame wait does not leak the continuation")
    func cancelsPendingFrame() async {
        let capture = EditorProjectPreviewCapture(projectURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let waiter = Task { @MainActor in try await capture.nextFrame() }
        await Task.yield()
        waiter.cancel()
        switch await waiter.result {
        case .success: Issue.record("Cancelled capture returned an image")
        case .failure: break
        }
        capture.stop()
    }
}
