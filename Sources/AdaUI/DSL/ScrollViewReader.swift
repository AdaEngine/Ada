//
//  ScrollViewReader.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 26.07.2024.
//

import AdaUtils
import Math
import Observation

/// A proxy value that supports programmatic scrolling of the scrollable views within a view hierarchy.
///
/// You don’t create instances of ScrollViewProxy directly.
/// Instead, your ``ScrollViewReader`` receives an instance of ``ScrollViewProxy`` in its content view builder.
/// You use actions within this view builder, such as button and gesture handlers or the ``View/onChange(of:perform:)``
/// method, to call the proxy’s ``ScrollViewProxy/scrollTo(_:anchor:)`` method.
@MainActor
public struct ScrollViewProxy {
    private let _proxy: _ScrollViewProxy

    init(proxy: _ScrollViewProxy) {
        self._proxy = proxy
    }

    public func scrollTo<H: Hashable>(_ id: H, anchor: AnchorPoint? = nil) {
        _proxy.subscribedScrollViewNodes.forEach { node in
            node.scrollToViewNodeIfFoundIt(id, anchor: anchor)
        }
    }

    public func isNearBottom(threshold: Float = 48) -> Bool {
        _proxy.subscribedScrollViewNodes.first(where: { _ in true })?.isNearBottom(threshold: threshold) ?? true
    }

    // FIXME: Should trigger when content offset did change.
    func scrollOffset(in coordinateSpace: NamedViewCoordinateSpace? = nil) -> Point {
        _proxy.subscribedScrollViewNodes.first(where: {
            $0.environment.coordinateSpaces.containers[coordinateSpace?.name ?? AnyHashable(ViewCoordinateSpace.scrollViewId)] != nil
        })?
        .contentOffset ?? .zero
    }
}

/// A view that provides programmatic scrolling, by working with a proxy to scroll to known child views.
///
/// The scroll view reader’s content view builder receives a ``ScrollViewProxy`` instance;
/// you use the proxy’s ``ScrollViewProxy/scrollTo(_:anchor:)`` to perform scrolling.
@MainActor @preconcurrency
public struct ScrollViewReader<Content: View>: View {
    @State private var proxy: _ScrollViewProxy
    let content: (ScrollViewProxy) -> Content

    public init(@ViewBuilder content: @escaping (ScrollViewProxy) -> Content) {
        self._proxy = State(initialValue: _ScrollViewProxy())
        self.content = content
    }

    public var body: some View {
        content(ScrollViewProxy(proxy: proxy))
            .environment(\.scrollViewProxy, proxy)
    }
}

@MainActor @Observable
final class _ScrollViewProxy {
    // Runtime node registration is bookkeeping and must not invalidate reader content.
    @ObservationIgnored
    var subscribedScrollViewNodes: WeakSet<ScrollViewNode> = []

    func subsribe(_ scrollView: ScrollViewNode) {
        self.subscribedScrollViewNodes.insert(scrollView)
    }
}

extension EnvironmentValues {
    @Entry var scrollViewProxy: _ScrollViewProxy?
}
