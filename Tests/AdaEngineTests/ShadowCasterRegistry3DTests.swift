@testable import AdaCorePipelines
import AdaEngine
@_spi(Internal) @testable import AdaRender
import Testing

@MainActor
@Suite("Shadow caster registry")
struct ShadowCasterRegistry3DTests {
    @Test("static casters use the GPU path; per-view CPU state keeps the CPU path")
    func splitsEligibleCasters() throws {
        let device = try Self.device()
        let cube = Mesh.generateCube(renderDevice: device)
        let material = PBRMaterial()
        let palette = device.createUniformBuffer(length: 64, binding: Skinning3DUniforms.binding)
        let sources = [
            Self.source(1, mesh: cube, material: material, at: [0, 0, 0]),
            Self.source(2, mesh: cube, material: material, at: [3, 0, 0], skinning: palette),
            Self.source(3, mesh: cube, material: material, at: [6, 0, 0], alternatives: [cube]),
            Self.source(4, mesh: cube, material: material, at: [9, 0, 0], maximumDistance: 20),
            Self.source(5, mesh: cube, material: material, at: [12, 0, 0], castShadows: false),
        ]
        var registry = Self.registry()
        var materials = PBR3DUniforms()
        registry.update(sources: sources, materials: &materials, identityPalette: palette, device: device)

        #expect(registry.cpuSources.map(\.entity) == [2, 3, 4], "Skinned, LOD and distance-faded casters stay on the CPU path")
        let parts = cube.models.reduce(0) { $0 + $1.parts.count }
        #expect(registry.input.casters.count == parts)
        #expect(registry.input.isValid)
        #expect(registry.groups.count == 1)
    }

    @Test("parts are grouped by draw state with consecutive segments")
    func groupsAndSegments() throws {
        let device = try Self.device()
        let cube = Mesh.generateCube(renderDevice: device)
        let singleSided = PBRMaterial()
        singleSided.doubleSided = false
        let doubleSided = PBRMaterial()
        doubleSided.doubleSided = true
        let masked = PBRMaterial()
        masked.alphaMode = .mask
        let palette = device.createUniformBuffer(length: 64, binding: Skinning3DUniforms.binding)
        var sources = [
            Self.source(1, mesh: cube, material: singleSided, at: [0, 0, 0]),
            Self.source(2, mesh: cube, material: masked, at: [3, 0, 0]),
            Self.source(3, mesh: cube, material: doubleSided, at: [6, 0, 0]),
            Self.source(4, mesh: cube, material: singleSided, at: [9, 0, 0]),
        ]
        sources[1].instances = [Mesh3DInstance(id: 7), Mesh3DInstance(id: 8, transform: Transform3D(translation: [0, 2, 0]))]
        var registry = Self.registry()
        var materials = PBR3DUniforms()
        registry.update(sources: sources, materials: &materials, identityPalette: palette, device: device)

        let input = registry.input
        #expect(input.isValid)
        #expect(registry.groups.count == 3, "Single-sided, masked and double-sided casters need different draw state")
        var next = 0
        for group in registry.groups {
            #expect(group.firstPart == next)
            next += group.partCount
        }
        #expect(next == input.parts.count)
        // Two single-sided cubes share their parts: each part draws both instances.
        let singleGroup = try #require(registry.groups.first)
        let firstPartCasters = input.casters.filter { $0.part == UInt32(singleGroup.firstPart) }
        #expect(firstPartCasters.count == 2)
        // Masked placements are culled per placement with their own bounds.
        let maskedGroup = try #require(registry.groups.first { if case .masked = $0.key { true } else { false } })
        let maskedCasters = input.casters.filter { $0.part == UInt32(maskedGroup.firstPart) }
        #expect(maskedCasters.count == 2)
        #expect(Set(maskedCasters.map(\.minimum.y)).count == 2)
    }

    @Test("unchanged scenes keep their revision; a moved caster reports its old and new bounds")
    func reportsChangedBounds() throws {
        let device = try Self.device()
        let cube = Mesh.generateCube(renderDevice: device)
        let material = PBRMaterial()
        let palette = device.createUniformBuffer(length: 64, binding: Skinning3DUniforms.binding)
        var sources = [
            Self.source(1, mesh: cube, material: material, at: [0, 0, 0]),
            Self.source(2, mesh: cube, material: material, at: [10, 0, 0]),
        ]
        var registry = Self.registry()
        var materials = PBR3DUniforms()
        registry.update(sources: sources, materials: &materials, identityPalette: palette, device: device)
        let first = registry.revision
        materials.beginFrame()
        registry.update(sources: sources, materials: &materials, identityPalette: palette, device: device)
        #expect(registry.revision == first, "Nothing changed, so nothing is uploaded or redrawn")

        sources[1] = Self.source(2, mesh: cube, material: material, at: [20, 0, 0])
        materials.beginFrame()
        registry.update(sources: sources, materials: &materials, identityPalette: palette, device: device)
        #expect(registry.revision == first &+ 1)
        let changed = try #require(registry.changedBounds)
        #expect(!changed.isEmpty)
        #expect(changed.allSatisfy { $0.center.x > 5 }, "Only the moved caster's old and new bounds are reported")
        #expect(changed.contains { abs($0.center.x - 10) < 0.01 } && changed.contains { abs($0.center.x - 20) < 0.01 })
    }

    @Test("without an identity palette every caster keeps the CPU path")
    func missingPaletteKeepsCPUPath() throws {
        let device = try Self.device()
        let cube = Mesh.generateCube(renderDevice: device)
        var registry = Self.registry()
        var materials = PBR3DUniforms()
        let sources = [Self.source(1, mesh: cube, material: PBRMaterial(), at: .zero)]
        registry.update(sources: sources, materials: &materials, identityPalette: nil, device: device)
        #expect(!registry.hasCasters)
        #expect(registry.cpuSources.map(\.entity) == [1])
    }

    @Test("added, removed and no-longer-casting casters report their bounds; material changes regroup")
    func reportsMembershipAndMaterialChanges() throws {
        let device = try Self.device()
        let cube = Mesh.generateCube(renderDevice: device)
        let material = PBRMaterial()
        let palette = device.createUniformBuffer(length: 64, binding: Skinning3DUniforms.binding)
        var registry = Self.registry()
        var materials = PBR3DUniforms()
        func update(_ sources: [Mesh3DRenderSource]) {
            materials.beginFrame()
            registry.update(sources: sources, materials: &materials, identityPalette: palette, device: device)
        }
        let first = Self.source(1, mesh: cube, material: material, at: [0, 0, 0])
        update([first])
        update([first, Self.source(2, mesh: cube, material: material, at: [30, 0, 0])])
        #expect(try #require(registry.changedBounds).allSatisfy { abs($0.center.x - 30) < 0.01 }, "Only the added caster changed")
        update([first])
        #expect(try #require(registry.changedBounds).allSatisfy { abs($0.center.x - 30) < 0.01 }, "Only the removed caster changed")
        update([first, Self.source(3, mesh: cube, material: material, at: [-30, 0, 0], castShadows: false)])
        #expect(registry.input.casters.count == cube.models.reduce(0) { $0 + $1.parts.count }, "Non-casters are not registered")

        let revision = registry.revision
        material.alphaMode = .mask
        update([first])
        #expect(registry.revision == revision &+ 1)
        #expect(registry.groups.allSatisfy { if case .masked = $0.key { true } else { false } }, "A masked material moves to a masked group")
        #expect(try #require(registry.changedBounds).contains { abs($0.center.x) < 0.01 })
    }

    @Test("pools grow by rebuilding from the source buffers and keep every part addressable")
    func poolsRebuildWhenFull() throws {
        let device = try Self.device()
        let material = PBRMaterial()
        let palette = device.createUniformBuffer(length: 64, binding: Skinning3DUniforms.binding)
        var registry = Self.registry()
        var materials = PBR3DUniforms()
        var sources: [Mesh3DRenderSource] = []
        func update() {
            materials.beginFrame()
            registry.update(sources: sources, materials: &materials, identityPalette: palette, device: device)
        }
        sources.append(Self.source(1, mesh: Mesh.generateCube(renderDevice: device), material: material, at: .zero))
        update()
        let initial = registry.pooledBytes
        #expect(initial > 0)
        // Distinct meshes each need their own pooled geometry until the first allocation is full.
        for index in 2...40 {
            sources.append(Self.source(index, mesh: Mesh.generateSphere(segments: 24, rings: 16, renderDevice: device), material: material, at: [Float(index) * 3, 0, 0]))
        }
        update()
        #expect(registry.pooledBytes > initial, "A full pool is reallocated larger")
        #expect(registry.changedBounds == nil, "Rebuilt pools move every part, so every view redraws")
        #expect(registry.isInputValid)
        let parts = registry.input.parts
        var ranges: Set<[UInt32]> = []
        for group in registry.groups {
            for part in group.firstPart..<(group.firstPart + group.partCount) {
                ranges.insert([UInt32(group.key.pool), parts[part].firstIndex])
            }
        }
        #expect(ranges.count == parts.count, "Pooled parts do not share index ranges within a pool")
        let revision = registry.revision
        update()
        #expect(registry.revision == revision, "A steady scene neither rebuilds nor re-uploads")
    }

    @Test("a scene over the pool limit keeps the CPU path without allocating pools every frame")
    func overLimitScenesAllocateNothing() throws {
        let device = try Self.device()
        let material = PBRMaterial()
        let palette = device.createUniformBuffer(length: 64, binding: Skinning3DUniforms.binding)
        var registry = Self.registry()
        registry.poolByteLimit = 1_024
        var materials = PBR3DUniforms()
        let sources = [Self.source(1, mesh: Mesh.generateSphere(segments: 24, rings: 16, renderDevice: device), material: material, at: .zero)]
        for _ in 0..<3 {
            materials.beginFrame()
            registry.update(sources: sources, materials: &materials, identityPalette: palette, device: device)
            #expect(!registry.hasCasters)
            #expect(registry.cpuSources.map(\.entity) == [1])
        }
        #expect(registry.poolAllocations == 0)
        #expect(registry.pooledBytes == 0)
    }

    private static func registry() -> ShadowCasterRegistry3D {
        var registry = ShadowCasterRegistry3D()
        registry.isEnabled = true
        registry.buildsWithoutDeviceSupport = true
        return registry
    }

    private static func source(
        _ entity: Entity.ID,
        mesh: Mesh,
        material: Material,
        at position: Vector3,
        skinning: (any UniformBuffer)? = nil,
        alternatives: [Mesh] = [],
        maximumDistance: Float? = nil,
        castShadows: Bool = true
    ) -> Mesh3DRenderSource {
        let transform = Transform3D(translation: position)
        return Mesh3DRenderSource(
            entity: entity,
            drawPass: Model3DDrawPass(),
            mesh: mesh,
            materials: [material],
            transform: transform,
            bounds: MeshVisibility3DMath.transformed(mesh.bounds, by: transform),
            alternatives: alternatives,
            maximumDistance: maximumDistance,
            castShadows: castShadows,
            skinningBuffer: skinning
        )
    }

    private static func device() throws -> RenderDevice {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        return unsafe RenderEngine.shared.renderDevice
    }
}
