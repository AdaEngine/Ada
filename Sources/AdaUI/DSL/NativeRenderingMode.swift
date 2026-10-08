//
//  NativeRenderingMode.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 21.04.2026.
//

import AdaUtils

/// The rendering mode for native views integrated into AdaUI.
public enum NativeRenderingMode: Sendable {
    /// The native view is rendered to an offscreen texture and drawn by AdaEngine.
    /// This allows the view to be part of the 2D/3D scene with proper Z-indexing and post-processing.
    case offscreen

    /// The native view is added as a subview directly on top of the engine's render surface.
    /// This provides the best performance and native interaction (scrolling, text input) but always renders on top.
    case overlay
}

public struct NativeRenderingModeKey: EnvironmentKey {
    public static let defaultValue: NativeRenderingMode = .offscreen
}

extension EnvironmentValues {
    /// The rendering mode for native views in this environment.
    public var nativeRenderingMode: NativeRenderingMode {
        get { self[NativeRenderingModeKey.self] }
        set { self[NativeRenderingModeKey.self] = newValue }
    }
}

extension View {
    /// Sets the rendering mode for native views within this view's hierarchy.
    /// - Parameter mode: The rendering mode to use.
    public func nativeRenderingMode(_ mode: NativeRenderingMode) -> some View {
        self.environment(\.nativeRenderingMode, mode)
    }
}
