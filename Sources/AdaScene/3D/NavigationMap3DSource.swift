import AdaAssets
import AdaECS
import AdaNavigation
import Foundation

/// Loads one baked navigation map for this world. Removing the selected source
/// releases only the map installed by this system; externally supplied maps survive.
/// Multiple enabled sources are rejected rather than selecting an arbitrary map.
@Component
public struct NavigationMap3DSource: Codable, Sendable {
    public var source: String = ""
    public internal(set) var status: String = "idle"
    public internal(set) var errorCode: String = ""
    public internal(set) var errorMessage: String = ""
    public internal(set) var polygonCount: Int = 0

    public init(source: String = "") { self.source = source }

    private enum CodingKeys: CodingKey { case source }
    public init(from decoder: any Decoder) throws {
        source = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .source) ?? ""
    }
}

@PlainSystem
public struct NavigationMap3DSourceSystem {
    @Query<Entity, Ref<NavigationMap3DSource>> private var sources
    @Commands private var commands
    @Local private var selection: NavigationSourceSelection?

    public init(world _: World) {}

    public func update(context _: UpdateContext) async {
        var candidates: [NavigationSourceSelection] = []
        sources.forEach { entity, source in
            if entity.isActive, !source.source.isEmpty {
                candidates.append(.init(entityID: entity.id, source: source.source))
            }
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            if selection != nil {
                commands.queue.push { world in removeOwnedNavigationMap(in: world) }
            }
            selection = nil
            let status = candidates.count > 1 ? "failed" : "idle"
            let error = candidates.count > 1 ? "multipleSources" : ""
            sources.forEach { entity, _ in
                guard var value = entity.components[NavigationMap3DSource.self],
                    value.status != status || value.errorCode != error || value.polygonCount != 0 else { return }
                value.status = status
                value.errorCode = error
                value.errorMessage = ""
                value.polygonCount = 0
                entity.components[NavigationMap3DSource.self] = value
            }
            return
        }
        guard selection != candidate else { return }
        selection = candidate
        let result: Result<NavigationMap3D, AssetError>
        do {
            guard let asset = try await AssetsManager.load(NavigationMeshAsset.self, at: candidate.source).asset else {
                throw AssetError.message("Navigation asset did not load.")
            }
            result = .success(NavigationMap3D(mesh: try NavigationMesh(data: asset.data)))
        } catch {
            result = .failure(.message(error.localizedDescription))
        }
        commands.queue.push { world in
            guard let entity = world.getEntityByID(candidate.entityID), entity.isActive,
                var source = entity.components[NavigationMap3DSource.self], source.source == candidate.source else { return }
            removeOwnedNavigationMap(in: world)
            switch result {
            case let .success(map):
                world.insertResource(map)
                world.insertResource(NavigationMapSourceOwnership(revision: map.revision))
                source.status = "ready"
                source.errorCode = ""
                source.errorMessage = ""
                source.polygonCount = map.mesh.data.polygonCount
            case let .failure(error):
                source.status = "failed"
                source.errorCode = "assetLoadFailed"
                source.errorMessage = error.localizedDescription
                source.polygonCount = 0
            }
            entity.components[NavigationMap3DSource.self] = source
        }
    }
}

private struct NavigationSourceSelection: Equatable, Sendable {
    let entityID: Entity.ID
    let source: String
}

private struct NavigationMapSourceOwnership: Resource {
    let revision: UUID
}

private func removeOwnedNavigationMap(in world: World) {
    guard let owner = world.getResource(NavigationMapSourceOwnership.self) else { return }
    if world.getResource(NavigationMap3D.self)?.revision == owner.revision {
        world.removeResource(NavigationMap3D.self)
    }
    world.removeResource(NavigationMapSourceOwnership.self)
}
