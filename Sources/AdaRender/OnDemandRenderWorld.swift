import AdaApp
import AdaAssets
import AdaECS
import AdaTransform
import AdaUtils
import Math

/// Work owned by a built-in plugin that must be collected before deciding whether to extract a render snapshot.
package struct RenderFrameWork: Resource {
    private var collectors: [@MainActor @Sendable (World) -> Bool] = []

    @MainActor
    package static func register(in world: World, _ collect: @escaping @MainActor @Sendable (World) -> Bool) {
        world.getOrInitRefResource(Self.self, constructor: { Self() }).collectors.append(collect)
    }

    @MainActor
    func collect(in world: World) -> Bool {
        var needsUpdate = false
        for collect in collectors where collect(world) {
            needsUpdate = true
        }
        return needsUpdate
    }
}

#if os(macOS) && SAGA_METAL && canImport(SAGACompiler)
    /// Accessed at the extraction boundary, after the preceding render update has joined.
    final class OnDemandRenderWorld {
        private let cameras = Query<Entity, Ref<Camera>>()
        private var previousWindows: RenderWindows?
        private var previousOnDemandTargets: [Entity.ID: WindowID] = [:]
        private var onDemandTargets: [Entity.ID: WindowID] = [:]
        private var previouslyHadContinuousCamera = false

        @MainActor
        static func needsUpdate(from main: World, to subworld: AppWorlds) -> Bool {
            let render = subworld.main
            guard subworld.updateScheduler == .renderRunner,
                  let surfaces = render.getResource(WindowSurfaces.self),
                  surfaces.allowsWindowRendering, surfaces.allowedWindowIDs == nil,
                  let engine = render.getResource(RenderEngineHandler.self)?.renderEngine,
                  engine.supportsDeferredWindowFrames,
                  !render.schedulers.hasUnclassifiedWork,
                  let graph = render.getResource(RenderGraph.self), graph.allowsDeferredSnapshots,
                  render.getResource(RenderGraphDiagnostics.self)?.isEnabled != true,
                  main.getResource(WindowFrameRequests.self)?.hasOnDemandWindows == true,
                  let windows = try? engine.getRenderWindows()
            else {
                return true
            }
            return surfaces.onDemand.needsUpdate(main: main, render: render, surfaces: surfaces, graph: graph, windows: windows)
        }

        @MainActor
        private func needsUpdate(
            main: World,
            render: World,
            surfaces: WindowSurfaces,
            graph: RenderGraph,
            windows: RenderWindows
        ) -> Bool {
            let hasFrameWork = main.getResource(RenderFrameWork.self)?.collect(in: main) == true
            guard var requests = main.getResource(WindowFrameRequests.self) else {
                return true
            }
            requests.clearCameraModes()
            let primary = main.getResource(PrimaryWindowId.self)
            let continuous = collectCameras(from: main, graph: graph, windows: windows, primary: primary, requests: &requests)
            let cameraModeChanged = continuous != previouslyHadContinuousCamera
            previouslyHadContinuousCamera = continuous
            var windowChanged = previousWindows?.windows.count != windows.windows.count
            for (id, window) in windows.windows.values where previousWindows?.windows.firstValue(for: id) != window {
                requests.requestedWindowIDs.insert(id)
                windowChanged = true
            }
            previousWindows = windows

            let retiringTextures = render.getResource(ExtractedCameraRenderViewTargets.self)?
                .targets.values.contains(where: { !$0.retiredFrameTextures.isEmpty }) ?? false
            let hasRenderMaintenance = render.getResource(RenderFrameWork.self)?.collect(in: render) == true
            if continuous || cameraModeChanged || windowChanged || hasFrameWork || main.hasRemovedEntities
                || retiringTextures || hasRenderMaintenance || !surfaces.pendingFrameRequests.isEmpty
                || windows.windows.isEmpty || windows.windows.values.contains(where: { requests.shouldRender($0.0) }) {
                surfaces.automaticFrameRequests = requests
                return true
            }

            if !surfaces.windows.isEmpty {
                surfaces.windows.removeAll(keepingCapacity: true)
                let targets = Query<Ref<RenderViewTarget>>()
                targets.update(from: render)
                targets.forEach { $0.outputTexture = nil }
            }
            RenderWorldExctractor.advanceClock(from: main, to: render)
            return false
        }

        @MainActor
        private func collectCameras(
            from main: World,
            graph: RenderGraph,
            windows: RenderWindows,
            primary: PrimaryWindowId?,
            requests: inout WindowFrameRequests
        ) -> Bool {
            var continuous = false
            var uniforms: [(Entity, GlobalViewUniform)] = []
            onDemandTargets.removeAll(keepingCapacity: true)
            cameras.update(from: main)
            cameras.forEach { entity, camera in
                guard camera.isActive else {
                    return
                }
                var refreshView = false
                switch camera.renderTarget {
                case let .texture(handle):
                    continuous = true
                    if let texture = handle.asset {
                        refreshView = camera.viewport.rect.width != Float(texture.width)
                            || camera.viewport.rect.height != Float(texture.height)
                            || camera.computedData.targetScaleFactor != texture.scaleFactor
                    }
                case let .window(window):
                    let onDemand = entity.components[WindowRenderOnDemand.self]
                    let cameraGraph = entity.components[CameraRenderGraph.self]
                    let deferrable = onDemand != nil && (cameraGraph.map {
                        graph.getSubgraph(by: $0.subgraphLabel)?.supportsOnDemandWindowFrames == true
                    } ?? true)
                    if !deferrable { continuous = true }
                    requests.include(window, primary: primary?.windowId, onDemand: deferrable)
                    if let primary, let target = windows.windows.firstValue(for: window.getWindowId(from: primary)) {
                        if deferrable { onDemandTargets[entity.id] = target.windowId }
                        refreshView = camera.viewport.rect.size != target.physicalSize
                            || camera.computedData.targetScaleFactor != target.scaleFactor
                    }
                }
                if refreshView, let transform = entity.components[GlobalTransform.self] {
                    let uniform = CameraSystem.refreshView(of: camera, globalTransform: transform, primaryWindow: primary)
                    uniforms.append((entity, uniform))
                }
            }
            for (entity, id) in onDemandTargets where previousOnDemandTargets[entity] != id {
                requests.requestedWindowIDs.insert(id)
            }
            for (entity, id) in previousOnDemandTargets where onDemandTargets[entity] != id && windows.windows.firstValue(for: id) != nil {
                requests.requestedWindowIDs.insert(id)
            }
            swap(&previousOnDemandTargets, &onDemandTargets)
            for (entity, uniform) in uniforms {
                entity.components += uniform
            }
            return continuous
        }
    }
#endif
