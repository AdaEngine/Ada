//
//  HotReloadView.swift
//  AdaEngine
//
//  Created by AdaEngine on 07.05.2026.
//

import AdaInput
import AdaUtils
import Math

/// A factory that creates a hot-reloaded AdaUI host view for the supplied identifier.
public typealias UIHotReloadFactory = @MainActor (_ id: String) -> UIView?

/// Main-actor runtime registry used by ``HotReloadView`` hosts.
@MainActor
public enum UIHotReloadRuntime {
    private static var factory: UIHotReloadFactory?
    private static var hosts: [WeakHotReloadHost] = []
    static var initialHostEnvironment: EnvironmentValues?

    /// Sets the factory used to create hot-reloaded views.
    ///
    /// Pass `nil` to disable hot reload creation and make hosts fall back to their compiled fallback views.
    public static func setFactory(_ factory: UIHotReloadFactory?) {
        self.factory = factory
    }

    /// Reloads all registered hosts with the supplied identifier.
    ///
    /// If the factory returns `nil`, the host recreates its fallback view.
    public static func reload(id: String) {
        compactHosts()

        for host in hosts {
            guard let value = host.value, value.id == id else {
                continue
            }

            value.reload()
        }
    }

    /// Reloads every registered hot reload host.
    public static func reloadAll() {
        compactHosts()

        for host in hosts {
            host.value?.reload()
        }
    }

    static func register(_ host: UIHotReloadHostView) {
        compactHosts()

        if hosts.contains(where: { $0.value === host }) {
            return
        }

        hosts.append(WeakHotReloadHost(host))
    }

    static func makeView(id: String) -> UIView? {
        return factory?(id)
    }

    static func withInitialHostEnvironment<T>(
        _ environment: EnvironmentValues,
        _ body: () -> T
    ) -> T {
        let previousEnvironment = initialHostEnvironment
        initialHostEnvironment = environment
        defer {
            initialHostEnvironment = previousEnvironment
        }

        return body()
    }

    /// Creates a stable private identifier for a source location.
    ///
    /// This is used by ``View/hotReloading(fileID:function:line:column:)`` so callers do not have to
    /// coordinate public string identifiers for redraw-only hot reload boundaries.
    public static func automaticID(
        fileID: StaticString,
        function: StaticString,
        line: UInt,
        column: UInt
    ) -> String {
        "ada-ui.hot-reload.\(fileID).\(function).\(line).\(column)"
    }

    private static func compactHosts() {
        hosts.removeAll { $0.value == nil }
    }
}

private final class WeakHotReloadHost {
    weak var value: UIHotReloadHostView?

    init(_ value: UIHotReloadHostView) {
        self.value = value
    }
}

/// A view that hosts a hot-reloadable AdaUI subtree with a compiled fallback.
@MainActor
public struct HotReloadView<Fallback: View>: UIViewRepresentable {
    public typealias ViewType = UIView

    private let id: String
    private let fallback: @MainActor () -> Fallback

    /// Creates a hot reload host.
    ///
    /// - Parameters:
    ///   - id: Stable identifier used by the hot reload runtime.
    ///   - fallback: Compiled fallback content used before the runtime provides a replacement, or when reload creation fails.
    public init(
        id: String,
        @ViewBuilder fallback: @escaping @MainActor () -> Fallback
    ) {
        self.id = id
        self.fallback = fallback
    }

    public func makeUIView(in _: Context) -> UIView {
        return UIHotReloadHostView(id: id) {
            UIContainerView(rootView: fallback())
        }
    }

    public func updateUIView(_ view: UIView, in _: Context) {
        guard let host = view as? UIHotReloadHostView else {
            return
        }

        host.update(id: id) {
            UIContainerView(rootView: fallback())
        }
    }

    public func sizeThatFits(
        _ proposal: ProposedViewSize,
        view: UIView,
        context _: Context
    ) -> Size {
        return view.sizeThatFits(proposal)
    }
}

extension View {
    /// Wraps this view in a hot reload redraw boundary.
    ///
    /// Unlike ``hotReload(id:)``, this modifier does not require a manually coordinated identifier or
    /// an exported C factory symbol. Automatic hot reload runtimes can use the boundary to recreate the
    /// view after injected Swift implementations have been loaded.
    public func hotReloading(
        fileID: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line,
        column: UInt = #column
    ) -> some View {
        HotReloadView(
            id: UIHotReloadRuntime.automaticID(
                fileID: fileID,
                function: function,
                line: line,
                column: column
            )
        ) {
            self
        }
    }

    /// Wraps this view in a hot reload host with the supplied identifier.
    public func hotReload(id: String) -> some View {
        HotReloadView(id: id) {
            self
        }
    }
}

@MainActor
final class UIHotReloadHostView: UIView {
    var id: String

    private var fallback: @MainActor () -> UIView
    private weak var activeView: UIView?

    init(
        id: String,
        fallback: @escaping @MainActor () -> UIView
    ) {
        self.id = id
        self.fallback = fallback
        super.init()

        self.backgroundColor = .clear
        UIHotReloadRuntime.register(self)
        reload()
    }

    required init(frame: Rect) {
        self.id = ""
        self.fallback = { UIView() }
        super.init(frame: frame)

        self.backgroundColor = .clear
        UIHotReloadRuntime.register(self)
        reload()
    }

    override var minimumContentSize: Size {
        activeView?.minimumContentSize ?? .zero
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        guard let activeView else {
            return
        }

        activeView.frame = bounds
        activeView.safeAreaInsets = safeAreaInsets
        activeView.keyboardOccludedHeight = keyboardOccludedHeight
        activeView.userInterfaceIdiom = userInterfaceIdiom
        activeView.colorScheme = colorScheme
        activeView.layoutSubviews()
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        guard let activeView else {
            return proposal.replacingUnspecifiedDimensions()
        }

        return activeView.sizeThatFits(proposal)
    }

    override func onKeyEvent(_ event: KeyEvent) {
        activeView?.onKeyEvent(event)
    }

    override func onTextInputEvent(_ event: TextInputEvent) {
        activeView?.onTextInputEvent(event)
    }

    override func onReceiveEvent(_ event: any InputEvent) {
        activeView?.onEvent(event)
    }

    override func onMouseEvent(_ event: MouseEvent) {
        activeView?.onMouseEvent(event)
    }

    override func onTouchesEvent(_ touches: Set<TouchEvent>) {
        activeView?.onTouchesEvent(touches)
    }

    func update(
        id: String,
        fallback: @escaping @MainActor () -> UIView
    ) {
        let previousID = self.id
        self.id = id
        self.fallback = fallback
        UIHotReloadRuntime.register(self)

        if previousID != id || activeView == nil {
            reload()
        }
    }

    func reload() {
        let nextView = UIHotReloadRuntime.withInitialHostEnvironment(rootEnvironmentValues()) {
            let factoryView = UIHotReloadRuntime.makeView(id: id)
            return factoryView ?? fallback()
        }
        replaceActiveView(with: nextView)
    }

    private func replaceActiveView(with view: UIView) {
        guard activeView !== view else {
            return
        }

        activeView?.removeFromParentView()

        view.frame = bounds
        view.autoresizingRules = [.flexibleWidth, .flexibleHeight]
        view.safeAreaInsets = safeAreaInsets
        view.keyboardOccludedHeight = keyboardOccludedHeight
        view.userInterfaceIdiom = userInterfaceIdiom
        view.colorScheme = colorScheme
        addSubview(view)
        activeView = view
        layoutSubviews()
        setNeedsLayout()
        setNeedsDisplay()
    }
}
