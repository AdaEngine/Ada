//
//  Scene.swift
//  AdaEngine
//
//  Created by v.prusakov on 11/1/21.
//

import AdaAssets
import AdaECS
import AdaUI
import AdaUtils
import Foundation
import OrderedCollections

enum SceneSerializationError: Error {
    case invalidExtensionType
    case unsupportedVersion
    case notRegistedObject(String)
}

/// A container that holds the collection of entities for render.
@safe
open class Scene: @unsafe Asset, @unchecked Sendable {
    public typealias ID = UUID

    /// Current supported version for mapping scene from file.
    nonisolated(unsafe) public static let currentVersion: Version = "1.0.0"

    /// Current scene name.
    public var name: String

    /// Current scene id.
    public private(set) var id: ID

    /// Current window for scene.
    public internal(set) weak var window: UIWindow?

    nonisolated(unsafe) public var assetMetaInfo: AssetMetaInfo?

    /// World for scene.
    public private(set) var world: World

    /// Event manager for scene.
    public private(set) var eventManager: EventManager = EventManager.default

    // MARK: - Initialization -

    /// Create new scene instance.
    /// - Parameter name: Name of this scene. By default name is `Scene`.
    /// - Parameter instantiateDefaultPlugin:
    public init(name: String? = nil) {
        self.id = UUID()
        self.name = name ?? "Scene"
        self.world = World()
    }

    public init(from world: World) {
        self.id = UUID()
        self.name = "Scene"
        self.world = world
    }

    // MARK: - Resource -
    public required convenience init(from assetDecoder: any AssetDecoder) throws {
        guard Self.extensions().contains(where: { assetDecoder.assetMeta.filePath.pathExtension == $0 }) else {
            throw SceneSerializationError.invalidExtensionType
        }

        let scene = try assetDecoder.decode(SceneSerialization.self)

        if unsafe Self.currentVersion < scene.version {
            throw SceneSerializationError.unsupportedVersion
        }

        self.init(name: scene.scene)
        self.world = scene.world
    }

    public func encodeContents(with assetEncoder: any AssetEncoder) throws {
        guard Self.extensions().contains(where: { assetEncoder.assetMeta.filePath.pathExtension == $0 }) else {
            throw SceneSerializationError.invalidExtensionType
        }

        unsafe try assetEncoder.encode(
            SceneSerialization(
                version: Self.currentVersion,
                scene: name,
                world: world
            )
        )
    }

    public static func extensions() -> [String] {
        ["ascn", "scene", "scn"]
    }
}

// MARK: - EventSource

extension Scene: EventSource {
    /// Receives events of the given type.
    /// - Parameters event: The type of the event, like `CollisionEvents.Began.Self`.
    /// - Parameters completion: A closure to call with the event.
    /// - Returns: A cancellable object. You should store it in memory, to recieve events.
    public func subscribe<E>(
        to event: E.Type,
        on eventSource: EventSource?,
        completion: @escaping @Sendable (E) -> Void
    ) -> Cancellable where E: Event {
        return self.eventManager.subscribe(to: event, on: eventSource ?? self, completion: completion)
    }
}

/// Events the scene triggers.
public enum SceneEvents {
    /// An event triggered once when scene is ready to use and will starts update soon.
    public struct OnReady: Event {
        public let scene: Scene
    }

    /// An event triggered once per frame interval that you can use to execute custom logic for each frame.
    public struct Update: Event {
        /// The updated scene.
        public let scene: Scene

        /// The elapsed time since the last update.
        public let deltaTime: AdaUtils.TimeInterval
    }
}

struct SceneResource: Resource {
    unowned let scene: Scene
}

extension WorldUpdateContext {
    public var scene: Scene? {
        self.world.getResource(SceneResource.self)?.scene
    }
}

extension Scene {
    private struct SceneSerialization: Codable {
        let version: Version
        let scene: String
        let world: AdaECS.World
    }
}
