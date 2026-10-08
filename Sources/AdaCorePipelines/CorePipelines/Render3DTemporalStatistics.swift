import AdaECS
import Math
import Synchronization

/// Local diagnostics distinguish actual temporal encoding from a capability check or spatial fallback.
public final class Render3DTemporalStatistics: Resource, Sendable {
    public struct Snapshot: Codable, Sendable {
        public var inputWidth: Int
        public var inputHeight: Int
        public var outputWidth: Int
        public var outputHeight: Int
        public var encodedFrames = 0
        public var fallbackFrames = 0
        public var historyResets = 0
    }
    private let state = Mutex<[String: Snapshot]>([:])
    public init() {}

    func record(view: Entity.ID, input: SizeInt, output: SizeInt, encoded: Bool, reset: Bool) {
        state.withLock { state in
            let key = "\(view)"
            var value = state[key] ?? Snapshot(inputWidth: input.width, inputHeight: input.height, outputWidth: output.width, outputHeight: output.height)
            value.inputWidth = input.width
            value.inputHeight = input.height
            value.outputWidth = output.width
            value.outputHeight = output.height
            if encoded { value.encodedFrames += 1 } else { value.fallbackFrames += 1 }
            if reset { value.historyResets += 1 }
            state[key] = value
        }
    }

    func retainViews(_ views: [Entity.ID]) {
        let keys = Set(views.map { "\($0)" })
        state.withLock { state in
            for key in state.keys where !keys.contains(key) { state.removeValue(forKey: key) }
        }
    }

    public var snapshots: [String: Snapshot] { state.withLock { $0 } }
}
