import AdaApp
import AdaAssets
import AdaECS
@_spi(Internal) import AdaRender
import Foundation
import Math
import Synchronization

/// Portable image inputs shared by scene authoring and scripted placement.
public struct Decal3DImages: Codable, Equatable, Sendable {
    public var color: String
    public var normal: String?
    public var roughness: String?
    public var priority: Int

    public init(color: String, normal: String? = nil, roughness: String? = nil, priority: Int = 0) {
        self.color = color
        self.normal = normal
        self.roughness = roughness
        self.priority = priority
    }

    enum LoadError: Error {
        case invalidPath
    }

    public func load() async throws -> Decal3D.Appearance {
        let color = try await Self.load(color)
        let normal = if let normal { try await Self.load(normal) } else { nil as Image? }
        let roughness = if let roughness { try await Self.load(roughness) } else { nil as Image? }
        return Decal3D.Appearance(color: color, normal: normal, roughness: roughness, priority: priority)
    }

    private static func load(_ path: String) async throws -> Image {
        let relative = path.dropFirst(7)
        guard path.hasPrefix("@res://"), !relative.isEmpty, relative.utf8.count <= 4_096,
              !relative.contains("\\"), !relative.contains(":"), !relative.contains("#"),
              relative.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw LoadError.invalidPath
        }
        return try await AssetsManager.load(Image.self, at: path).asset
    }
}

@_spi(Scripting)
public final class Decal3DCommands: Resource {
    public struct Outcome: Sendable {
        public let value: String
        public let errorCode: String
        public let message: String

        static func success(_ value: String = "") -> Self {
            Self(value: value, errorCode: "", message: "")
        }

        static func failure(_ code: String, _ message: String) -> Self {
            Self(value: "", errorCode: code, message: message)
        }
    }

    public enum Operation: Sendable {
        case place(Entity.ID, Decal3D.Projector, Decal3DImages)
        case update(Entity.ID, String, Decal3DImages)
        case remove(Entity.ID, String)

        var receiver: Entity.ID {
            switch self {
            case let .place(receiver, _, _), let .update(receiver, _, _), let .remove(receiver, _): receiver
            }
        }

        var missingReceiver: Outcome {
            switch self {
            case .place: .failure("unsupportedReceiver", "The receiver needs a supported Mesh3DComponent.")
            case .update, .remove: .failure("staleHandle", "The decal receiver is no longer available.")
            }
        }

        var images: Decal3DImages? {
            switch self {
            case let .place(_, _, images), let .update(_, _, images): images
            case .remove: nil
            }
        }
    }

    struct Request: Sendable {
        let id: String
        let operation: Operation
    }

    private struct Mailbox {
        var ready: [Request] = []
        var inFlight: Set<String> = []
        var completed: [String: Outcome] = [:]
        var completedOrder: [String] = []

        mutating func finish(_ id: String, outcome: Outcome) {
            inFlight.remove(id)
            if completedOrder.count == 256 {
                completed.removeValue(forKey: completedOrder.removeFirst())
            }
            completed[id] = outcome
            completedOrder.append(id)
        }
    }

    private let mailbox = Mutex(Mailbox())

    public func enqueue(_ operation: Operation) -> String {
        let id = UUID().uuidString
        mailbox.withLock { state in
            if state.ready.count + state.inFlight.count < 64 {
                state.ready.append(Request(id: id, operation: operation))
            } else {
                state.finish(id, outcome: .failure("capacityExceeded", "The decal command queue is full."))
            }
        }
        return id
    }

    public func rejectInvalidArguments() -> String {
        let id = UUID().uuidString
        complete(id, outcome: .failure("invalidArguments", "The decal command has invalid arguments."))
        return id
    }

    public func takeResult(_ request: String) -> Outcome? {
        mailbox.withLock { state in
            if let result = state.completed.removeValue(forKey: request) {
                state.completedOrder.removeAll { $0 == request }
                return result
            }
            if state.inFlight.contains(request) || state.ready.contains(where: { $0.id == request }) {
                return nil
            }
            return .failure("unknownRequest", "The decal request is unknown, expired, or already consumed.")
        }
    }

    func next() -> Request? {
        mailbox.withLock { state in
            guard !state.ready.isEmpty else {
                return nil
            }
            let request = state.ready.removeFirst()
            state.inFlight.insert(request.id)
            return request
        }
    }

    func complete(_ id: String, outcome: Outcome) {
        mailbox.withLock { $0.finish(id, outcome: outcome) }
    }
}

struct Decal3DCommandSystem: System {
    @Res<Decal3DCommands> private var commands
    private let executor = Executor()

    var queries: SystemQueries { SystemQueries(queries: [_commands, ExclusiveWorldAccess()]) }

    static let dependencies: [SystemDependency] = [.after(SkeletalAnimation3DSystem.self), .after(Decal3DCleanupSystem.self)]

    init(world _: World) {}

    @MainActor
    func update(context: UpdateContext) {
        executor.update(context.world, commands: commands)
    }

    private final class Executor: Sendable {
        private struct Applied {
            let receiver: Entity.ID
            let handle: Decal3D.Handle
        }

        private struct Loading {
            let request: Decal3DCommands.Request
            let receiver: ObjectIdentifier
            let task: Task<Void, Never>
        }

        @MainActor private var loading: Loading?
        @MainActor private var loaded: Decal3D.Appearance?
        @MainActor private var finishedLoading = false
        @MainActor private var handles: [String: Applied] = [:]

        @MainActor
        func update(_ world: World, commands: Decal3DCommands) {
            if let work = loading {
                guard let receiver = world.getEntityByID(work.request.operation.receiver), ObjectIdentifier(receiver) == work.receiver else {
                    work.task.cancel()
                    loading = nil
                    loaded = nil
                    finishedLoading = false
                    commands.complete(work.request.id, outcome: work.request.operation.missingReceiver)
                    return
                }
                guard finishedLoading else {
                    return
                }
                loading = nil
                finishedLoading = false
                let appearance = loaded
                loaded = nil
                guard let appearance else {
                    commands.complete(work.request.id, outcome: .failure("assetLoadFailed", "Could not load the decal images from project assets."))
                    return
                }
                apply(work.request, to: receiver, appearance: appearance, commands: commands)
                return
            }

            guard let request = commands.next() else {
                return
            }
            handles = handles.filter { _, applied in
                guard let receiver = world.getEntityByID(applied.receiver) else {
                    return false
                }
                return Decal3D.contains(applied.handle, on: receiver)
            }
            guard Decal3D.isSupported else {
                commands.complete(request.id, outcome: .failure("unsupportedBackend", "3D decals require native SAGA raster rendering."))
                return
            }
            guard let receiver = world.getEntityByID(request.operation.receiver), receiver.components[Mesh3DComponent.self] != nil else {
                commands.complete(request.id, outcome: request.operation.missingReceiver)
                return
            }
            if let images = request.operation.images {
                let task = Task { @MainActor [weak self] in
                    let appearance = try? await images.load()
                    guard !Task.isCancelled, let self else {
                        return
                    }
                    self.loaded = appearance
                    self.finishedLoading = true
                }
                loading = Loading(request: request, receiver: ObjectIdentifier(receiver), task: task)
            } else {
                apply(request, to: receiver, appearance: nil, commands: commands)
            }
        }

        @MainActor
        private func apply(
            _ request: Decal3DCommands.Request, to receiver: Entity, appearance: Decal3D.Appearance?, commands: Decal3DCommands
        ) {
            let outcome: Decal3DCommands.Outcome
            do throws(Decal3D.PlacementError) {
                switch request.operation {
                case let .place(_, projector, _):
                    guard let appearance else { throw .invalidAppearance }
                    let handle = try Decal3D.place(on: receiver, projector: projector, appearance: appearance)
                    handles[request.id] = Applied(receiver: receiver.id, handle: handle)
                    outcome = .success(request.id)
                case let .update(_, token, _):
                    guard let applied = handles[token], applied.receiver == receiver.id else { throw .staleHandle }
                    guard let appearance else { throw .invalidAppearance }
                    try Decal3D.update(applied.handle, on: receiver, appearance: appearance)
                    outcome = .success(token)
                case let .remove(_, token):
                    guard let applied = handles[token], applied.receiver == receiver.id else { throw .staleHandle }
                    try Decal3D.remove(applied.handle, from: receiver)
                    handles.removeValue(forKey: token)
                    outcome = .success()
                }
            } catch {
                outcome = .failure(String(describing: error), "The 3D decal operation failed: \(error).")
            }
            commands.complete(request.id, outcome: outcome)
        }
    }
}
