//
//  AppScene.swift
//  AdaEngine
//
//  Created by v.prusakov on 6/14/22.
//

import AdaUtils
import Foundation
import Math

#if canImport(Glibc)
    import Glibc
#endif
#if canImport(Darwin)
    import Darwin.C
#endif
#if os(Windows)
    import WinSDK
#endif

/// Describe which kind of scene will present on start.
@MainActor @preconcurrency
public protocol AppScene {
    associatedtype Body: AppScene
    var body: Body { get }

    @MainActor @preconcurrency
    static func _makeView(
        _ scene: _AppSceneNode<Self>,
        inputs: _SceneInputs
    ) -> _SceneOutputs
}

public struct _SceneInputs {
    var appWorlds: AppWorlds
}

public struct _SceneOutputs {
    var appWorlds: AppWorlds
}

extension AppScene {
    @MainActor @preconcurrency
    public static func _makeView(
        _ scene: _AppSceneNode<Self>,
        inputs: _SceneInputs
    ) -> _SceneOutputs {
        if Self.Body.self == Never.self {
            return _SceneOutputs(appWorlds: inputs.appWorlds)
        }
        let body = Self.Body._makeView(scene[\.body], inputs: inputs)
        return body
    }
}

// MARK: - Modifiers

extension AppScene {
    /// Set the minimum size of the window.
    public func minimumSize(width: Float, height: Float) -> some AppScene {
        return self.modifier(MinimumWindowSizeSceneModifier(size: Size(width: width, height: height)))
    }

    /// Set the window presentation mode.
    public func windowMode(_ mode: WindowMode) -> some AppScene {
        return self.modifier(WindowModeSceneModifier(windowMode: mode))
    }

    /// Set the flag which describe can we create more than one window.
    public func singleWindow(_ isSingleWindow: Bool) -> some AppScene {
        return self.modifier(IsSingleWindowSceneModifier(isSingleWindow: isSingleWindow))
    }

    /// Set whether the native platform window should draw a drop shadow.
    public func windowShadow(_ hasShadow: Bool) -> some AppScene {
        self.modifier(WindowShadowSceneModifier(hasShadow: hasShadow))
    }

    /// Set whether the native platform window can be resized by the user.
    public func windowResizable(_ isResizable: Bool) -> some AppScene {
        self.modifier(WindowResizableSceneModifier(isResizable: isResizable))
    }

    /// Set the window title.
    public func windowTitle(_ title: String) -> some AppScene {
        self.modifier(WindowTitleSceneModifier(title: title))
    }

    /// Set the preferred display for the window.
    public func windowScreen(_ preference: WindowScreenPreference) -> some AppScene {
        self.modifier(WindowScreenSceneModifier(preference: preference))
    }

    /// Set the platform title bar presentation.
    public func windowTitleBar(_ titleBar: WindowTitleBar) -> some AppScene {
        self.modifier(WindowTitleBarSceneModifier(titleBar: titleBar))
    }

    /// Set the native platform window chrome style.
    public func windowChrome(_ chrome: WindowChrome) -> some AppScene {
        self.modifier(WindowChromeSceneModifier(chrome: chrome))
    }

    /// Set the native platform window background style.
    public func windowBackground(_ background: WindowBackground) -> some AppScene {
        self.modifier(WindowBackgroundSceneModifier(background: background))
    }

    /// Set whether the native platform window background should be transparent.
    public func windowTransparentBackground(_ isTransparent: Bool = true) -> some AppScene {
        self.windowBackground(isTransparent ? .transparent : .opaque(.black))
    }

    /// Offset macOS traffic light buttons. Positive `x` moves right, positive `y` moves down.
    public func windowTrafficLightOffset(x: Float, y: Float) -> some AppScene {
        self.modifier(WindowTrafficLightOffsetSceneModifier(offset: Point(x: x, y: y)))
    }

    /// Add new plugin for app
    public func addPlugins<each T: Plugin>(_ plugin: repeat each T) -> some AppScene {
        return modifier(AddPluginsModifier(plugins: (repeat (each plugin))))
    }
}

extension AppScene {
    /// Applies a modifier to a view and returns a new view.
    /// - Parameter modifier: The modifier to apply to this view.
    public func modifier<T>(_ modifier: T) -> SceneModifiedContent<Self, T> {
        return SceneModifiedContent(content: self, modifier: modifier)
    }
}

extension SceneModifier where Body == Never {
    public func body(content _: Self.Content) -> Never {
        fatalError("We should call body when Body is Never type.")
    }
}

public struct SceneModifiedContent<Content, Modifier> {
    public var content: Content
    public var modifier: Modifier

    @inlinable public init(content: Content, modifier: Modifier) {
        self.content = content
        self.modifier = modifier
    }
}
/// A modifier that you apply to a view or another view modifier, producing a different version of the original value.
///
/// Adopt the ``ViewModifier`` protocol when you want to create a reusable modifier that you can apply to any view.
/// You can apply ``View/modifier(_:)`` directly to a view, but a more common and idiomatic approach
/// uses ``View/modifier(_:)`` to define an extension to View itself that incorporates the view modifier:
@preconcurrency
public protocol SceneModifier {
    /// The type of view representing the body.
    associatedtype Body: AppScene
    /// The content view type passed to body().
    typealias Content = _ModifiedScene<Self>

    /// Gets the current body of the caller.
    @MainActor
    func body(content: Self.Content) -> Body

    @MainActor
    static func _makeView(
        for modifier: _AppSceneNode<Self>,
        inputs: _SceneInputs,
        body: @escaping (_SceneInputs) -> _SceneOutputs
    ) -> _SceneOutputs
}

extension SceneModifier {
    @MainActor
    public static func _makeView(
        for modifier: _AppSceneNode<Self>,
        inputs: _SceneInputs,
        body: @escaping (_SceneInputs) -> _SceneOutputs
    ) -> _SceneOutputs {
        let newBody = modifier.value.body(content: _ModifiedScene(storage: .makeScene(body)))
        return Self.Body._makeView(_AppSceneNode(value: newBody), inputs: inputs)
    }
}

public struct _AppSceneNode<Value>: Equatable {
    let value: Value

    subscript<U>(keyPath: KeyPath<Value, U>) -> _AppSceneNode<U> {
        _AppSceneNode<U>(value: self.value[keyPath: keyPath])
    }

    public static func == (lhs: _AppSceneNode<Value>, rhs: _AppSceneNode<Value>) -> Bool where Value: Equatable {
        lhs.value == rhs.value
    }

    public static func == (lhs: _AppSceneNode<Value>, rhs: _AppSceneNode<Value>) -> Bool {
        // if its pod, we can compare it together using memcmp.
        if _isPOD(Value.self) {
            let memSize = MemoryLayout<Value>.size
            return unsafe withUnsafePointer(to: lhs.value) { lhsPtr in
                unsafe withUnsafePointer(to: rhs.value) { rhsPtr in
                    unsafe memcmp(lhsPtr, rhsPtr, memSize) == 0
                }
            }
        } else {
            // For another hand we should compare it using reflection or smth else
            return false
        }
    }
}

extension SceneModifiedContent: AppScene where Modifier: SceneModifier, Content: AppScene {
    public var body: Never {
        fatalError("Unreachable code")
    }

    @MainActor
    public static func _makeView(_ view: _AppSceneNode<Self>, inputs: _SceneInputs) -> _SceneOutputs {
        return Modifier._makeView(for: view[\.modifier], inputs: inputs) { inputs in
            return Content._makeView(view[\.content], inputs: inputs)
        }
    }
}

extension SceneModifiedContent: SceneModifier where Content: SceneModifier, Modifier: SceneModifier {
    @MainActor
    public static func _makeView(
        for modifier: _AppSceneNode<Self>,
        inputs: _SceneInputs,
        body: @escaping (_SceneInputs) -> _SceneOutputs
    ) -> _SceneOutputs {
        return Modifier._makeView(for: modifier[\.modifier], inputs: inputs) { inputs in
            let content = modifier[\.content]
            return Content._makeView(for: content, inputs: inputs, body: body)
        }
    }
}

protocol _ViewInputsViewModifier {
    @MainActor static func _makeModifier(_ modifier: _AppSceneNode<Self>, inputs: inout _SceneInputs)
}

extension SceneModifier where Self: _ViewInputsViewModifier {
    @MainActor
    static func _makeView(
        for modifier: _AppSceneNode<Self>,
        inputs: _SceneInputs,
        body: @escaping (_SceneInputs) -> _SceneOutputs
    ) -> _SceneOutputs {
        var inputs = inputs
        Self._makeModifier(modifier, inputs: &inputs)

        let newBody = modifier.value.body(content: _ModifiedScene(storage: .makeScene(body)))
        return Self.Body._makeView(_AppSceneNode(value: newBody), inputs: inputs)
    }
}

protocol _SceneOutputsViewModifier {
    @MainActor static func _makeModifier(_ modifier: _AppSceneNode<Self>, outputs: inout _SceneOutputs)
}

extension SceneModifier where Self: _SceneOutputsViewModifier {
    @MainActor
    static func _makeView(
        for modifier: _AppSceneNode<Self>,
        inputs: _SceneInputs,
        body: @escaping (_SceneInputs) -> _SceneOutputs
    ) -> _SceneOutputs {
        let newBody = modifier.value.body(content: _ModifiedScene(storage: .makeScene(body)))
        var outputs = Self.Body._makeView(_AppSceneNode(value: newBody), inputs: inputs)
        self._makeModifier(modifier, outputs: &outputs)
        return outputs
    }
}
