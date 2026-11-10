import AdaECS
import Foundation

/// Opts a subworld, normally a render world, into pipelined updates.
///
/// A pipelined subworld runs one frame behind its parent. The parent extracts frame N into it,
/// starts its update and continues with frame N+1 without waiting. Before the next extraction the
/// parent waits for that update to finish, so extraction remains the only point where both worlds
/// meet. Frame time approaches the longer of the two paths instead of their sum, at the cost of
/// one frame of input latency.
///
/// While a pipelined update is in flight, systems of the subworld must not read the parent world
/// (see `Extract` and `MainWorld`), and parent systems must not mutate objects the subworld reads.
/// Set `ADAENGINE_PIPELINED_RENDERING=0|1` to override the setting of every world that declares this
/// resource, for measurements.
/// Pipelining is unavailable on WebAssembly, where the setting is ignored.
public struct RenderPipelining: Resource, Sendable {
    /// Whether this subworld updates one frame behind its parent.
    public var isEnabled: Bool

    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    /// Whether pipelining is in effect for a world declaring this setting, after the environment override.
    public var isActive: Bool {
        #if WASM
            return false
        #else
            return Self.environmentOverride ?? isEnabled
        #endif
    }

    /// Whether `world` belongs to a pipelined subworld. Usable where only the `World` is available.
    public static func isActive(in world: World) -> Bool {
        world.getResource(RenderPipelining.self)?.isActive ?? false
    }

    /// The process-wide override from `ADAENGINE_PIPELINED_RENDERING`, if set.
    static let environmentOverride: Bool? = {
        switch ProcessInfo.processInfo.environment["ADAENGINE_PIPELINED_RENDERING"] {
        case "1": true
        case "0": false
        default: nil
        }
    }()
}

extension AppWorlds {
    /// Whether this world's updates run one frame behind its parent.
    public var isUpdatePipelined: Bool {
        #if WASM
            return false
        #else
            // Only worlds that declare the resource are candidates; the override never pipelines other worlds.
            return RenderPipelining.isActive(in: main)
        #endif
    }

    /// Waits for this world's and its subworlds' in-flight pipelined updates.
    ///
    /// Tooling access, extraction and teardown call this before touching state that a pipelined
    /// update may still read. Errors of the finished update are rethrown.
    public func waitForPipelinedUpdates() async throws {
        if let pending = pipelinedUpdate {
            pipelinedUpdate = nil
            try await pending.value
        }
        for world in subWorlds.values {
            try await world.waitForPipelinedUpdates()
        }
    }

    /// Starts this world's update without waiting for it. The caller waits with ``waitForPipelinedUpdates()``.
    func startPipelinedUpdate() {
        pipelinedUpdate = Task { @MainActor [self] in
            try await update()
        }
    }
}
