import Foundation
import Math

public enum TerrainHeightBrushOperation: String, Codable, CaseIterable, Sendable {
    case raise, lower, smooth, flatten, setHeight, ramp, terrace, noise, talus

    var usesTime: Bool {
        switch self {
        case .raise, .lower, .smooth, .flatten, .talus: true
        case .setHeight, .ramp, .terrace, .noise: false
        }
    }
}

/// A bounded grayscale alpha; decoded or imported data are validated again before a stroke executes.
public struct TerrainBrushAlpha: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let values: [UInt8]

    public init(width: Int, height: Int, values: [UInt8]) throws {
        self.width = width
        self.height = height
        self.values = values
        try validate()
    }

    private enum CodingKeys: CodingKey { case width, height, values }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let width = try container.decode(Int.self, forKey: .width)
        let height = try container.decode(Int.self, forKey: .height)
        guard (1...1_024).contains(width), (1...1_024).contains(height) else { throw TerrainHeightBrushError.invalidAlpha }
        let expected = width * height
        var encoded = try container.nestedUnkeyedContainer(forKey: .values)
        if let count = encoded.count, count != expected { throw TerrainHeightBrushError.invalidAlpha }
        var values: [UInt8] = []
        values.reserveCapacity(expected)
        while !encoded.isAtEnd {
            guard values.count < expected else { throw TerrainHeightBrushError.invalidAlpha }
            values.append(try encoded.decode(UInt8.self))
        }
        guard values.count == expected else { throw TerrainHeightBrushError.invalidAlpha }
        try self.init(width: width, height: height, values: values)
    }

    func validate() throws {
        guard (1...1_024).contains(width), (1...1_024).contains(height), values.count == width * height else {
            throw TerrainHeightBrushError.invalidAlpha
        }
    }
}

public enum TerrainBrushShape: Codable, Equatable, Sendable {
    case softRound, hardRound, square, ridge, crater, ridgedNoise
    case alpha(TerrainBrushAlpha)
}

/// Terrain-local controls. Time tools use height units/second or convergence/second;
/// stamp tools apply strength per distance-spaced dab. Angles are radians except slope/talus degrees.
public struct TerrainHeightBrushSettings: Codable, Equatable, Sendable {
    public var operation: TerrainHeightBrushOperation
    public var shape: TerrainBrushShape = .softRound
    public var radius: Float = 8
    public var strength: Float = 1
    public var falloff: Float = 1
    public var spacing: Float = 0.25
    public var rotation: Float = 0
    public var rotationJitter: Float = 0
    public var seed: UInt64 = 0
    public var targetHeight: Float?
    public var terraceStep: Float = 1
    public var noiseAmplitude: Float = 1
    public var talusAngle: Float = 30
    public var iterations: Int = 4
    public var heightRange: ClosedRange<Float>?
    public var slopeRange: ClosedRange<Float>?

    public init(operation: TerrainHeightBrushOperation, radius: Float = 8, strength: Float = 1) {
        self.operation = operation
        self.radius = radius
        self.strength = strength
    }
}

/// One input event. Time is measured in seconds from a monotonically increasing stroke clock.
public struct TerrainBrushPoint: Codable, Equatable, Sendable {
    public let position: Vector3
    public let time: Double
    public let pressure: Float

    public init(position: Vector3, time: Double, pressure: Float = 1) {
        self.position = position
        self.time = time
        self.pressure = pressure
    }
}

/// A complete gesture: its bounded data are evaluated off-thread and published as one height delta.
public struct TerrainHeightBrushStroke: Codable, Equatable, Sendable {
    public let settings: TerrainHeightBrushSettings
    public let points: [TerrainBrushPoint]

    public init(settings: TerrainHeightBrushSettings, points: [TerrainBrushPoint]) {
        self.settings = settings
        self.points = points
    }
}

public enum TerrainHeightBrushError: LocalizedError {
    case invalidParameters, invalidStroke, invalidAlpha, tooManyDabs, tooManySamples, workBudgetExceeded, missingSurface

    public var errorDescription: String? {
        switch self {
        case .invalidParameters: "Terrain brush requires finite, bounded settings"
        case .invalidStroke: "Terrain brush requires finite points, ordered times and valid pressure"
        case .invalidAlpha: "Terrain brush alpha must contain 1...1024 grayscale pixels on each axis"
        case .tooManyDabs: "Terrain brush exceeds its 4096-dab stroke budget"
        case .tooManySamples: "Terrain brush exceeds its 65536-sample stroke budget"
        case .workBudgetExceeded: "Terrain brush exceeds its bounded sample-visit budget"
        case .missingSurface: "Terrain brush requires a resident surface at its starting point"
        }
    }
}
