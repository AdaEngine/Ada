//
//  GeometryReader.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 24.06.2024.
//

import AdaUtils
import Math
import Observation

// MARK: - Coordinate Space

/// A view coordinate space.
public enum ViewCoordinateSpace {
    /// A local view coordinate space.
    case local
    /// A global view coordinate space.
    case global
    /// A scroll view coordinate space.
    case scrollView
    /// A named view coordinate space.
    case named(AnyHashable)

    /// The scroll view id.
    internal static let scrollViewId = "_ScrollView"
}

/// A protocol that defines a view coordinate space.
public protocol ViewCoordinateSpaceProtocol {
    /// The coordinate space.
    var coordinateSpace: ViewCoordinateSpace { get }
}

/// A global view coordinate space.
public struct GlobalViewCoordinateSpace: ViewCoordinateSpaceProtocol {
    public let coordinateSpace: ViewCoordinateSpace = .global
}

/// A local view coordinate space.
public struct LocalViewCoordinateSpace: ViewCoordinateSpaceProtocol {
    public let coordinateSpace: ViewCoordinateSpace = .local
}

extension ViewCoordinateSpaceProtocol where Self == GlobalViewCoordinateSpace {
    public static var global: GlobalViewCoordinateSpace {
        GlobalViewCoordinateSpace()
    }
}

extension ViewCoordinateSpaceProtocol where Self == LocalViewCoordinateSpace {
    public static var local: LocalViewCoordinateSpace {
        LocalViewCoordinateSpace()
    }
}

extension ViewCoordinateSpaceProtocol where Self == LocalViewCoordinateSpace {
    public static func named<H: Hashable>(_ name: H) -> NamedViewCoordinateSpace {
        NamedViewCoordinateSpace(name)
    }
}

/// A named view coordinate space.
public struct NamedViewCoordinateSpace: Equatable, ViewCoordinateSpaceProtocol {
    let name: AnyHashable
    public let coordinateSpace: ViewCoordinateSpace

    /// Initialize a new named view coordinate space.
    ///
    /// - Parameter name: The name of the named view coordinate space.
    init<H: Hashable>(_ name: H) {
        self.name = name
        self.coordinateSpace = .named(AnyHashable(name))
    }

    /// Check if two named view coordinate spaces are equal.
    ///
    /// - Parameters:
    ///   - lhs: The left-hand side of the equality check.
    ///   - rhs: The right-hand side of the equality check.
    /// - Returns: A Boolean value indicating whether the two named view coordinate spaces are equal.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        return lhs.name == rhs.name
    }

    /// Create a new named view coordinate space.
    ///
    /// - Parameter name: The name of the named view coordinate space.
    /// - Returns: A new named view coordinate space.
    public static func named<H: Hashable>(_ name: H) -> Self {
        Self(name)
    }
}

// MARK: - Geometry Reader

/// A geometry proxy.
@MainActor
public struct GeometryProxy {
    /// The named coordinate space container.
    let namedCoordinateSpaceContainer: NamedViewCoordinateSpaceContainer

    /// The local frame of the geometry proxy.
    let localFrame: Rect

    /// The global frame of the geometry proxy.
    let globalFrame: Rect

    /// The node that owns this proxy. When available, coordinate-space queries
    /// resolve against the current tree position so ancestor relayouts do not
    /// leave captured proxies with stale global origins.
    weak var node: ViewNode?

    /// The size of the geometry proxy.
    ///
    /// - Returns: The size of the geometry proxy.
    public var size: Size {
        return localFrame.size
    }

    /// Get the frame of the geometry proxy in a given coordinate space.
    ///
    /// - Parameter coordinateSpace: The coordinate space.
    /// - Returns: The frame of the geometry proxy in the given coordinate space.
    public func frame(in coordinateSpace: ViewCoordinateSpaceProtocol) -> Rect {
        namedCoordinateSpaceContainer.compact()
        switch coordinateSpace.coordinateSpace {
        case .local:
            return self.localFrame
        case .global:
            return self.resolvedGlobalFrame
        case .scrollView:
            return frame(relativeTo: ViewCoordinateSpace.scrollViewId)
        case let .named(value):
            return frame(relativeTo: value)
        }
    }

    private var resolvedGlobalFrame: Rect {
        node?.visualAbsoluteFrame() ?? globalFrame
    }

    private func frame(relativeTo coordinateSpace: AnyHashable) -> Rect {
        guard let container = namedCoordinateSpaceContainer.containers[coordinateSpace]?.value else {
            return .zero
        }

        let containerFrame = container.visualAbsoluteFrame()
        let globalFrame = resolvedGlobalFrame
        return Rect(
            x: globalFrame.origin.x - containerFrame.origin.x,
            y: globalFrame.origin.y - containerFrame.origin.y,
            width: globalFrame.width,
            height: globalFrame.height
        )
    }
}

/// A geometry reader.
public struct GeometryReader<Content: View>: View, ViewNodeBuilder {
    public typealias Body = Never
    public var body: Never { fatalError("Unreachable code") }

    let content: (GeometryProxy) -> Content

    /// Initialize a new geometry reader.
    ///
    /// - Parameter content: The content of the geometry reader.
    public init(@ViewBuilder content: @escaping (GeometryProxy) -> Content) {
        self.content = content
    }

    /// Build a view node.
    ///
    /// - Parameter context: The build context.
    /// - Returns: The view node.
    func buildViewNode(in _: BuildContext) -> ViewNode {
        GeometryReaderViewNode(contentProxy: content, content: self)
    }
}

/// A geometry reader view node.
final class GeometryReaderViewNode<Content: View>: ViewContainerNode {
    /// The content proxy.
    private var contentProxy: (GeometryProxy) -> Content
    private var lastContentSignature: ContentSignature?
    private var contentNeedsRebuild = true

    private struct ContentSignature: Equatable {
        let frame: Rect
        let globalFrame: Rect
        let environmentVersion: UInt64
    }

    /// Initialize a new geometry reader view node.
    ///
    /// - Parameter contentProxy: The content proxy.
    /// - Parameter content: The content.
    init<Root: View>(contentProxy: @escaping (GeometryProxy) -> Content, content: Root) {
        self.contentProxy = contentProxy
        super.init(content: content, buildImmediately: false, body: { _ in _ViewListOutputs(outputs: []) })
    }

    override func update(from newNode: ViewNode) {
        guard let geometryReaderNode = newNode as? GeometryReaderViewNode<Content> else {
            super.update(from: newNode)
            return
        }

        // GeometryReader content depends on its laid-out frame and must be rebuilt
        // only from performLayout(), where a valid GeometryProxy is available.
        // Calling ViewContainerNode.update(from:) here would install the placeholder
        // empty body from the fresh node and immediately reconcile children to [],
        // which can make the view disappear until the next layout pass.
        self.contentProxy = geometryReaderNode.contentProxy
        self.markInspectionRedraw()
        self.environmentTransform = geometryReaderNode.environmentTransform
        self.structuralIdentity = geometryReaderNode.structuralIdentity
        self.accessibilityIdentifier = geometryReaderNode.accessibilityIdentifier

        var resolvedEnvironment = geometryReaderNode.environment
        if !resolvedEnvironment.animationsDisabled,
            resolvedEnvironment.animationController == nil,
            let animationController = self.environment.animationController {
            resolvedEnvironment.animationController = animationController
        }
        self.applyResolvedEnvironmentSilently(resolvedEnvironment)
        self.setContent(geometryReaderNode.content)

        self.contentNeedsRebuild = true
        self.markNeedsLayout()
        self.invalidateNearestLayer()
        owner?.containerView?.setNeedsLayout()
    }

    /// Perform the layout of the geometry reader view node.
    ///
    /// - Returns: The layout of the geometry reader view node.
    override func performLayout() {
        let signature = self.currentContentSignature()
        if contentNeedsRebuild || lastContentSignature != signature {
            self.rebuildContent(for: signature)
        }

        let proposal = ProposedViewSize(width: self.frame.width, height: self.frame.height)
        for node in self.nodes {
            node.place(in: .zero, anchor: .topLeading, proposal: proposal)
        }

        self.invalidateLayerIfNeeded()
    }

    override func place(in origin: Point, anchor: AnchorPoint, proposal: ProposedViewSize, measuredSize size: Size) {
        super.place(in: origin, anchor: anchor, proposal: proposal, measuredSize: size)

        let signature = self.currentContentSignature()
        guard !contentNeedsRebuild, lastContentSignature != signature else {
            return
        }

        self.performLayout()
        self.markLayoutClean()
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        let resolvedSize = proposal.replacingUnspecifiedDimensions()
        return resolvedSize
    }

    /// Invalidate the content of the geometry reader view node.
    ///
    /// - Returns: The invalidated content of the geometry reader view node.
    override func invalidateContent() {
        self.contentNeedsRebuild = true
        self.markNeedsLayout()
        self.invalidateNearestLayer()
        owner?.containerView?.setNeedsLayout()
    }

    private func currentContentSignature() -> ContentSignature {
        ContentSignature(
            frame: self.frame,
            globalFrame: self.visualAbsoluteFrame(),
            environmentVersion: self.environment.version
        )
    }

    private func rebuildContent(for signature: ContentSignature) {
        UILayoutDebugCounters.recordContentInvalidation()
        UILayoutDebugCounters.recordRebuild()
        let observationRevision = beginContentObservation()
        var environment = self.environment
        let disablesAnimation = shouldDisableAnimation(for: signature)
        if disablesAnimation {
            environment.animationController = nil
        }
        let context = _ViewInputs(parentNode: self, environment: environment)
        let proxy = GeometryProxy(
            namedCoordinateSpaceContainer: environment.coordinateSpaces,
            localFrame: Rect(origin: .zero, size: self.frame.size),
            globalFrame: signature.globalFrame,
            node: self
        )
        let outputs = withObservationTracking {
            let content = self.contentProxy(proxy)
            return Content._makeListView(_ViewGraphNode(value: content), inputs: _ViewListInputs(input: context)).outputs
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleObservedContentInvalidation(revision: observationRevision)
            }
        }
        let nodes = outputs.map(\.node)

        self.reconcileChildNodes(from: nodes)
        self.lastContentSignature = signature
        self.contentNeedsRebuild = false
    }

    override func invalidateObservedContent() {
        // Geometry-dependent bodies are rebuilt by the subsequent layout pass.
        invalidateContent()
    }

    private func shouldDisableAnimation(for signature: ContentSignature) -> Bool {
        guard let lastContentSignature else {
            return false
        }

        return lastContentSignature.frame.size != signature.frame.size
    }
}

// MARK: - Environment

/// A named view coordinate space container.
/// Environment propagation and coordinate-space registration run on the UI
/// actor; the unchecked conformance only lets EnvironmentValues store the
/// reference as a Sendable value.
final class NamedViewCoordinateSpaceContainer: @unchecked Sendable {
    /// The containers of the named view coordinate space.
    var containers: [AnyHashable: WeakBox<ViewNode>] = [:]

    func compact() {
        containers = containers.filter { !$0.value.isEmpty }
    }
}

/// A protocol that defines a coordinate space.
public protocol CoordinateSpace {
    /// The coordinate space.
    var coordinateSpace: ViewCoordinateSpace { get }
}

extension EnvironmentValues {
    /// The coordinate spaces.
    @Entry var coordinateSpaces: NamedViewCoordinateSpaceContainer = NamedViewCoordinateSpaceContainer()
}

extension View {
    /// The coordinate space of the view.
    ///
    /// - Parameter named: The named view coordinate space.
    /// - Returns: The coordinate space of the view.
    public func coordinateSpace(_ named: NamedViewCoordinateSpace) -> some View {
        self.modifier(CoordinateSpaceViewModifier(named: named, content: self))
    }
}

struct CoordinateSpaceViewModifier<Content: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never

    let named: NamedViewCoordinateSpace
    let content: Content

    func buildViewNode(in context: BuildContext) -> ViewNode {
        let node = CoordinateSpaceViewModifierNode(
            named: named,
            contentNode: context.makeNode(from: content),
            content: content
        )
        node.updateEnvironment(context.environment)
        return node
    }
}

private final class CoordinateSpaceViewModifierNode: ViewModifierNode {
    private let named: NamedViewCoordinateSpace

    init<Content: View>(named: NamedViewCoordinateSpace, contentNode: ViewNode, content: Content) {
        self.named = named
        super.init(contentNode: contentNode, content: content)
    }

    override func update(from newNode: ViewNode) {
        super.update(from: newNode)
        updateEnvironment(environment)
    }

    override func updateEnvironment(_ environment: EnvironmentValues) {
        var environment = environment
        let previousVersion = environment.version
        environment.coordinateSpaces.compact()

        if contentNode is ScrollViewNode {
            environment.coordinateSpaces.containers[ViewCoordinateSpace.scrollViewId] = WeakBox(contentNode)
        }

        environment.coordinateSpaces.containers[named.name] = WeakBox(contentNode)
        environment.ensureVersionDiffers(from: previousVersion)
        super.updateEnvironment(environment)
    }
}
