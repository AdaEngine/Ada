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
    private let memory = Mutex<[String: Int]>([:])
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

    /// Latest GPU memory held per resource, in bytes. Resources that hold nothing are absent.
    public var memoryBytes: [String: Int] { memory.withLock { $0 } }

    /// Records how many bytes `resource` currently holds, replacing the previous figure. Zero removes the entry.
    public func record(memory resource: String, bytes: Int) {
        memory.withLock { values in
            if bytes > 0 { values[resource] = bytes } else { values.removeValue(forKey: resource) }
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

    /// Sum of the per-pass averages in milliseconds. Passes can overlap on the GPU, so treat this as a
    /// budget indicator rather than a measured frame time.
    public var totalAverageMilliseconds: Double {
        samples.reduce(0) { $0 + $1.averageMilliseconds }
    }

    /// A fixed-width table of the measured passes, slowest first, ending with the summed average. Meant for
    /// logs and developer overlays; returns a single line while nothing has been measured yet.
    public func report() -> String {
        let measured = samples.sorted { $0.averageMilliseconds > $1.averageMilliseconds }
        let held = memoryBytes.sorted { $0.key < $1.key }
        guard !measured.isEmpty || !held.isEmpty else {
            return "No GPU pass timings recorded yet."
        }
        func kibibytes(_ bytes: Int) -> String {
            let tenths = Int((Double(bytes) / 1024 * 10).rounded())
            return "\(tenths / 10).\(tenths % 10) KiB"
        }
        let memoryLines = held.map { "memory " + $0.key + " " + kibibytes($0.value) }
        guard !measured.isEmpty else {
            return memoryLines.joined(separator: "\n")
        }
        func milliseconds(_ value: Double) -> String {
            let thousandths = Int((value * 1000).rounded())
            let fraction = String(thousandths % 1000)
            return "\(thousandths / 1000)." + String(repeating: "0", count: 3 - fraction.count) + fraction
        }
        func column(_ text: String, _ width: Int, alignRight: Bool = true) -> String {
            let padding = String(repeating: " ", count: max(0, width - text.count))
            return alignRight ? padding + text : text + padding
        }
        let nameWidth = max(8, measured.map(\.pass.count).max() ?? 0)
        var lines = [column("pass", nameWidth, alignRight: false) + column("avg ms", 9) + column("min ms", 9) + column("max ms", 9) + column("frames", 8)]
        for sample in measured {
            lines.append(
                column(sample.pass, nameWidth, alignRight: false)
                    + column(milliseconds(sample.averageMilliseconds), 9)
                    + column(milliseconds(sample.minimumMilliseconds), 9)
                    + column(milliseconds(sample.maximumMilliseconds), 9)
                    + column(String(sample.count), 8)
            )
        }
        lines.append(column("total", nameWidth, alignRight: false) + column(milliseconds(totalAverageMilliseconds), 9))
        return (lines + memoryLines).joined(separator: "\n")
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
