import Foundation

/// Ordered material intent evaluated on one connected side of the anchored surface.
public struct MeshTerrainPaintStamp: Codable, Equatable, Sendable {
    public enum Operation: Codable, Equatable, Sendable {
        case paint(layer: UInt16)
        case erase
    }

    public let id: UUID
    public let anchor: MeshTerrainSurfaceAnchor
    public let radius: Float
    public let strength: Float
    public let operation: Operation

    public init(id: UUID = UUID(), anchor: MeshTerrainSurfaceAnchor, radius: Float, strength: Float, operation: Operation) {
        self.id = id
        self.anchor = anchor
        self.radius = radius
        self.strength = strength
        self.operation = operation
    }

    func validate() throws {
        try anchor.validate()
        guard radius.isFinite, radius > 0, radius <= 256, strength.isFinite, (0...1).contains(strength) else {
            throw TriangleGeometryError.invalidInput
        }
    }
}

/// Sparse, ordered corner samples. The authoritative intent remains in the document.
public struct MeshTerrainCompiledPaint: Codable, Equatable, Sendable {
    public struct Sample: Codable, Equatable, Sendable {
        public struct Layer: Codable, Equatable, Sendable {
            public let id: UInt16
            public var weight: Float

            public init(id: UInt16, weight: Float) {
                self.id = id
                self.weight = weight
            }
        }

        public let corner: Int
        /// Premultiplied authored weights. The remainder is procedural material.
        public let layers: [Layer]

        public init(corner: Int, layers: [Layer]) {
            self.corner = corner
            self.layers = layers
        }

        private enum CodingKeys: CodingKey { case corner, layers }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            corner = try container.decode(Int.self, forKey: .corner)
            layers = try MeshTerrainDecoding.list(Layer.self, key: .layers, in: container, decoder: decoder, maximum: 32)
        }

        func validate() throws {
            guard !layers.isEmpty, layers.count <= 32,
                layers.allSatisfy({ $0.weight.isFinite && $0.weight > 0 }),
                zip(layers, layers.dropFirst()).allSatisfy({ $0.id < $1.id }),
                layers.reduce(Float(0), { $0 + $1.weight }) <= 1.00001
            else { throw TriangleGeometryError.invalidInput }
        }
    }

    public let samples: [Sample]

    public init(samples: [Sample]) { self.samples = samples }

    private enum CodingKeys: CodingKey { case samples }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        samples = try MeshTerrainDecoding.list(Sample.self, key: .samples, in: container, decoder: decoder, maximum: 262_144)
    }

    public func validate(cornerCount: Int) throws {
        guard samples.count <= 262_144 else { throw TriangleGeometryError.budgetExceeded }
        var previous = -1
        for sample in samples {
            guard sample.corner > previous, sample.corner < cornerCount else { throw TriangleGeometryError.invalidInput }
            try sample.validate()
            previous = sample.corner
        }
    }
}
