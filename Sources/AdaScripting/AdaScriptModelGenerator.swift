import AdaAssets
import Foundation
import Gravity

/// Runs an agent-authored AdaScript `build(model)` function in an isolated VM and collects the parts it creates.
///
/// The script sees only the `model` builder (materials, primitives, a revolve profile, raw triangles and part
/// transforms, plus explicit joints, weights and translation/rotation clips) and the limits of
/// ``AdaScriptGeneratorRunner``. Encoding and writing the `.glb` stay with the host (see ``GLBWriter``).
@MainActor
public enum AdaScriptModelGenerator {
    public static func generate(source: String) throws -> ProceduralModel {
        let bridge = AdaScriptModelBridge()
        try AdaScriptGeneratorRunner.run(source: source, kind: "model", bridge: bridge, prelude: builderPrelude, factory: "__ada_make_model_builder")
        if let failure = bridge.failure { throw AdaScriptError.invalidManifest(failure) }
        return try bridge.result()
    }

    // Parameter validation lives in the bridge; the script-side wrapper only forwards positional values.
    private static let builderPrelude = """

        class __AdaModelBuilder {
            var __host;
            func init(host) { __host = host; }
            func material(index, red, green, blue) { return __host.setMaterialColor(index, red, green, blue); }
            func surface(index, metallic, roughness) { return __host.setSurface(index, metallic, roughness); }
            func emissive(index, red, green, blue) { return __host.setEmissive(index, red, green, blue); }
            func box(width, height, depth) { return __host.addBox(width, height, depth); }
            func plane(width, depth) { return __host.addPlane(width, depth); }
            func sphere(radius, segments) { return __host.addSphere(radius, segments); }
            func cylinder(radiusTop, radiusBottom, height, segments) { return __host.addCylinder(radiusTop, radiusBottom, height, segments); }
            func capsule(radius, height, segments) { return __host.addCapsule(radius, height, segments); }
            func torus(majorRadius, minorRadius, segments) { return __host.addTorus(majorRadius, minorRadius, segments); }
            func profile(radius, y) { return __host.addProfilePoint(radius, y); }
            func lathe(segments) { return __host.addLathe(segments); }
            func vertex(x, y, z) { return __host.addVertex(x, y, z); }
            func triangle(a, b, c) { return __host.addTriangle(a, b, c); }
            func mesh() { return __host.addMesh(); }
            func group() { return __host.addGroup(); }
            func place(id, x, y, z) { return __host.setPosition(id, x, y, z); }
            func rotate(id, x, y, z) { return __host.setRotation(id, x, y, z); }
            func scale(id, x, y, z) { return __host.setScale(id, x, y, z); }
            func paint(id, material) { return __host.setMaterial(id, material); }
            func parent(id, parentId) { return __host.setParent(id, parentId); }
            func name(id, text) { return __host.setName(id, text); }
            func partCount() { return __host.partCount(); }
            func partName(id) { return __host.partName(id); }
            func partParent(id) { return __host.partParent(id); }
            func hasMesh(id) { return __host.partHasMesh(id); }
            func vertexCount(id) { return __host.partVertexCount(id); }
            func vertexPosition(id, vertex, axis) { return __host.rigVertexPosition(id, vertex, axis); }
            func joint(name, parent, x, y, z) { return __host.rigJoint(name, parent, [x, y, z]); }
            func bind(part, joint) { return __host.rigBind(part, joint); }
            func weights(part, vertex, first, firstWeight, second, secondWeight) { return __host.rigWeights(part, vertex, [first, firstWeight, second, secondWeight]); }
            func clip(name) { return __host.rigClip(name); }
            func rotationKey(clip, joint, time, x, y, z) { return __host.rigRotationKey(clip, joint, [time, x, y, z]); }
            func translationKey(clip, joint, time, x, y, z) { return __host.rigTranslationKey(clip, joint, [time, x, y, z]); }
        }
        func __ada_make_model_builder(host) { return __AdaModelBuilder(host); }
        """
}

// Only the owning main-actor generator touches this bridge, inside the shared VM lock.
@GSExportable("AdaModelBuilderHost")
final class AdaScriptModelBridge {
    @GSExportableIgnore private static let maximumNodes = 512
    @GSExportableIgnore private static let maximumVertices = 200_000
    @GSExportableIgnore private static let maximumProfilePoints = 256
    @GSExportableIgnore private static let maximumCustomVertices = 20_000
    @GSExportableIgnore private static let maximumCustomTriangles = 40_000

    @GSExportableIgnore var failure: String?
    @GSExportableIgnore private var nodes: [ProceduralNode] = []
    @GSExportableIgnore private var materials: [Int: ProceduralMaterial] = [:]
    @GSExportableIgnore private var profile: [SIMD2<Float>] = []
    @GSExportableIgnore private var vertices: [SIMD3<Float>] = []
    @GSExportableIgnore private var triangles: [SIMD3<Int>] = []
    @GSExportableIgnore private var vertexCount = 0
    @GSExportableIgnore private var rig: AdaScriptModelRigBuilder?

    init() {}

    @GSExportableIgnore
    func result() throws -> ProceduralModel {
        guard nodes.contains(where: { $0.mesh != nil }) else {
            throw AdaScriptError.invalidManifest("The script created no geometry; call model.box, sphere, cylinder, lathe, mesh or another shape.")
        }
        let used = Array(Set(nodes.filter { $0.mesh != nil }.map(\.material))).sorted()
        var remapped = nodes
        for index in remapped.indices where remapped[index].mesh != nil {
            remapped[index].material = used.firstIndex(of: remapped[index].material) ?? 0
        }
        let source = ProceduralModel(materials: used.map { materials[$0] ?? Self.defaultMaterial($0) }, nodes: remapped)
        return try rig?.finish(source) ?? source
    }

    // MARK: - Materials

    func setMaterialColor(index: GSValue, red: GSValue, green: GSValue, blue: GSValue) -> Bool {
        guard let index = materialIndex(index), let red = unit(red), let green = unit(green), let blue = unit(blue) else {
            return fail("model.material expects an index in 0...63 and red, green, blue in 0...1.")
        }
        var material = materials[index] ?? Self.defaultMaterial(index)
        material.baseColor = SIMD4(red, green, blue, 1)
        materials[index] = material
        return true
    }

    func setSurface(index: GSValue, metallic: GSValue, roughness: GSValue) -> Bool {
        guard let index = materialIndex(index), let metallic = unit(metallic), let roughness = unit(roughness) else {
            return fail("model.surface expects an index in 0...63 and metallic, roughness in 0...1.")
        }
        var material = materials[index] ?? Self.defaultMaterial(index)
        material.metallic = metallic
        material.roughness = roughness
        materials[index] = material
        return true
    }

    func setEmissive(index: GSValue, red: GSValue, green: GSValue, blue: GSValue) -> Bool {
        guard let index = materialIndex(index), let red = unit(red), let green = unit(green), let blue = unit(blue) else {
            return fail("model.emissive expects an index in 0...63 and red, green, blue in 0...1.")
        }
        var material = materials[index] ?? Self.defaultMaterial(index)
        material.emissive = SIMD3(red, green, blue)
        materials[index] = material
        return true
    }

    // MARK: - Shapes

    func addBox(width: GSValue, height: GSValue, depth: GSValue) -> Int {
        guard let width = length(width), let height = length(height), let depth = length(depth) else {
            return failed("model.box expects a positive width, height and depth.")
        }
        return add("Box", ProceduralGeometry.box(width: width, height: height, depth: depth))
    }

    func addPlane(width: GSValue, depth: GSValue) -> Int {
        guard let width = length(width), let depth = length(depth) else { return failed("model.plane expects a positive width and depth.") }
        return add("Plane", ProceduralGeometry.plane(width: width, depth: depth))
    }

    func addSphere(radius: GSValue, segments: GSValue) -> Int {
        guard let radius = length(radius), let segments = segmentCount(segments) else {
            return failed("model.sphere expects a positive radius and segments in 3...64.")
        }
        return add("Sphere", ProceduralGeometry.sphere(radius: radius, segments: segments))
    }

    func addCylinder(radiusTop: GSValue, radiusBottom: GSValue, height: GSValue, segments: GSValue) -> Int {
        guard let top = length(radiusTop, allowZero: true), let bottom = length(radiusBottom, allowZero: true), top + bottom > 0,
            let height = length(height), let segments = segmentCount(segments)
        else {
            return failed("model.cylinder expects non-negative radii (not both zero), a positive height and segments in 3...64.")
        }
        return add("Cylinder", ProceduralGeometry.cylinder(radiusTop: top, radiusBottom: bottom, height: height, segments: segments))
    }

    func addCapsule(radius: GSValue, height: GSValue, segments: GSValue) -> Int {
        guard let radius = length(radius), let height = length(height), height >= 2 * radius, let segments = segmentCount(segments) else {
            return failed("model.capsule expects a positive radius, a total height of at least twice the radius and segments in 3...64.")
        }
        return add("Capsule", ProceduralGeometry.capsule(radius: radius, height: height, segments: segments))
    }

    func addTorus(major: GSValue, minor: GSValue, segments: GSValue) -> Int {
        guard let major = length(major), let minor = length(minor), minor < major, let segments = segmentCount(segments) else {
            return failed("model.torus expects a major radius larger than the positive minor radius and segments in 3...64.")
        }
        return add("Torus", ProceduralGeometry.torus(majorRadius: major, minorRadius: minor, segments: segments))
    }

    func addProfilePoint(radius: GSValue, y: GSValue) -> Bool {
        guard let radius = radius.finiteNumber, radius >= 0, let y = y.finiteNumber, profile.count < Self.maximumProfilePoints else {
            return fail("model.profile expects a non-negative radius and a y; a lathe profile has at most \(Self.maximumProfilePoints) points.")
        }
        profile.append(SIMD2(Float(radius), Float(y)))
        return true
    }

    func addLathe(segments: GSValue) -> Int {
        guard let segments = segmentCount(segments) else { return failed("model.lathe expects segments in 3...64.") }
        defer { profile = [] }
        let mesh = ProceduralGeometry.lathe(profile: profile, segments: segments)
        guard !mesh.isEmpty else { return failed("model.lathe needs at least two distinct model.profile points with a positive radius.") }
        return add("Lathe", mesh)
    }

    func addVertex(x: GSValue, y: GSValue, z: GSValue) -> Int {
        guard let x = x.finiteNumber, let y = y.finiteNumber, let z = z.finiteNumber, vertices.count < Self.maximumCustomVertices else {
            return failed("model.vertex expects three numbers; a custom mesh has at most \(Self.maximumCustomVertices) vertices.")
        }
        vertices.append(SIMD3(Float(x), Float(y), Float(z)))
        return vertices.count - 1
    }

    func addTriangle(a: GSValue, b: GSValue, c: GSValue) -> Bool {
        guard let a = vertexIndex(a), let b = vertexIndex(b), let c = vertexIndex(c), triangles.count < Self.maximumCustomTriangles else {
            return fail("model.triangle expects three indices returned by model.vertex; a custom mesh has at most \(Self.maximumCustomTriangles) triangles.")
        }
        triangles.append(SIMD3(a, b, c))
        return true
    }

    func addMesh() -> Int {
        defer {
            vertices = []
            triangles = []
        }
        let mesh = ProceduralGeometry.flat(vertices: vertices, triangles: triangles)
        guard !mesh.isEmpty else { return failed("model.mesh needs at least one non-degenerate model.triangle.") }
        return add("Mesh", mesh)
    }

    func addGroup() -> Int {
        guard rig == nil else { return failed("Finish geometry before starting rig authoring.") }
        guard nodes.count < Self.maximumNodes else { return failed("A model has at most \(Self.maximumNodes) parts.") }
        nodes.append(ProceduralNode(name: "Group \(nodes.count)"))
        return nodes.count - 1
    }

    // MARK: - Part properties

    func setPosition(id: GSValue, x: GSValue, y: GSValue, z: GSValue) -> Bool {
        guard rig == nil else { return fail("Geometry transforms are frozen during rig authoring.") }
        guard let id = nodeIndex(id), let x = x.finiteNumber, let y = y.finiteNumber, let z = z.finiteNumber else {
            return fail("model.place expects a part id and x, y, z numbers.")
        }
        nodes[id].translation = SIMD3(Float(x), Float(y), Float(z))
        return true
    }

    func setRotation(id: GSValue, x: GSValue, y: GSValue, z: GSValue) -> Bool {
        guard rig == nil else { return fail("Geometry transforms are frozen during rig authoring.") }
        guard let id = nodeIndex(id), let x = x.finiteNumber, let y = y.finiteNumber, let z = z.finiteNumber else {
            return fail("model.rotate expects a part id and x, y, z angles in degrees.")
        }
        nodes[id].rotation = ProceduralMath.quaternion(eulerDegrees: SIMD3(Float(x), Float(y), Float(z)))
        return true
    }

    func setScale(id: GSValue, x: GSValue, y: GSValue, z: GSValue) -> Bool {
        guard rig == nil else { return fail("Geometry transforms are frozen during rig authoring.") }
        guard let id = nodeIndex(id), let x = length(x), let y = length(y), let z = length(z) else {
            return fail("model.scale expects a part id and positive x, y, z factors; mirroring is not supported.")
        }
        nodes[id].scale = SIMD3(x, y, z)
        return true
    }

    func setMaterial(id: GSValue, material: GSValue) -> Bool {
        guard let id = nodeIndex(id), let material = materialIndex(material) else {
            return fail("model.paint expects a part id and a material index in 0...63.")
        }
        nodes[id].material = material
        return true
    }

    func setParent(id: GSValue, parent: GSValue) -> Bool {
        guard rig == nil else { return fail("Geometry parents are frozen during rig authoring.") }
        guard let id = nodeIndex(id), let parent = nodeIndex(parent), parent < id else {
            return fail("model.parent expects two part ids, and the parent must have been created before the child.")
        }
        nodes[id].parent = parent
        return true
    }

    func setName(id: GSValue, text: GSValue) -> Bool {
        guard rig == nil else { return fail("Geometry names are frozen during rig authoring.") }
        guard let id = nodeIndex(id), text.isString else { return fail("model.name expects a part id and a string.") }
        let name = String(text.toString.prefix(64)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return fail("model.name expects a non-empty string.") }
        nodes[id].name = name
        return true
    }

    // MARK: - Interpreted rig authoring

    func partCount() -> Int { nodes.count }
    func partName(id: GSValue) -> String {
        guard let index = nodeIndex(id) else { _ = fail("Invalid part id"); return "" }
        return nodes[index].name
    }
    func partParent(id: GSValue) -> Int {
        guard let index = nodeIndex(id) else { return failed("Invalid part id") }
        return nodes[index].parent ?? -1
    }
    func partHasMesh(id: GSValue) -> Bool {
        guard let index = nodeIndex(id) else { return fail("Invalid part id") }
        return nodes[index].mesh != nil
    }
    func partVertexCount(id: GSValue) -> Int {
        guard let index = nodeIndex(id) else { return failed("Invalid part id") }
        return nodes[index].mesh?.positions.count ?? 0
    }
    func rigJoint(name: GSValue, parent: GSValue, position: GSValue) -> Int {
        rigCall(-1) { try $0.scriptJoint(name, parent, position) }
    }
    func rigBind(part: GSValue, joint: GSValue) -> Bool { rigCall(false) { try $0.bind(part: $0.index(part), joint: $0.index(joint)) } }
    func rigVertexPosition(part: GSValue, vertex: GSValue, axis: GSValue) -> Double {
        rigCall(0) { try $0.position(part: $0.index(part), vertex: $0.index(vertex), axis: $0.index(axis)) }
    }
    func rigWeights(part: GSValue, vertex: GSValue, values: GSValue) -> Bool {
        rigCall(false) { try $0.scriptWeights(part, vertex, values) }
    }
    func rigClip(name: GSValue) -> Int { rigCall(-1) { try $0.addClip(name: $0.text(name)) } }
    func rigRotationKey(clip: GSValue, joint: GSValue, values: GSValue) -> Bool {
        rigCall(false) { try $0.scriptKey(clip, joint, values, rotation: true) }
    }
    func rigTranslationKey(clip: GSValue, joint: GSValue, values: GSValue) -> Bool {
        rigCall(false) { try $0.scriptKey(clip, joint, values, rotation: false) }
    }

    // MARK: - Helpers

    @GSExportableIgnore
    private func rigCall<T>(_ fallback: T, _ action: (AdaScriptModelRigBuilder) throws -> T) -> T {
        do {
            if rig == nil { rig = try AdaScriptModelRigBuilder(nodes: nodes) }
            guard let rig else { return fallback }
            return try action(rig)
        } catch {
            _ = fail(error.localizedDescription)
            return fallback
        }
    }

    @GSExportableIgnore
    private static func defaultMaterial(_ index: Int) -> ProceduralMaterial {
        ProceduralMaterial(name: index == 0 ? "Default" : "Material \(index)")
    }

    @GSExportableIgnore
    private func add(_ name: String, _ mesh: ProceduralMeshData) -> Int {
        guard rig == nil else { return failed("Finish geometry before starting rig authoring.") }
        guard nodes.count < Self.maximumNodes else { return failed("A model has at most \(Self.maximumNodes) parts.") }
        guard vertexCount + mesh.positions.count <= Self.maximumVertices else {
            return failed("A model has at most \(Self.maximumVertices) vertices; use fewer segments or fewer parts.")
        }
        vertexCount += mesh.positions.count
        nodes.append(ProceduralNode(name: "\(name) \(nodes.count)", mesh: mesh))
        return nodes.count - 1
    }

    @GSExportableIgnore
    private func fail(_ message: String) -> Bool {
        failure = failure ?? message
        return false
    }

    @GSExportableIgnore
    private func failed(_ message: String) -> Int {
        _ = fail(message)
        return -1
    }

    @GSExportableIgnore
    private func wholeNumber(_ value: GSValue) -> Int? {
        guard let number = value.finiteNumber, number == number.rounded(), abs(number) <= 1_000_000 else { return nil }
        return Int(number)
    }

    @GSExportableIgnore
    private func nodeIndex(_ value: GSValue) -> Int? {
        wholeNumber(value).flatMap { nodes.indices.contains($0) ? $0 : nil }
    }

    @GSExportableIgnore
    private func vertexIndex(_ value: GSValue) -> Int? {
        wholeNumber(value).flatMap { vertices.indices.contains($0) ? $0 : nil }
    }

    @GSExportableIgnore
    private func materialIndex(_ value: GSValue) -> Int? {
        wholeNumber(value).flatMap { (0...63).contains($0) ? $0 : nil }
    }

    @GSExportableIgnore
    private func segmentCount(_ value: GSValue) -> Int? {
        wholeNumber(value).flatMap { (3...64).contains($0) ? $0 : nil }
    }

    @GSExportableIgnore
    private func unit(_ value: GSValue) -> Float? {
        value.finiteNumber.flatMap { (0...1).contains($0) ? Float($0) : nil }
    }

    @GSExportableIgnore
    private func length(_ value: GSValue, allowZero: Bool = false) -> Float? {
        value.finiteNumber.flatMap { (allowZero ? $0 >= 0 : $0 > 0) && $0 <= 1000 ? Float($0) : nil }
    }
}
