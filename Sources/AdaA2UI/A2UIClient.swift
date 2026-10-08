import AdaUI
import AdaUIDescription
import Foundation
import Observation

/// One session with one originating agent. Supply complete, ordered JSON envelopes from any transport.
/// The Ada catalog is deliberately smaller than the A2UI Basic Catalog.
@MainActor @Observable
public final class A2UIClient {
    nonisolated public static let catalogID = "https://adaengine.org/a2ui/catalogs/forms/v1"
    public private(set) var surfaces: [String: A2UISurface] = [:]
    public private(set) var lastError: A2UIValidationError?
    @ObservationIgnored public var onEvent: (@MainActor (A2UIClientEvent) -> Void)?
    /// Called after a surface changes, including local input edits, creation, and deletion.
    @ObservationIgnored public var onSurfaceChanged: (@MainActor (String) -> Void)?
    public let maximumMessageBytes: Int
    public let maximumComponents: Int
    public let maximumSurfaces: Int

    public init(maximumMessageBytes: Int = 1_048_576, maximumComponents: Int = 1024, maximumSurfaces: Int = 16) {
        self.maximumMessageBytes = max(1, maximumMessageBytes)
        self.maximumComponents = max(1, maximumComponents)
        self.maximumSurfaces = max(1, maximumSurfaces)
    }

    /// Metadata to include in the host transport's capability negotiation.
    public var capabilities: UIValue {
        .object(["a2uiClientCapabilities": .object(["supportedCatalogIds": .array([.string(Self.catalogID)])])])
    }

    /// The catalog schema to provide to the agent alongside `commonTypesSchema()`.
    /// Its identifier does not trigger a network fetch.
    public static func catalogSchema() throws -> Data {
        guard let url = Bundle.module.url(forResource: "catalog", withExtension: "json", subdirectory: "Resources") else {
            throw A2UIValidationError(message: "Bundled Ada catalog is missing.")
        }
        return try Data(contentsOf: url)
    }

    /// Structural type definitions referenced by the catalog schema as `common_types.json`.
    public static func commonTypesSchema() throws -> Data {
        guard let url = Bundle.module.url(forResource: "common_types", withExtension: "json", subdirectory: "Resources") else {
            throw A2UIValidationError(message: "Bundled structural types are missing.")
        }
        return try Data(contentsOf: url)
    }

    /// Applies one message atomically. Invalid messages retain the previous UI and emit an error event.
    public func receive(_ json: Data) throws {
        var surfaceID = ""
        do {
            let message = try A2UIMessage(json: json, maximumBytes: maximumMessageBytes)
            surfaceID = message.surfaceID
            try apply(message)
            lastError = nil
        } catch {
            let validation = error as? A2UIValidationError
            let failure = A2UIValidationError(
                surfaceID: validation?.surfaceID.isEmpty == false ? validation?.surfaceID ?? surfaceID : surfaceID,
                path: validation?.path ?? "/",
                message: validation?.message ?? error.localizedDescription
            )
            lastError = failure
            onEvent?(.init(envelope: failure.envelope))
            throw failure
        }
    }

    public func receive(json: String) throws { try receive(Data(json.utf8)) }

    private func apply(_ message: A2UIMessage) throws {
        let body = message.body
        switch message.kind {
        case "createSurface":
            try body.checkKeys(["surfaceId", "catalogId", "sendDataModel", "theme"])
            guard body["catalogId"] == .string(Self.catalogID) else {
                throw A2UIValidationError(path: "/catalogId", message: "Unsupported catalog. Negotiate the Ada forms catalog.")
            }
            if let theme = body["theme"], try !theme.objectFields().isEmpty {
                throw A2UIValidationError(path: "/theme", message: "This catalog uses host styling and accepts only an empty theme.")
            }
            if let send = body["sendDataModel"], send.bool == nil {
                throw A2UIValidationError(path: "/sendDataModel", message: "Expected a boolean.")
            }
            guard surfaces[message.surfaceID] == nil, surfaces.count < maximumSurfaces else {
                throw A2UIValidationError(message: "Surface already exists or surface limit reached.")
            }
            let surface = try A2UISurface(id: message.surfaceID, sendDataModel: body["sendDataModel"]?.bool ?? false)
            surface.emit = { [weak self] event in self?.onEvent?(event) }
            surface.didChange = { [weak self] in self?.onSurfaceChanged?(message.surfaceID) }
            surfaces[message.surfaceID] = surface
            onSurfaceChanged?(message.surfaceID)
        case "deleteSurface":
            try body.checkKeys(["surfaceId"])
            let surface = try requireSurface(message.surfaceID)
            surface.deactivate()
            surfaces.removeValue(forKey: message.surfaceID)
            onSurfaceChanged?(message.surfaceID)
        case "updateComponents":
            try body.checkKeys(["surfaceId", "components"])
            let surface = try requireSurface(message.surfaceID)
            guard let values = body["components"]?.array, values.count <= maximumComponents else {
                throw A2UIValidationError(path: "/components", message: "Expected a component array within the limit.")
            }
            var candidate = surface.components
            var ids = Set<String>()
            for (index, value) in values.enumerated() {
                do {
                    let component = try A2UIComponent(value)
                    guard ids.insert(component.id).inserted else {
                        throw A2UIValidationError(path: "/id", message: "Duplicate ID in component update.")
                    }
                    candidate[component.id] = component
                } catch let failure as A2UIValidationError {
                    throw A2UIValidationError(path: "/components/\(index)" + failure.path, message: failure.message)
                }
            }
            guard candidate.count <= maximumComponents else {
                throw A2UIValidationError(path: "/components", message: "Surface component limit reached.")
            }
            try surface.update(components: candidate)
        case "updateDataModel":
            try body.checkKeys(["surfaceId", "path", "value"])
            let surface = try requireSurface(message.surfaceID)
            if let path = body["path"], path.string == nil {
                throw A2UIValidationError(path: "/path", message: "Expected a JSON Pointer string.")
            }
            let pointer = try A2UIPointer(body["path"]?.string ?? "/")
            let candidate = try pointer.replacing(in: surface.dataModel, with: body["value"])
            try surface.update(dataModel: candidate)
        default: break
        }
    }

    private func requireSurface(_ id: String) throws -> A2UISurface {
        guard let surface = surfaces[id] else { throw A2UIValidationError(message: "Surface must be created before it can be updated or deleted.") }
        return surface
    }
}

/// Mounts a surface in any AdaUI view. Creation, updates, and deletion are observed automatically.
@MainActor
public struct A2UISurfaceView: View {
    public let client: A2UIClient
    public let surfaceID: String

    public init(client: A2UIClient, surfaceID: String) {
        self.client = client
        self.surfaceID = surfaceID
    }

    public var body: some View {
        if let surface = client.surfaces[surfaceID] {
            UISceneView(session: surface.scene).id(surface.generation)
        } else {
            EmptyView()
        }
    }
}
