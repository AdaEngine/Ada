//
//  LinearGradient.swift
//  AdaEngine
//
//  Created by Codex on 17.04.2026.
//

import AdaUtils
import Math

/// A normalized point in a view's coordinate space.
public struct UnitPoint: Hashable, Sendable {
    public var x: Float
    public var y: Float

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }
}

extension UnitPoint {
    public static let zero = UnitPoint(x: 0, y: 0)
    public static let center = UnitPoint(x: 0.5, y: 0.5)
    public static let leading = UnitPoint(x: 0, y: 0.5)
    public static let trailing = UnitPoint(x: 1, y: 0.5)
    public static let top = UnitPoint(x: 0.5, y: 0)
    public static let bottom = UnitPoint(x: 0.5, y: 1)
    public static let topLeading = UnitPoint(x: 0, y: 0)
    public static let topTrailing = UnitPoint(x: 1, y: 0)
    public static let bottomLeading = UnitPoint(x: 0, y: 1)
    public static let bottomTrailing = UnitPoint(x: 1, y: 1)
}

extension UnitPoint {
    var asVector2: Vector2 {
        Vector2(x: x, y: y)
    }
}

/// A color gradient defined by color stops.
public struct Gradient: Hashable, Sendable {
    public struct Stop: Hashable, Sendable {
        public var color: Color
        public var location: Float

        public init(color: Color, location: Float) {
            self.color = color
            self.location = location
        }
    }

    private var storage: [Stop]

    public var stops: [Stop] {
        get { storage }
        set { storage = Self.normalizeStops(newValue) }
    }

    public init(stops: [Stop]) {
        self.storage = Self.normalizeStops(stops)
    }
}

extension Gradient {
    static let maximumStops = 16

    static func evenlyDistributedStops(colors: [Color]) -> [Stop] {
        switch colors.count {
        case 0:
            return [.init(color: .clear, location: 0), .init(color: .clear, location: 1)]
        case 1:
            return [.init(color: colors[0], location: 0), .init(color: colors[0], location: 1)]
        default:
            let lastIndex = max(colors.count - 1, 1)
            return colors.enumerated()
                .map { index, color in
                    Stop(
                        color: color,
                        location: Float(index) / Float(lastIndex)
                    )
                }
        }
    }

    static func normalizeStops(_ stops: [Stop]) -> [Stop] {
        var normalized =
            stops
            .map { Stop(color: $0.color, location: min(max($0.location, 0), 1)) }
            .sorted { lhs, rhs in
                if lhs.location == rhs.location {
                    return lhs.color.toHex < rhs.color.toHex
                }
                return lhs.location < rhs.location
            }

        if normalized.count > maximumStops {
            guard let last = normalized.last else {
                return []
            }
            normalized = Array(normalized.prefix(maximumStops))
            normalized[maximumStops - 1] = last
        }

        switch normalized.count {
        case 0:
            return [
                Stop(color: .clear, location: 0),
                Stop(color: .clear, location: 1),
            ]
        case 1:
            let stop = normalized[0]
            return [
                Stop(color: stop.color, location: 0),
                Stop(color: stop.color, location: 1),
            ]
        default:
            return normalized
        }
    }
}

struct ResolvedLinearGradient: Hashable, Sendable {
    let startPoint: Vector2
    let endPoint: Vector2
    let stops: [Gradient.Stop]

    init(
        startPoint: UnitPoint,
        endPoint: UnitPoint,
        stops: [Gradient.Stop]
    ) {
        self.startPoint = startPoint.asVector2
        self.endPoint = endPoint.asVector2
        self.stops = Gradient.normalizeStops(stops)
    }

    func applyingOpacity(_ opacity: Float) -> Self {
        guard opacity != 1 else {
            return self
        }

        return Self(
            startPoint: UnitPoint(x: startPoint.x, y: startPoint.y),
            endPoint: UnitPoint(x: endPoint.x, y: endPoint.y),
            stops: stops.map { stop in
                Gradient.Stop(
                    color: stop.color.opacity(stop.color.alpha * opacity),
                    location: stop.location
                )
            }
        )
    }
}

/// A view that fills its bounds with a linear gradient.
public struct LinearGradient: View, ViewNodeBuilder {
    public typealias Body = Never
    public var body: Never { fatalError("Unreachable code") }

    public let gradient: Gradient
    public let startPoint: UnitPoint
    public let endPoint: UnitPoint

    public init(gradient: Gradient, startPoint: UnitPoint, endPoint: UnitPoint) {
        self.gradient = gradient
        self.startPoint = startPoint
        self.endPoint = endPoint
    }

    public init(colors: [Color], startPoint: UnitPoint, endPoint: UnitPoint) {
        self.init(
            gradient: Gradient(stops: Gradient.evenlyDistributedStops(colors: colors)),
            startPoint: startPoint,
            endPoint: endPoint
        )
    }

    public init(stops: [Gradient.Stop], startPoint: UnitPoint, endPoint: UnitPoint) {
        self.init(
            gradient: Gradient(stops: stops),
            startPoint: startPoint,
            endPoint: endPoint
        )
    }

    func buildViewNode(in _: BuildContext) -> ViewNode {
        let resolvedGradient = ResolvedLinearGradient(
            startPoint: self.startPoint,
            endPoint: self.endPoint,
            stops: self.gradient.stops
        )
        return CanvasViewNode(
            content: self,
            drawBlock: { graphicsContext, size in
                graphicsContext.drawLinearGradient(
                    resolvedGradient,
                    in: Rect(origin: .zero, size: size)
                )
            }
        )
    }
}
