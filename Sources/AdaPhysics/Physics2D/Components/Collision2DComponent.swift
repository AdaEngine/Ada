//
//  Collision2DComponent.swift
//  AdaEngine
//
//  Created by v.prusakov on 7/11/22.
//

import AdaECS
import AdaUtils

@Component
public struct Collision2DComponent: Sendable, Codable {
    internal var runtimeBody: Body2D?
    internal private(set) var shapes: [Shape2DResource] = []

    /// The physics body’s mode, indicating how or if it moves.
    public var mode: Mode

    /// The physics body's filter.
    public var filter: CollisionFilter

    /// Custom debug color.
    public var debugColor: Color?

    public init(
        shapes: [Shape2DResource],
        mode: Mode = .default,
        filter: CollisionFilter = CollisionFilter()
    ) {
        self.mode = mode
        self.shapes = shapes
        self.filter = filter
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.shapes = try container.decode([Shape2DResource].self, forKey: .shapes)
        self.mode = try container.decode(Mode.self, forKey: .mode)
        self.filter = try container.decode(CollisionFilter.self, forKey: .filter)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.shapes, forKey: .shapes)
        try container.encode(self.filter, forKey: .filter)
        try container.encode(self.mode, forKey: .mode)
    }

    enum CodingKeys: CodingKey {
        case shapes
        case mode
        case filter
    }
}

extension Collision2DComponent {
    public enum Mode: Codable, Sendable {
        case trigger
        case `default`
    }
}
