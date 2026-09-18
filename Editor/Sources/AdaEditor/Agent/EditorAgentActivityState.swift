@_spi(AdaEngine) import AdaEngine

enum EditorAgentActivityState: String, Equatable, Sendable {
    case idle, working, completed, needsInput, failed

    var motion: Float {
        switch self {
        case .idle,
            .completed:
            0
        case .working: 1
        case .needsInput: 0.32
        case .failed: 0.15
        }
    }

    var intensity: Float {
        switch self {
        case .idle: 0
        case .working,
            .needsInput:
            1.15
        case .completed: 0.98
        case .failed: 1.09
        }
    }

    func color(accent: Color) -> Color {
        switch self {
        case .idle,
            .working:
            accent
        case .completed: Color(red: 52 / 255, green: 210 / 255, blue: 123 / 255)
        case .needsInput: Color(red: 245 / 255, green: 200 / 255, blue: 66 / 255)
        case .failed: Color(red: 240 / 255, green: 100 / 255, blue: 100 / 255)
        }
    }

    static func resolve(
        operation: EditorOperationActivity.State?,
        connection: EditorAgentConnectionState,
        isSending: Bool
    ) -> Self {
        if operation == .running || operation == .needsAttention {
            if case .failed = connection {
                return .failed
            }
            return operation == .needsAttention ? .needsInput : .working
        }
        if case .failed = connection {
            return .failed
        }
        if case .connecting = connection {
            return .working
        }
        switch operation {
        case .completed: return .completed
        case .failed,
            .interrupted:
            return .failed
        case .cancelled: return .idle
        default: return isSending ? .working : .idle
        }
    }
}

extension EditorAgentViewModel {
    /// Observe only this window's latest run, including a run continuing in another chat.
    /// Historical notifications and operations belonging to other projects cannot light this window.
    var activityState: EditorAgentActivityState {
        let operation = lastActivityID.flatMap { id in notifications.activities.all.first { $0.id == id } }
        return .resolve(operation: operation?.state, connection: currentConnectionState, isSending: isSending)
    }
}
