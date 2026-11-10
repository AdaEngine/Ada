import AdaApp
import AdaUtils
import Observation

/// Measures the elapsed time between variable updates in a single game world.
@_spi(AdaEngine)
@MainActor
@Observable
public final class GameDiagnosticsSession {
    struct Sample: Equatable {
        let framesPerSecond: Double
        let millisecondsPerFrame: Double
    }

    private(set) var sample: Sample?
    @ObservationIgnored private var windowStart: Double?
    @ObservationIgnored private var previousTick: Double?
    @ObservationIgnored private var intervalCount = 0

    public init() {}

    public func attach(to app: AppWorlds) {
        reset()
        app.gameDiagnosticsTick = { [weak self] isRunning in
            self?.tick(at: Time.absolute, isRunning: isRunning)
        }
    }

    func tick(at timestamp: Double, isRunning: Bool = true) {
        guard isRunning else {
            reset()
            return
        }
        guard timestamp.isFinite else {
            return
        }
        guard let windowStart, let previousTick else {
            self.windowStart = timestamp
            self.previousTick = timestamp
            return
        }
        let elapsed = timestamp - windowStart
        guard timestamp > previousTick, elapsed.isFinite else {
            return
        }
        self.previousTick = timestamp
        intervalCount += 1

        guard elapsed >= 1 else {
            return
        }
        sample = Sample(
            framesPerSecond: Double(intervalCount) / elapsed,
            millisecondsPerFrame: elapsed / Double(intervalCount) * 1_000
        )
        self.windowStart = timestamp
        intervalCount = 0
    }

    private func reset() {
        if sample != nil {
            sample = nil
        }
        windowStart = nil
        previousTick = nil
        intervalCount = 0
    }
}
