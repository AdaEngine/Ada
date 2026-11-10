import Foundation
import Synchronization

/// Opt-in local slow-operation logging. No timestamps or output are produced unless ADAENGINE_STALL_PROBE=1.
/// Durations include suspension/queue latency where the caller measures an asynchronous operation, not GPU timestamps.
public enum PerformanceStallProbe {
    public static let isEnabled = ProcessInfo.processInfo.environment["ADAENGINE_STALL_PROBE"] == "1"
    private static let origin = ContinuousClock.now
    private static let outputLock = Mutex(())
    private static let threshold = ProcessInfo.processInfo.environment["ADAENGINE_STALL_THRESHOLD_MS"]
        .flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0.05 ? $0 : nil } ?? 8

    public static func begin() -> ContinuousClock.Instant? {
        guard isEnabled else { return nil }
        _ = origin
        return .now
    }

    public static func end(_ phase: String, since start: ContinuousClock.Instant?, bytes: Int = 0, count: Int = 0) {
        guard isEnabled, let start else { return }
        let duration = milliseconds(start.duration(to: .now))
        guard duration >= threshold else { return }
        let elapsed = milliseconds(origin.duration(to: start))
        let name = phase.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        write("ADA_STALL\t\(elapsed)\t\(duration)\t\(name)\t\(bytes)\t\(count)")
    }

    /// Marker on the same monotonic timeline as slow operations; only used by opt-in profiling tools.
    public static func mark(_ phase: String) {
        guard isEnabled else { return }
        let elapsed = milliseconds(origin.duration(to: .now))
        write("ADA_STALL_PHASE\t\(elapsed)\t\(phase)")
    }

    /// Writes unbuffered so piped profiling captures keep their order relative to other output.
    private static func write(_ line: String) {
        outputLock.withLock { _ in try? FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8)) }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }
}
