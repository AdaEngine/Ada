//
//  ScriptableComponent.swift
//  AdaEngine
//

import AdaECS
import AdaInput
import AdaUtils

/// Contains a heterogeneous collection of registered ``ScriptableObject`` values.
@Component
public struct ScriptableComponents: Codable {
    public var scripts: ContiguousArray<ScriptableObject> = []

    private enum CodingKeys: String, CodingKey {
        case scripts
    }

    public init(scripts: ContiguousArray<ScriptableObject>) {
        self.scripts = scripts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.scripts = ContiguousArray(
            try container.decode([ScriptableObjectEnvelope].self, forKey: .scripts).map(\.script)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scripts.map(ScriptableObjectEnvelope.init(script:)), forKey: .scripts)
    }
}

/// Base class for low-cardinality, entity-attached gameplay behavior.
///
/// Lifecycle callbacks receive a scoped ``ScriptableObjectContext``. Use ECS
/// systems and queries for data-oriented work over large entity sets.
open class ScriptableObject: Codable, @unchecked Sendable {
    private enum LifecycleState {
        case unattached
        case attached
        case ready
        case destroyed
    }

    package var encodedSchemaVersion: Int = 1
    package weak var attachedEntity: Entity?
    private var lifecycleState: LifecycleState = .unattached

    /// Stable identifier supplied by wrappers that share one native runtime type.
    open var explicitTypeIdentifier: String? { nil }

    /// Creates a detached scriptable object.
    public required init() {}

    /// Returns detached exported state for UI binding. Override alongside `writeExportedField` in native scripts.
    /// AdaScript provides these accessors automatically for `@export` properties.
    @MainActor
    open func readExportedField(_: String) -> EditorFieldValue? { nil }

    /// Applies a queued UI edit outside view construction. Return false for unknown or incompatible values.
    @MainActor
    open func writeExportedField(_: String, value _: EditorFieldValue) -> Bool { false }

    /// Called exactly once after successful attachment.
    @MainActor
    open func ready(context _: ScriptableObjectContext) {}

    /// Called on the update scheduler.
    @MainActor
    open func update(context _: ScriptableObjectContext) {}

    /// Called for fixed-timestep work.
    @MainActor
    open func fixedUpdate(context _: ScriptableObjectContext) {}

    /// Called when input events are available.
    @MainActor
    open func event(_: [any InputEvent], context _: ScriptableObjectContext) {}

    /// Called exactly once when the object is detached or its entity disappears.
    @MainActor
    open func destroy(context _: ScriptableObjectContext) {}

    // MARK: - Codable

    public required init(from decoder: Decoder) throws {
        var mirror: Mirror? = Mirror(reflecting: self)
        let container = try decoder.container(keyedBy: CodingName.self)

        repeat {
            guard let children = mirror?.children else {
                break
            }
            for child in children {
                guard let decodableKey = child.value as? _ExportDecodable else {
                    continue
                }
                let propertyName = String((child.label ?? "").dropFirst())
                try decodableKey.decode(
                    from: container,
                    propertyName: propertyName,
                    userInfo: decoder.userInfo
                )
            }
            mirror = mirror?.superclassMirror
        } while mirror != nil
    }

    open func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingName.self)
        var mirror: Mirror? = Mirror(reflecting: self)

        repeat {
            guard let children = mirror?.children else {
                break
            }
            for child in children {
                guard let encodableKey = child.value as? _ExportEncodable else {
                    continue
                }
                let propertyName = String((child.label ?? "").dropFirst())
                try encodableKey.encode(
                    to: &container,
                    propertyName: propertyName,
                    userInfo: encoder.userInfo
                )
            }
            mirror = mirror?.superclassMirror
        } while mirror != nil
    }

    @MainActor
    package func attach(to entity: Entity) -> Bool {
        switch lifecycleState {
        case .unattached:
            attachedEntity = entity
            lifecycleState = .attached
            return true
        case .attached,
            .ready:
            return attachedEntity === entity
        case .destroyed:
            return false
        }
    }

    @MainActor
    package func runReadyIfNeeded(context: ScriptableObjectContext) {
        guard lifecycleState == .attached else {
            return
        }
        ready(context: context)
        lifecycleState = .ready
    }

    @MainActor
    package func detach(context: ScriptableObjectContext) {
        guard lifecycleState == .attached || lifecycleState == .ready else {
            return
        }
        lifecycleState = .destroyed
        destroy(context: context)
        attachedEntity = nil
    }
}

extension ScriptableObject {
    package var components: Entity.ComponentSet {
        get {
            guard let attachedEntity else {
                fatalError("Scriptable object is not attached to an entity")
            }
            return attachedEntity.components
        }
        set {
            attachedEntity?.components = newValue
        }
    }
}
