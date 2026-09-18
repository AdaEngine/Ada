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
                    allowsWindowRendering: app.main.getResource(OffscreenRenderWorld.self) == nil
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
            try await runRenderGraph(in: context.world)
            for window in windows {
                try window.currentDrawable?.present()
            }
        } catch {
            assertionFailure("Failed to execute render graph \(error)")
        }
    }

    @RenderGraphActor
    @inline(__always)
    private func runRenderGraph(
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
        if let primaryWindow = mainWorld.getResource(PrimaryWindowId.self) {
            renderWorld.insertResource(primaryWindow)
        }
        await renderWorld.runScheduler(.extract)
    }
}

/// The resource that contains the main world.
struct MainWorld: Resource {
    var world: World
}

public struct WindowSurface: Sendable {
    public var swapchain: (any Swapchain)?
    public var currentDrawable: (any Drawable)?
}

public final class WindowSurfaces: Resource, @unchecked Sendable {
    public var windows: SparseSet<WindowRef, WindowSurface>
    let allowsWindowRendering: Bool

    public convenience init(windows: SparseSet<WindowRef, WindowSurface>) {
        self.init(windows: windows, allowsWindowRendering: true)
    }

    init(windows: SparseSet<WindowRef, WindowSurface>, allowsWindowRendering: Bool) {
        self.windows = windows
        self.allowsWindowRendering = allowsWindowRendering
    }
}

@System
@_spi(Internal)
public func CreateWindowSurfaces(
    _ surfaces: ResMut<WindowSurfaces>,
    _ renderDevice: Res<RenderDeviceHandler>,
    _ renderInstance: Res<RenderEngineHandler>,
    _ primaryWindow: Extract<Res<PrimaryWindowId>>
) async {
    surfaces.windows.removeAll()
    // Keep this system in the camera dependency graph, but never acquire host drawables offscreen.
    guard surfaces.wrappedValue.allowsWindowRendering else {
        return
    }
    let device = renderDevice.renderDevice

    do {
        let renderWindows = try await renderInstance.renderEngine.getRenderWindows()
        for (windowId, _) in renderWindows.windows.values {
            guard let swapchain = await device.createSwapchain(from: windowId) else {
                Logger(label: "org.adaengine.render")
                    .debug("Swapchain not enable for \(windowId)")
                continue
            }

            let ref: WindowRef =
                if primaryWindow.wrappedValue.windowId == windowId {
                    .primary
                } else {
                    .windowId(windowId)
                }
            let drawable = swapchain.getNextDrawable(device)
            surfaces.windows[ref] = WindowSurface(
                swapchain: swapchain,
                currentDrawable: drawable
            )
        }
    } catch {
        Logger(label: "org.adaengine.AdaRender").error("\(error)")
    }
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
