import AdaECS
import AdaRender
import Synchronization

/// Optional local GPU-pass measurements. Install only when profiling is requested.
/// Backends without GPU timestamps report unavailable rather than CPU submission time.
public final class Render3DPerformanceMetrics: Resource, Sendable {
    public struct Sample: Sendable, Codable {
        public let pass: String
        public let count: Int
        public let averageMilliseconds: Double
        public let minimumMilliseconds: Double
        public let maximumMilliseconds: Double
    }
    private struct Accumulator {
        var seen = 0
        var count = 0
        var sum: Double = 0
        var minimum = Double.infinity
        var maximum: Double = 0
    }
    private let state = Mutex<[String: Accumulator]>([:])
    private let warmupSamples: Int
    /// Profiling-only serialization isolates pass durations from dependent GPU work.
    public let synchronizesPasses: Bool

    public init(warmupSamples: Int = 20, synchronizesPasses: Bool = false) {
        self.warmupSamples = max(0, warmupSamples)
        self.synchronizesPasses = synchronizesPasses
    }

    func commit(_ command: CommandBuffer) async {
        guard synchronizesPasses else {
            command.commit()
            return
        }
        await withCheckedContinuation { continuation in
            command.addCompletedHandler { continuation.resume() }
            command.commit()
        }
    }

    public func record(pass: String, seconds: Double?) {
        guard let seconds, seconds.isFinite, seconds > 0 else {
            return
        }
        state.withLock { values in
            var value = values[pass] ?? Accumulator()
            value.seen += 1
            if value.seen > warmupSamples {
                let milliseconds = seconds * 1000
                value.count += 1
                value.sum += milliseconds
                value.minimum = min(value.minimum, milliseconds)
                value.maximum = max(value.maximum, milliseconds)
            }
            values[pass] = value
        }
    }

    public var samples: [Sample] {
        state.withLock { values in
            values.compactMap { name, value in
                guard value.count >= 1 else {
                    return nil
                }
                return Sample(pass: name, count: value.count, averageMilliseconds: value.sum / Double(value.count), minimumMilliseconds: value.minimum, maximumMilliseconds: value.maximum)
            }.sorted { $0.pass < $1.pass }
        }
    }
}
