//
//  UIPlugin.swift
//  AdaEngine
//
//  Created by vladislav.prusakov on 19.08.2024.
//

import AdaApp
import AdaCorePipelines
import AdaECS
@_spi(Internal) import AdaInput
import AdaRender
import AdaText
import AdaUtils
import Logging
import Math

public struct UIPlugin: Plugin {
    public init() {}

    public func setup(in app: AppWorlds) {
        UIComponent.registerComponent()

        app
            .addSystem(UpdateWindowManagerSystem.self, on: .preUpdate)
            .addSystem(UIComponentSystem.self)
            .insertResource(UIWindowPendingDrawViews())
            .insertResource(UIContextPendingDraw())
            .insertResource(UIRedrawRequest())

        guard let renderWorld = app.getSubworldBuilder(by: .renderWorld) else {
            return
        }

        // Register resources for UI rendering
        renderWorld
            .insertResource(ExtractedUIComponents())
            .insertResource(ExtractedUIContexts())
            .insertResource(PendingUIGraphicsContext())
            .insertResource(RenderItems<UITransparentRenderItem>())
            .insertResource(UIDrawPass())
            .insertResource(UIViewUniform())
            .insertResource(UIRenderBuildState())
            .insertResource(UILayerDrawCache())
            .insertResource(GlassBackgroundTexture())
            .insertResource(RenderPipelines(configurator: LinearGradientPipeline()))
            .insertResource(RenderPipelines(configurator: GlassPipeline()))

        renderWorld.initResource(UIRenderPipelines.self)

        let renderGraph = renderWorld.getRefResource(RenderGraph.self)
        do {
            try renderGraph.wrappedValue.updateSubgraph(by: .main2D) { graph in
                graph.addNode(UIRenderNode())

                // After Main2D, UIRenderNode draws UI; before each render item that contains glass
                // it ends the pass, blits the main target → GlassBackgroundTexture on the same
                // command buffer, then resumes (so blur samples ECS plus any UI drawn underneath).
                graph.removeNodeEdge(from: Main2DRenderNode.name, to: RenderNodeLabel.Main2D.endPass)
                graph.addNodeEdge(from: Main2DRenderNode.self, to: UIRenderNode.self)
                graph.addNodeEdge(from: UIRenderNode.name, to: RenderNodeLabel.Main2D.endPass)
            }

            // Add UI rendering systems
            renderWorld.addSystem(ExtractUIComponentsSystem.self, on: .extract)
            renderWorld.addSystem(UIRenderPreparingSystem.self, on: .prepare)
            renderWorld.addSystem(UIRenderTesselationSystem.self, on: .update)
        } catch {
            Logger(label: "org.adaengine.UIRenderPlugin").error("\(error)")
        }
    }
}

public struct WindowPlugin: Plugin {
    let primaryWindow: UIWindow?

    public init(primaryWindow: UIWindow? = nil) {
        self.primaryWindow = primaryWindow
    }

    public func setup(in app: AppWorlds) {
        #if WASM
            print("AdaEngine WindowPlugin setup")
        #endif
        guard let windowSettings = app.getResource(WindowSettings.self) else {
            return
        }

        if let primaryWindow {
            primaryWindow.showWindow(makeFocused: true)
            app
                .insertResource(PrimaryWindow(window: primaryWindow))
                .insertResource(PrimaryWindowId(windowId: primaryWindow.id))
        } else {
            #if os(iOS) || os(tvOS) || os(watchOS)
                let embeddedWindowSize = Screen.main?.size ?? windowSettings.minimumSize
                let configuration = UIWindow.Configuration(
                    title: windowSettings.title ?? "App",
                    frame: windowSettings.frame,
                    minimumSize: embeddedWindowSize,
                    mode: .fullscreen,
                    chrome: UIWindow.Chrome(windowSettings.chrome),
                    titleBar: UIWindow.TitleBar(windowSettings.titleBar),
                    background: UIWindow.Background(windowSettings.background),
                    backgroundEffect: UIWindow.BackgroundEffect(windowSettings.backgroundEffect),
                    level: UIWindow.Level(windowSettings.level),
                    collectionBehavior: UIWindow.CollectionBehavior(windowSettings.collectionBehavior),
                    screenPreference: windowSettings.screenPreference,
                    showsImmediately: windowSettings.showsImmediately,
                    makeKey: windowSettings.makeKey,
                    hasShadow: windowSettings.hasShadow,
                    isResizable: windowSettings.isResizable
                )
            #else
                let configuration = UIWindow.Configuration(
                    title: windowSettings.title ?? "App",
                    frame: windowSettings.frame,
                    minimumSize: windowSettings.minimumSize,
                    mode: UIWindow.Mode(windowSettings.windowMode),
                    chrome: UIWindow.Chrome(windowSettings.chrome),
                    titleBar: UIWindow.TitleBar(windowSettings.titleBar),
                    background: UIWindow.Background(windowSettings.background),
                    backgroundEffect: UIWindow.BackgroundEffect(windowSettings.backgroundEffect),
                    level: UIWindow.Level(windowSettings.level),
                    collectionBehavior: UIWindow.CollectionBehavior(windowSettings.collectionBehavior),
                    screenPreference: windowSettings.screenPreference,
                    showsImmediately: windowSettings.showsImmediately,
                    makeKey: windowSettings.makeKey,
                    hasShadow: windowSettings.hasShadow,
                    isResizable: windowSettings.isResizable
                )
            #endif
            let window = UIWindow(configuration: configuration)
            #if WASM
                print("AdaEngine WindowPlugin created window")
            #endif
            if configuration.showsImmediately {
                window.showWindow(makeFocused: configuration.makeKey)
            }
            app
                .insertResource(PrimaryWindow(window: window))
                .insertResource(PrimaryWindowId(windowId: window.id))
        }
    }
}

public struct PrimaryWindow: Resource {
    public let window: UIWindow

    public init(window: UIWindow) {
        self.window = window
    }
}

public struct WindowManagerResource: Resource {
    public let windowManager: UIWindowManager

    public init(windowManager: UIWindowManager) {
        self.windowManager = windowManager
    }
}

extension UIWindow.Mode {
    init(_ mode: WindowMode) {
        switch mode {
        case .windowed:
            self = .windowed
        case .fullscreen:
            self = .fullscreen
        case .fullScreenWindowed:
            self = .fullScreenWindowed
        }
    }
}

extension UIWindow.Chrome {
    init(_ chrome: WindowChrome) {
        switch chrome {
        case .standard:
            self = .standard
        case .borderless:
            self = .borderless
        }
    }
}

extension UIWindow.Background {
    init(_ background: WindowBackground) {
        switch background {
        case let .opaque(color):
            self = .opaque(color)
        case .transparent:
            self = .transparent
        }
    }
}

extension UIWindow.BackgroundEffect {
    init(_ effect: WindowBackgroundEffect) {
        switch effect {
        case .none:
            self = .none
        case let .blur(material):
            self = .blur(Self.BlurMaterial(material))
        }
    }
}

extension UIWindow.BackgroundEffect.BlurMaterial {
    init(_ material: WindowBackgroundEffect.BlurMaterial) {
        switch material {
        case .windowBackground:
            self = .windowBackground
        case .hudWindow:
            self = .hudWindow
        case .sidebar:
            self = .sidebar
        case .popover:
            self = .popover
        case .contentBackground:
            self = .contentBackground
        case .underWindowBackground:
            self = .underWindowBackground
        #if os(macOS)
            case .glass:
                self = .glass
        #endif
        }
    }
}

extension UIWindow.Level {
    init(_ level: WindowLevel) {
        switch level {
        case .normal:
            self = .normal
        case .floating:
            self = .floating
        case .statusBar:
            self = .statusBar
        }
    }
}

extension UIWindow.CollectionBehavior {
    init(_ behavior: WindowCollectionBehavior) {
        switch behavior {
        case .standard:
            self = .standard
        case .allSpacesStationary:
            self = .allSpacesStationary
        }
    }
}

extension UIWindow.TitleBar {
    init(_ titleBar: WindowTitleBar) {
        switch titleBar.background {
        case .system:
            self.init(
                background: .system,
                reservesSafeArea: titleBar.reservesSafeArea,
                dragRegionHeight: titleBar.dragRegionHeight,
                trafficLightOffset: titleBar.trafficLightOffset
            )
        case .transparent:
            self.init(
                background: .transparent,
                reservesSafeArea: titleBar.reservesSafeArea,
                dragRegionHeight: titleBar.dragRegionHeight,
                trafficLightOffset: titleBar.trafficLightOffset
            )
        }
    }
}

@System(dependencies: [
    .after(InputEventParseSystem.self)
])
@inline(__always)
@MainActor
public func UpdateWindowManager(
    _: WorldUpdateContext,
    _ windowManager: Res<WindowManagerResource>,
    _ pendingViews: ResMut<UIWindowPendingDrawViews>,
    _ contexts: ResMut<UIContextPendingDraw>,
    _ redrawRequest: ResMut<UIRedrawRequest>,
    _ input: ResMut<Input>,
    _ deltaTime: Res<DeltaTime>
) {
    pendingViews.windows.removeAll(keepingCapacity: true)
    contexts.contexts.removeAll(keepingCapacity: true)
    redrawRequest.needsRedraw = false
    let windowManager = windowManager.windowManager
    let deltaTime = deltaTime.deltaTime
    let windows = windowManager.windows
    for window in windows {
        let menuBuilder = windowManager.menuBuilder(for: window)
        menuBuilder?.updateIfNeeded()

        for event in input.wrappedValue.eventsPool where event.window == window.id {
            window.sendEvent(event)
        }

        window.internalUpdate(deltaTime)
        if window.canDraw && window.needsDisplay {
            pendingViews.windows.append(window)
            redrawRequest.needsRedraw = true
            window.needsDisplay = false
        }
    }
}

public struct UIWindowPendingDrawViews: Resource {
    public var windows: [UIWindow] = []
}

public struct UIContextPendingDraw: Resource {
    public var contexts: [UIGraphicsContext] = []
}

public struct UIRedrawRequest: Resource {
    public var needsRedraw: Bool = true
}
