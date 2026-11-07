import AdaECS
import AdaRender
import AdaUtils

/// A shared static mesh/material table with placements; terrain uses one component per spatial cell.
/// Instance records do not create authored ECS entities.
public struct Mesh3DInstancesComponent: Component {
    public var mesh: Mesh { didSet { extractionRevision = RID() } }
    public var materials: [Material] { didSet { extractionRevision = RID() } }
    public var instances: [Mesh3DInstance] { didSet { extractionRevision = RID() } }
    public var castShadows: Bool { didSet { extractionRevision = RID() } }
    public var receiveShadows: Bool { didSet { extractionRevision = RID() } }
    private(set) var extractionRevision = RID()

    public init(mesh: Mesh, materials: [Material], instances: [Mesh3DInstance], castShadows: Bool = true, receiveShadows: Bool = true) {
        self.mesh = mesh
        self.materials = materials
        self.instances = instances
        self.castShadows = castShadows
        self.receiveShadows = receiveShadows
    }
}
