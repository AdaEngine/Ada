//
//  WorldPlugin.swift
//  AdaEngine
//
//  Created by v.prusakov on 8/11/22.
//

import AdaApp
import AdaECS
import AdaUtils
import Foundation
import Logging
import Math

/// The plugin that sets up the render world.
public struct RenderWorldPlugin: Plugin {
    public init() {}

    /// Setup the render world.
    /// - Parameter app: The app to setup the render world for.
    public func setup(in app: AppWorlds) {
        VisibleEntities.registerComponent()
        Visibility.registerComponent()
        NoFrustumCulling.registerComponent()
        BoundingComponent.registerComponent()
        Texture.registerTypes()

        let renderWorld = AppWorlds(main: World(name: "RenderWorld"))
        renderWorld.updateScheduler = .renderRunner
        renderWorld
            .insertResource(RenderGraph(label: "RenderWorld_Root"))
            .insertResource(RenderGraphDiagnostics())
            .insertResource(
                DefaultSchedulerOrder(order: [
                    .preUpdate,
                    .prepare,
                    .batching,
                    .update,
                    .render,
                    .postUpdate,
                ])
            )
        renderWorld.setExctractor(RenderWorldExctractor())
        renderWorld.main.setSchedulers([
            .startup,
            .extract,
            .preUpdate,
            .prepare,
            .batching,
            .update,
            .render,
            .postUpdate,
        ])

        do {
            try RenderEngine.setupRenderEngine()
        } catch {
            fatalError("Critical Error RenderWorldPlugin: \(error.localizedDescription)")
        }

        let renderDevice = unsafe RenderDeviceHandler(renderDevice: RenderEngine.shared.renderDevice)
        app.insertResource(renderDevice)

        unsafe renderWorld
            .insertResource(renderDevice)
            .insertResource(RenderEngineHandler(renderEngine: RenderEngine.shared))
            .insertResource(
                WindowSurfaces(
                    windows: [:],
                    allowsWindowRendering: app.main.getResource(OffscreenRenderWorld.self) == nil,
                    allowedWindowIDs: app.main.getResource(RenderWindowScope.self)?.windowIDs
                )
            )
            .addSystem(CreateWindowSurfacesSystem.self, on: .prepare)
            .addSystem(DefaultSchedulerRunner.self, on: .renderRunner)
            .addSystem(RenderSystem.self, on: .render)

        app.addSubworld(renderWorld, by: .renderWorld)
    }
}

public struct RenderDeviceHandler: Resource {
    public var renderDevice: RenderDevice

    public init(renderDevice: RenderDevice) {
        self.renderDevice = renderDevice
    }
}

public struct RenderEngineHandler: Resource {
    public var renderEngine: RenderEngine

    public init(renderEngine: RenderEngine) {
        self.renderEngine = renderEngine
    }
}

@PlainSystem
@_spi(Internal)
public struct RenderSystem {
    @Res<RenderGraph?>
    private var renderGraph

    @Res<WindowSurfaces>
    private var surfaces

    @Res<RenderDeviceHandler?>
    private var renderDevice

    @Res<RenderGraphDiagnostics?>
    private var renderGraphDiagnostics

    public init(world _: World) {}

    public func update(context: UpdateContext) async {
        renderGraph?.update(from: context.world)

        // We should capture drawables before we start async task.
        // Because we can have a situation when we start task, but main thread already cleared surfaces.
        let windows = surfaces.windows
        do {
            if RenderPipelining.isActive(in: context.world) {
                try await runPipelinedRenderGraph(in: context.world)
            } else {
                try await runRenderGraph(in: context.world)
            }
            for window in windows {
                try window.currentDrawable?.present()
            }
        } catch {
            assertionFailure("Failed to execute render graph \(error)")
        }
    }

    /// A pipelined render world executes off the shared `RenderGraphActor`, so a serial world's graph
    /// (for example the UI window) does not queue behind it. Its own updates never overlap: the parent
    /// waits for the previous update before extracting the next frame.
    @concurrent
    private func runPipelinedRenderGraph(in world: World) async throws {
        try await executeRenderGraph(in: world)
    }

    @RenderGraphActor
    @inline(__always)
    private func runRenderGraph(in world: World) async throws {
        try await executeRenderGraph(in: world)
    }

    @inline(__always)
    private func executeRenderGraph(
        in world: World
    ) async throws {
        guard
            let renderGraph,
            let renderDevice = renderDevice?.renderDevice
        else {
            return
        }
        let renderGraphExecutor = RenderGraphExecutor()
        try await renderGraphExecutor.execute(
            renderGraph,
            renderDevice: renderDevice,
            in: world,
            diagnostics: renderGraphDiagnostics
        )
    }
}

/// The extractor that extracts the main world to the render world.
struct RenderWorldExctractor: WorldExctractor {
    func exctract(from mainWorld: World, to renderWorld: World) async {
        renderWorld.clear()
        renderWorld.insertResource(MainWorld(world: mainWorld))
        var graphClock = renderWorld.getResource(ShaderGraphClock.self) ?? ShaderGraphClock()
        graphClock.advance(delta: mainWorld.getResource(DeltaTime.self)?.deltaTime ?? 0)
        renderWorld.insertResource(graphClock)
        if let primaryWindow = mainWorld.getResource(PrimaryWindowId.self) {
            renderWorld.insertResource(primaryWindow)
        }
        // Copied, not read through `Extract`, because surfaces are created after extraction (`.prepare`).
        if let frameRequests = mainWorld.getResource(WindowFrameRequests.self) {
            renderWorld.insertResource(frameRequests)
        } else {
            renderWorld.removeResource(WindowFrameRequests.self)
        }
        await renderWorld.runScheduler(.extract)
        // A pipelined render world renders while the main world simulates the next frame.
        // Reading the main world after extraction would race, so the reference ends here.
        if RenderPipelining.isActive(in: renderWorld) {
            renderWorld.removeResource(MainWorld.self)
        }
    }
}

/// The resource that contains the main world.
package struct MainWorld: Resource {
    package var world: World

    package init(world: World) {
        self.world = world
    }
}

public struct WindowSurface: Sendable {
    public var swapchain: (any Swapchain)?
    public var currentDrawable: (any Drawable)?
}

public final class WindowSurfaces: Resource, @unchecked Sendable {
    public var windows: SparseSet<WindowRef, WindowSurface>
    var pendingFrameRequests = PendingWindowFrameRequests()
    let allowsWindowRendering: Bool
    let allowedWindowIDs: Set<WindowID>?

    public convenience init(windows: SparseSet<WindowRef, WindowSurface>) {
        self.init(windows: windows, allowsWindowRendering: true)
    }

    init(windows: SparseSet<WindowRef, WindowSurface>, allowsWindowRendering: Bool, allowedWindowIDs: Set<WindowID>? = nil) {
        self.windows = windows
        self.allowsWindowRendering = allowsWindowRendering
        self.allowedWindowIDs = allowedWindowIDs
    }
}

@System
@_spi(Internal)
public func CreateWindowSurfaces(
    _ surfaces: ResMut<WindowSurfaces>,
    _ renderDevice: Res<RenderDeviceHandler>,
    _ renderInstance: Res<RenderEngineHandler>,
    _ primaryWindow: Res<PrimaryWindowId?>,
    _ frameRequests: Res<WindowFrameRequests?>
) async {
    surfaces.windows.removeAll()
    // Keep this system in the camera dependency graph, but never acquire host drawables offscreen.
    guard surfaces.wrappedValue.allowsWindowRendering else {
        return
    }
    let device = renderDevice.renderDevice
    let requests = frameRequests.wrappedValue
    surfaces.wrappedValue.pendingFrameRequests.include(requests)

    do {
        let renderWindows = try await renderInstance.renderEngine.getRenderWindows()
        surfaces.wrappedValue.pendingFrameRequests.retainWindows(renderWindows.windows.values.lazy.map { $0.0 })
        for (windowId, _) in renderWindows.windows.values {
            if let allowed = surfaces.wrappedValue.allowedWindowIDs, !allowed.contains(windowId) {
                continue
            }
            guard surfaces.wrappedValue.pendingFrameRequests.shouldAcquireDrawable(for: windowId, requests: requests) else { continue }
            guard let swapchain = await device.createSwapchain(from: windowId) else {
                Logger(label: "org.adaengine.render")
                    .debug("Swapchain not enable for \(windowId)")
                continue
            }

            let ref: WindowRef =
                if primaryWindow.wrappedValue?.windowId == windowId {
                    .primary
                } else {
                    .windowId(windowId)
                }
            let drawable = swapchain.getNextDrawable(device)
            if drawable != nil { surfaces.wrappedValue.pendingFrameRequests.didAcquireDrawable(for: windowId) }
            surfaces.windows[ref] = WindowSurface(
                swapchain: swapchain,
                currentDrawable: drawable
            )
        }
    } catch {
        Logger(label: "org.adaengine.AdaRender").error("\(error)")
    }
}

/// Limits a runtime's drawable acquisition to its own native windows.
/// Insert before building render plugins; other embedded panels keep their own frame loop.
public struct RenderWindowScope: Resource {
    public let windowIDs: Set<WindowID>
    public init(windowIDs: Set<WindowID>) { self.windowIDs = windowIDs }
}

/// Insert before building plugins to render only into textures, without presenting windows.
@_spi(Internal)
public struct OffscreenRenderWorld: Resource {
    public init() {}
}

public struct PrimaryWindowId: Resource {
    public var windowId: RID

    public init(windowId: RID) {
        self.windowId = windowId
    }
}

public struct RenderWindows: Resource {
    public var windows: SparseSet<WindowID, RenderWindow>

    public init(windows: SparseSet<WindowID, RenderWindow>) {
        self.windows = windows
    }
}

public struct RenderWindow: Sendable, Hashable {
    public var windowId: WindowID
    public var height: Int
    public var width: Int
    public var scaleFactor: Float

    public var physicalSize: Size {
        Size(
            width: Float(width) * scaleFactor,
            height: Float(height) * scaleFactor
        )
    }

    public var logicalSize: SizeInt {
        SizeInt(width: width, height: height)
    }

    public init(windowId: WindowID, height: Int, width: Int, scaleFactor: Float) {
        self.windowId = windowId
        self.height = height
        self.width = width
        self.scaleFactor = scaleFactor
    }
}

extension SchedulerName {
    /// The render scheduler.
    public static let renderRunner = SchedulerName(rawValue: "RenderWorld_RenderRunner")

    public static let prepare = SchedulerName(rawValue: "RenderWorld_Prepare")
    public static let batching = SchedulerName(rawValue: "RenderWorld_Batching")
    public static let render = SchedulerName(rawValue: "RenderWorld_Render")
    public static let extract = SchedulerName(rawValue: "RenderWorld_Extract")
}

extension AppWorldName {
    /// The render world that will render the scene.
    public static let renderWorld = AppWorldName(rawValue: "RenderWorld")
}
