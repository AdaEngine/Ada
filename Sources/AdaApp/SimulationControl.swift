import AdaECS

public enum SimulationMode: String, Codable, Sendable {
    case running
    case paused
}

public struct SimulationControl: Resource, Codable, Sendable {
    public var mode: SimulationMode
    public var reason: String?
    public var pendingStepCount: Int

    public init(
        mode: SimulationMode = .running,
        reason: String? = nil,
        pendingStepCount: Int = 0
    ) {
        self.mode = mode
        self.reason = reason
        self.pendingStepCount = pendingStepCount
    }
}
