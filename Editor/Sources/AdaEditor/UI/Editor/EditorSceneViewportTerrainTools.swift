@_spi(AdaEngine) import AdaEngine
import Foundation
import Math

extension EditorSceneViewportModel {
    func refreshTerrainSourceControls() {
        terrainEditing.sourceActions = .init(
            create: { [weak self] in self?.createTerrainSource() },
            materials: { [weak self] in self?.configureTerrainMaterials() },
            variation: { [weak self] in self?.configureTerrainMaterials(addRules: false) },
            mesh: { [weak self] in self?.registerTerrainMesh() },
            texture: { [weak self] in self?.registerTerrainTexture() },
            extend: { [weak self] in
                guard let self else {
                    return
                }
                let x = (self.terrainEditing.sourceManifest?.heightRegions.map { Int($0.x) }.max() ?? 0)
                self.performTerrainResourceCommand(.region(.init(x: x, z: 0)))
            },
            generate: { [weak self] in
                guard let self, !self.terrainEditing.isSourceBusy, !self.rejectHeightfieldTool() else {
                    return
                }
                if self.terrainEditing.sourceManifest == nil, self.terrainSourceEntity(for: self.selectedEditorID) == nil {
                    self.createTerrainSource()
                } else {
                    self.performTerrainResourceCommand(.generate(self.terrainEditing.noise))
                }
            },
            join: { [weak self] in self?.joinSelectedMeshTerrain() },
            detach: { [weak self] in self?.detachSelectedMeshTerrain() },
            cancel: { [weak self] in
                guard let self else { return }
                if !self.cancelActiveMeshTerrainTransform() { self.endTerrainStroke(cancelled: true) }
            }
        )
        refreshMeshTerrainControls()
        guard let context = terrainSourceContext else {
            return
        }
        let selection = selectedEditorID
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let metadata = try? await context.application.withWorldAccess { () -> (TerrainManifestAsset?, String?) in
                if let entity = self.terrainSourceEntity(for: selection), let owner = self.runtimeEntity(for: entity.id),
                    let resources = owner.components[MeshTerrain3DSourceResources.self] {
                    return (resources.manifest, owner.components[Terrain3DSource.self]?.source)
                }
                let hit = self.selectedTerrainSourceHit(for: selection)
                let source = hit.flatMap { try? EditorTerrainSourcePayload.decode($0.payload).source }
                return (hit?.surface.manifest, source)
            }
            guard self.selectedEditorID == selection, self.terrainSourceContext?.application === context.application,
                self.terrainSourceContext?.assetsRoot == context.assetsRoot else { return }
            self.terrainEditing.sourceManifest = metadata?.0
            self.terrainEditing.sourceAssetFolder = metadata?.1.flatMap {
                try? EditorTerrainResource.resolve($0, sourceURL: context.assetsRoot.appendingPathComponent("scene.ascn"), resourceRootURL: context.assetsRoot)
                    .deletingLastPathComponent()
            }
            if let palette = metadata?.0?.materials {
                if !palette.layers.contains(where: { $0.id == self.terrainEditing.sourceLayerID }) {
                    self.terrainEditing.sourceLayerID = palette.fallbackLayerID
                }
                self.terrainEditing.usesTextureVariation = palette.layers.allSatisfy { $0.variation.isEnabled }
            }
            if let first = metadata?.0?.meshPrototypes.first { self.terrainEditing.sourcePrototypeID = first.id }
        }
    }

    func makeTerrainSourceCommand(at point: Vector3) -> EditorTerrainStrokeCommand {
        let points: [TerrainBrushPoint] = [.init(position: point, time: 0), .init(position: point, time: 1 / 60)]
        switch terrainEditing.sourceTool {
        case .sculpt:
            let preset = EditorTerrainBrushPreset.all.first { $0.name == terrainEditing.sourcePresetName }
            let operation: TerrainHeightBrushOperation
            switch terrainEditing.mode {
            case .raise: operation = .raise
            case .lower: operation = .lower
            case .smooth: operation = .smooth
            case .flatten: operation = .flatten
            }
            var settings = TerrainHeightBrushSettings(operation: preset?.operation ?? operation, radius: terrainEditing.radius, strength: terrainEditing.strength)
            settings.shape = preset?.shape ?? .softRound
            settings.targetHeight = point.y
            settings.terraceStep = preset?.step ?? 1
            settings.seed = terrainEditing.noise.seed
            settings.noiseAmplitude = terrainEditing.strength
            return .height(.init(settings: settings, points: points))
        case .paint, .erasePaint:
            var settings = TerrainSurfaceBrushSettings(
                operation: terrainEditing.sourceTool == .paint ? .paintLayer : .eraseLayer,
                radius: terrainEditing.radius,
                strength: terrainEditing.strength
            )
            settings.layerID = terrainEditing.sourceLayerID
            return .surface(.init(settings: settings, points: points))
        case .scatter, .eraseMeshes:
            var settings = TerrainInstanceBrushSettings(
                prototypeID: terrainEditing.sourcePrototypeID,
                operation: terrainEditing.sourceTool == .scatter ? .paint : .erase,
                radius: terrainEditing.radius,
                density: Float(terrainEditing.meshDensity)
            )
            settings.seed = terrainEditing.noise.seed
            settings.minimumDistance = 0.8
            return .instances(.init(settings: settings, points: points))
        case .add, .subtract:
            let operand: TerrainVolumeOperand
            switch terrainEditing.volumeOperand {
            case "Box": operand = .primitive(.box(halfExtents: .one))
            case "Capsule": operand = .primitive(.capsule(radius: 1, halfHeight: 2))
            case "Palette mesh": operand = terrainEditing.sourceManifest?.meshPrototypes.first(where: { $0.id == terrainEditing.sourcePrototypeID })
                .map { .mesh(assetPath: $0.assetPath, scene: $0.scene) } ?? .primitive(.sphere(radius: 1))
            default: operand = .primitive(.sphere(radius: 1))
            }
            return .volume(.init(
                operation: terrainEditing.sourceTool == .add ? .union : .subtract,
                operand: operand,
                transform: .init(translation: point, rotation: .identity, scale: Vector3(terrainEditing.radius))
            ))
        }
    }

    private func configureTerrainMaterials(addRules: Bool = true) {
        let variation = TerrainTextureVariation(isEnabled: terrainEditing.usesTextureVariation, seed: terrainEditing.noise.seed)
        let palette = EditorTerrainAutoPalette.make(existing: terrainEditing.sourceManifest?.materials, variation: variation, addRules: addRules)
        performTerrainResourceCommand(.materials(palette))
    }

    private func registerTerrainMesh() {
        guard !terrainEditing.isSourceBusy else { return }
        if let file = terrainProjectFile(terrainEditing.meshReference) {
            performTerrainResourceCommand(.mesh(file))
            return
        }
        let selection = selectedEditorID, context = terrainSourceContext
        Task { @MainActor [weak self] in
            guard let file = await ProjectOpenPicker.pickAssetImportURLs()?.first, let self,
                self.selectedEditorID == selection, self.terrainSourceContext?.application === context?.application,
                self.terrainSourceContext?.assetsRoot == context?.assetsRoot else {
                return
            }
            self.performTerrainResourceCommand(.mesh(file))
        }
    }

    private func registerTerrainTexture() {
        guard !terrainEditing.isSourceBusy else { return }
        let used = Set(terrainEditing.sourceManifest?.materials?.layers.map(\.id) ?? [])
        guard let id = (UInt16(0)...UInt16(31)).first(where: { !used.contains($0) }) else {
            return
        }
        terrainEditing.sourceLayerID = id
        if let file = terrainProjectFile(terrainEditing.textureReference) {
            performTerrainResourceCommand(.texture(file, layerID: id))
            return
        }
        let selection = selectedEditorID, context = terrainSourceContext
        Task { @MainActor [weak self] in
            guard let file = await ProjectOpenPicker.pickAssetImportURLs()?.first, let self,
                self.selectedEditorID == selection, self.terrainSourceContext?.application === context?.application,
                self.terrainSourceContext?.assetsRoot == context?.assetsRoot else {
                return
            }
            self.performTerrainResourceCommand(.texture(file, layerID: id))
        }
    }

    private func terrainProjectFile(_ reference: String) -> URL? {
        guard let context = terrainSourceContext, !reference.isEmpty else {
            return nil
        }
        let relative = reference.hasPrefix("@res://") ? String(reference.dropFirst(7)) : reference
        let root = context.assetsRoot.resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: file.path) else {
            return nil
        }
        return file
    }

    private func rejectHeightfieldTool() -> Bool {
        guard isMeshTerrainSource(for: selectedEditorID) else { return false }
        terrainEditing.sourceFailure = nil
        terrainEditing.sourceStatus = "Choose a Heightfield for this tool."
        return true
    }

    func performTerrainResourceCommand(_ command: EditorTerrainStrokeCommand) {
        guard !terrainEditing.isSourceBusy, let context = terrainSourceContext else {
            return
        }
        if isMeshTerrainSource(for: selectedEditorID) {
            switch command {
            case .materials, .mesh, .texture: performMeshTerrainResources(command)
            default: _ = rejectHeightfieldTool()
            }
            return
        }
        let selection = selectedEditorID
        terrainEditing.sourceGeneration = UUID()
        let generation = terrainEditing.sourceGeneration
        terrainEditing.isSourceBusy = true
        terrainEditing.sourceFailure = nil
        terrainEditing.sourceTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer { self.finishSourceTerrainTask(generation: generation) }
            do {
                guard let hit = try await context.application.withWorldAccess({ self.selectedTerrainSourceHit(for: selection) }) else {
                    throw EditorTerrainSourceAuthoring.Failure.unavailable
                }
                try await self.runTerrainSourceCommand(command, hit: hit, generation: generation)
            } catch {
                if self.terrainEditing.sourceGeneration == generation { self.terrainEditing.sourceStatus = "Terrain stroke could not be saved. Try again." }
            }
        }
    }

    private func createTerrainSource() {
        guard !terrainEditing.isSourceBusy, let context = terrainSourceContext, let baseline = sceneModel else {
            return
        }
        let settings = terrainEditing.noise
        let backend = terrainEditing.creationBackend
        terrainEditing.sourceGeneration = UUID()
        let generation = terrainEditing.sourceGeneration
        terrainEditing.isSourceBusy = true
        terrainEditing.sourceTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer { self.finishSourceTerrainTask(generation: generation) }
            var meshReceipt: EditorMeshTerrainCreation.Receipt?
            do {
                let file = context.assetsRoot.appendingPathComponent("terrain-\(UUID().uuidString.lowercased()).aterrain")
                if backend == .mesh { meshReceipt = try await EditorMeshTerrainCreation.create(at: file, noise: settings) }
                else { try await Self.writeNewTerrain(at: file, noise: settings) }
                guard !Task.isCancelled, self.terrainEditing.sourceGeneration == generation, self.sceneModel == baseline else {
                    if let meshReceipt { await EditorMeshTerrainCreation.discard(meshReceipt) }
                    return
                }
                var model = baseline
                let parent = model.entities.first(where: { $0.name == "Environment" })?.id ?? model.addEntity(name: "Environment", parentID: nil).id
                let id = model.addEntity(name: L10n.tr(backend == .mesh ? "Mesh Terrain" : "Terrain"), parentID: parent).id
                model.addComponent(typeName: EditorBuiltInComponentType.visibility, to: id)
                guard let index = model.entities.firstIndex(where: { $0.id == id }) else {
                    if let meshReceipt { await EditorMeshTerrainCreation.discard(meshReceipt) }
                    return
                }
                model.entities[index].components[EditorBuiltInComponentType.terrain3DSource] = EditorTerrainSourcePayload.encode(
                    Terrain3DSource(source: "@res://" + file.lastPathComponent, streamingRadius: nil, queries: .init())
                )
                if backend == .mesh {
                    let identity = MeshTerrain3DIdentity()
                    model.entities[index].components[String(reflecting: MeshTerrain3DIdentity.self)] = ["id": .string(identity.id.uuidString)]
                }
                model.editor?.selectedEntity = id
                self.sceneModel = model
                self.selectedEditorID = id
                self.publishTerrainDocument()
                meshReceipt = nil
                _ = self.reloadSceneRuntimeIfReady()
                self.refreshTerrainSourceControls()
            } catch {
                if let meshReceipt { await EditorMeshTerrainCreation.discard(meshReceipt) }
                if !(error is CancellationError), self.terrainEditing.sourceGeneration == generation {
                    self.terrainEditing.sourceStatus = "Terrain stroke could not be saved. Try again."
                }
            }
        }
    }

    @concurrent
    private static func writeNewTerrain(at file: URL, noise: EditorTerrainNoise) async throws {
        var terrain = Terrain3D(resolution: 129, size: 128)
        for z in 0..<129 {
            try Task.checkCancellation()
            for x in 0..<129 { terrain.heights[z * 129 + x] = noise.height(x: Float(x) - 64, z: Float(z) - 64) }
        }
        let storage = try TerrainHeightStorage(importing: terrain)
        var regions: [TerrainRegionAsset] = []
        for coordinate in storage.resourceCoordinates {
            if let region = try storage.regionAsset(at: coordinate) { regions.append(region) }
        }
        _ = try await AssetsManager.saveTerrainRegions(regions, manifest: .init(spacing: 1, originX: -64, originZ: -64), at: file.path)
    }
}
