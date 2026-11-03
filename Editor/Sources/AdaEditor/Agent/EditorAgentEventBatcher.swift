import Foundation

/// Publish at most one text update per interval. Control events flush text immediately
/// so permissions, tool updates and terminal persistence retain provider ordering.
@MainActor
final class EditorAgentEventBatcher {
    private var pending: EditorAgentEvent?
    private var task: Task<Void, Never>?
    private let publish: (EditorAgentEvent) -> Void

    init(publish: @escaping (EditorAgentEvent) -> Void) {
        self.publish = publish
    }

    func receive(_ event: EditorAgentEvent) {
        guard event.kind == .message,
              event.configuration == nil, event.permission == nil, event.toolCall == nil,
              let message = event.message, message.role == .assistant,
              message.segments.count == 1,
              let segment = message.segments.first, segment.kind == .text || segment.kind == .thinking else {
            flush()
            publish(event)
            return
        }
        if pending?.id != event.id || pending?.message?.segments.first?.kind != segment.kind
            || (pending?.isDelta == true) != (event.isDelta == true) {
            flush()
        }
        if pending == nil || event.isDelta != true {
            pending = event
        } else {
            let text = (pending?.message?.segments[0].text ?? "") + (segment.text ?? "")
            pending?.message?.segments[0].text = text
            pending?.createdAt = event.createdAt
        }
        guard task == nil else { return }
        task = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
            self?.flush()
        }
    }

    func flush() {
        task?.cancel()
        task = nil
        guard let event = pending else { return }
        pending = nil
        publish(event)
    }
}
