//
//  ViewProxy.swift
//  AdaEngine
//
//  Created by Codex on 20.05.2026.
//

import AdaUtils

@MainActor
protocol ViewProxyTarget: AnyObject {
    nonisolated var proxyTargetID: ObjectIdentifier { get }

    func layoutIfNeeded()
    func redraw()
    func setNeedsDisplay()
}

/// A public handle for requesting imperative updates from the current view node.
///
/// `ViewProxy` keeps `ViewNode` internal while allowing views to request layout
/// and redraw work through `@Environment(\.viewProxy)`.
public struct ViewProxy: Hashable, @unchecked Sendable {
    private weak var target: (any ViewProxyTarget)?
    private let targetID: ObjectIdentifier?

    /// Creates an empty proxy.
    public init() {
        self.target = nil
        self.targetID = nil
    }

    @MainActor
    init(target: any ViewProxyTarget) {
        self.target = target
        self.targetID = target.proxyTargetID
    }

    /// Forces the container to perform layout if it has pending layout work.
    @MainActor
    public func layoutIfNeeded() {
        target?.layoutIfNeeded()
    }

    /// Invalidates cached drawing for the view and schedules it for redraw.
    @MainActor
    public func redraw() {
        target?.redraw()
    }

    /// Marks the view's visible bounds as dirty.
    @MainActor
    public func setNeedsDisplay() {
        target?.setNeedsDisplay()
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.targetID == rhs.targetID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(targetID)
    }
}

extension EnvironmentValues {
    /// A proxy for requesting layout and redraw work from the current view node.
    @Entry public var viewProxy: ViewProxy = ViewProxy()
}

extension ViewNode: ViewProxyTarget {
    nonisolated var proxyTargetID: ObjectIdentifier {
        ObjectIdentifier(self)
    }

    func layoutIfNeeded() {
        owner?.containerView?.layoutIfNeeded()
    }

    func redraw() {
        invalidateNearestLayer()
        owner?.containerView?.setNeedsDisplay(in: visualAbsoluteFrame())
    }

    func setNeedsDisplay() {
        owner?.containerView?.setNeedsDisplay(in: visualAbsoluteFrame())
    }
}
