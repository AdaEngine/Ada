#if canImport(ACP) && canImport(ACPModel)
import ACP
import ACPModel
import Foundation

/// A prompt response can overtake the client's separately consumed notification stream.
/// Observe wire order through ACP's in-memory debug stream, without logging payloads, and
/// wait until the UI sink has processed every session update preceding that response.
actor EditorACPNotificationDrain {
    private var issued = 0
    private var observed = 0
    private var receivedNotifications = 0
    private var processedNotifications = 0
    private var requestTickets: [RequestId: Int] = [:]
    private var targets: [Int: Int] = [:]
    private var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var abandoned = Set<Int>()
    private var isClosed = false

    func beginPrompt() -> Int {
        issued += 1
        return issued
    }

    func observe(_ debug: DebugMessage) {
        guard let message = try? JSONDecoder().decode(ACPModel.Message.self, from: debug.rawData) else {
            return
        }
        switch (debug.direction, message) {
        case let (.outgoing, .request(request)) where request.method == "session/prompt":
            observed += 1
            requestTickets[request.id] = observed
        case let (.incoming, .notification(notification)) where notification.method == "session/update":
            receivedNotifications += 1
        case let (.incoming, .response(response)):
            guard let ticket = requestTickets.removeValue(forKey: response.id) else {
                return
            }
            if abandoned.remove(ticket) != nil {
                return
            }
            targets[ticket] = receivedNotifications
            resumeReady()
        default: break
        }
    }

    func didProcessNotification() {
        processedNotifications += 1
        resumeReady()
    }

    func wait(for ticket: Int) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if isClosed || Task.isCancelled {
                    continuation.resume(throwing: EditorAgentServiceError.sessionUnavailable)
                } else if let target = targets[ticket], processedNotifications >= target {
                    targets.removeValue(forKey: ticket)
                    continuation.resume()
                } else {
                    waiters[ticket] = continuation
                }
            }
        } onCancel: {
            Task { await self.abandon(ticket) }
        }
    }

    func abandon(_ ticket: Int) {
        abandoned.insert(ticket)
        targets.removeValue(forKey: ticket)
        waiters.removeValue(forKey: ticket)?.resume(throwing: CancellationError())
    }

    func close() {
        isClosed = true
        let pending = waiters.values
        waiters.removeAll()
        for continuation in pending { continuation.resume(throwing: EditorAgentServiceError.sessionUnavailable) }
    }

    private func resumeReady() {
        for ticket in Array(waiters.keys) {
            if let target = targets[ticket], processedNotifications >= target {
                targets.removeValue(forKey: ticket)
                waiters.removeValue(forKey: ticket)?.resume()
            }
        }
    }
}
#endif
