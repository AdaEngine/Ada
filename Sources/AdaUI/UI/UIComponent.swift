//
//  UIComponent.swift
//  AdaEngine
//
//  Created by vladislav.prusakov on 19.08.2024.
//

import AdaECS
import AdaRender
import AdaUtils
import Foundation

/// - Warning: Work in progress component
@Component
public struct UIComponent: Sendable, Codable {
    /// Behaviour how to draw view on screen
    public enum Behaviour: String, Codable, Sendable {
        /// Always render on top of scene.
        case overlay

        /// Render UI elements in camera
        case `default`
    }

    private let storage: UIComponentStorage
    public var source: UIComponentSource? { storage.source }

    /// Entity-owned data for source-backed script bindings, including binding diagnostics.
    @MainActor public var scriptBindingContext: UIBindingContext? { storage.bindingData()?.context }

    @MainActor package func synchronizeScriptBindings(
        read: (UIScriptFieldBinding) throws -> UIScriptFieldSnapshot,
        write: (UIScriptFieldBinding, UIValue) throws -> Void
    ) {
        guard let source else {
            return
        }
        storage.bindingData()?.synchronize(mappings: source.scriptBindings, read: read, write: write)
    }

    @MainActor public var view: UIView {
        do { return try storage.resolve(runtime: nil) } catch { return UIContainerView(rootView: Text(error.localizedDescription).foregroundColor(.red)) }
    }

    /// Resolves a serialized source using the current world's UI services.
    @MainActor public func resolveView(runtime: UIComponentRuntime?) throws -> UIView {
        try storage.resolve(runtime: runtime)
    }
    public let behaviour: Behaviour
    public let windowRef: WindowRef

    @MainActor
    public init<V: View>(
        view: V,
        behaviour: Behaviour,
        windowRef: WindowRef = .primary
    ) {
        let container = UIContainerView(rootView: view)
        container.backgroundColor = .clear
        self.storage = UIComponentStorage(view: container)
        self.behaviour = behaviour
        self.windowRef = windowRef
    }

    public init(
        view: UIView,
        behaviour: Behaviour,
        windowRef: WindowRef = .primary
    ) {
        self.storage = UIComponentStorage(view: view)
        self.behaviour = behaviour
        self.windowRef = windowRef
    }
}

extension UIComponent {
    public init(source: UIComponentSource, behaviour: Behaviour = .overlay, windowRef: WindowRef = .primary) {
        storage = UIComponentStorage(source: source)
        self.behaviour = behaviour
        self.windowRef = windowRef
    }

    private enum CodingKeys: String, CodingKey { case source, behaviour, windowRef }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            source: try container.decode(UIComponentSource.self, forKey: .source),
            behaviour: try container.decodeIfPresent(Behaviour.self, forKey: .behaviour) ?? .overlay,
            windowRef: try container.decodeIfPresent(WindowRef.self, forKey: .windowRef) ?? .primary
        )
    }

    public func encode(to encoder: any Encoder) throws {
        guard let source else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "Only source-backed UIComponent values can be serialized."))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(behaviour, forKey: .behaviour)
        try container.encode(windowRef, forKey: .windowRef)
    }
}
