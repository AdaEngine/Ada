//
//  UISystem.swift
//  AdaEngine
//
//  Created by vladislav.prusakov on 19.08.2024.
//

import AdaECS
import AdaInput
import AdaRender
import AdaTransform
import AdaUtils
import Math

@PlainSystem
public struct UIComponentSystem: Sendable {
    @Query<Entity, UIComponent, GlobalTransform>
    private var uiComponents

    @Query<Camera>
    private var cameras

    @ResMut
    private var input: Input

    @Res<DeltaTime>
    private var deltaTime

    @Res<WindowManagerResource>
    private var windowManager

    @ResMut<UIWindowPendingDrawViews>
    private var pendingViews

    @ResMut<UIRedrawRequest>
    private var redrawRequest

    @Res<PrimaryWindowId>
    private var primaryWindowId

    public init(world _: World) {}

    @MainActor
    public func update(context _: UpdateContext) async {
        self.uiComponents.forEach { entity, component, transform in
            update(
                entity: entity,
                component: component,
                globalTransform: transform,
                deltaTime: deltaTime.deltaTime
            )
        }
    }
}

extension UIComponentSystem {
    @MainActor
    @inline(__always)
    private func update(
        entity: Entity,
        component: UIComponent,
        globalTransform: GlobalTransform,
        deltaTime: TimeInterval
    ) {
        let view: UIView
        do {
            let runtime = entity.world?.getResource(UIComponentRuntimeResource.self)?.runtime
            view = try component.resolveView(runtime: runtime)
        } catch { return }
        let behaviour = component.behaviour

        if let viewOwner = (view as? ViewOwner) {
            var environment = EnvironmentValues()
            environment.entity = entity
            environment.windowManager = windowManager.windowManager
            if let world = entity.world {
                environment.world = world
            }
            viewOwner.updateEnvironment(environment)
        }

        switch behaviour {
        case .overlay:
            if let window = windowManager
                .windowManager
                .windows[component.windowRef.getWindowId(from: primaryWindowId)] {
                // Do not assign `view.window` before `addSubview`: `UIWindow.addSubview`
                // treats `view.window === self` as “already added” and asserts.
                if view.parentView !== window {
                    view.autoresizingRules = [.flexibleWidth, .flexibleHeight]
                    window.addSubview(view)
                }
                // Overlay must match the window bounds during live resize. Using only
                // `sizeThatFits` can under-fill the window while layout is settling, which
                // breaks UI draw/compositing atop the scene (black or empty content region).
                let newFrame = Rect(origin: .zero, size: window.frame.size)
                if view.frame != newFrame {
                    view.frame = newFrame
                    view.layoutSubviews()
                    redrawRequest.needsRedraw = true
                }
            }
        case .default:
            if view.transform3D != globalTransform.matrix {
                view.transform3D = globalTransform.matrix
                view.setNeedsDisplay()
            }
        }

        let events = input.getInputEvents()
        for event in events {
            guard view.canRespondToAction(event) else {
                continue
            }

            let responder = view.findFirstResponder(for: event) ?? view
            responder.onEvent(event)
        }

        view.update(deltaTime)

        if view.consumeNeedsDisplay() {
            redrawRequest.needsRedraw = true
        }
    }
}

extension EnvironmentValues {
    /// The world where view attached.
    @_spi(Internal) @Entry public internal(set) var world: World?

    /// The game scene where view attached.
    @Entry internal var entity: Entity?

    @Entry internal var input: Ref<Input>?

    /// The windowManager where view attached.
    @_spi(Internal) @Entry public internal(set) var windowManager: UIWindowManager?
}
