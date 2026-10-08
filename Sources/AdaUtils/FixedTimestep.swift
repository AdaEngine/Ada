//
//  FixedTimestep.swift
//  AdaEngine
//
//  Created by v.prusakov on 2/6/23.
//

/// FixedTimestep enable your systems run at a fixed timestep between executions.
/// This does not guarentee you that the elapsed time will be exactly fixed.
public struct FixedTimestep: Sendable {
    public struct AdvanceResult: Sendable {
        /// The elapsed time between executions.
        public internal(set) var fixedTime: TimeInterval
        /// The flag that tell you, that is a fixed tick.
        public internal(set) var isFixedTick: Bool
    }

    /// The amount of time each step takes.
    public var step: TimeInterval

    var accumulator: TimeInterval = 0

    /// Creates a FixedTimestep that ticks once every step seconds.
    public init(step: TimeInterval = 0) {
        self.step = step
    }

    /// Creates a FixedTimestep that ticks once every `stepsPerSecond` times per second.
    public init(stepsPerSecond: Int) {
        precondition(stepsPerSecond > 0)
        self.step = 1 / TimeInterval(stepsPerSecond)
    }

    /// - Parameter deltaTime: The delta time between frame updates.
    /// - Returns: Advanced result with elapsed time and flag. Advance result can returns zero if that isn't fixed update.
    public mutating func advance(with deltaTime: TimeInterval) -> AdvanceResult {
        var result = AdvanceResult(fixedTime: 0, isFixedTick: false)

        if deltaTime > 1 {
            return result
        }

        self.accumulator += deltaTime

        while self.accumulator >= self.step {
            self.accumulator -= self.step
            result.fixedTime += self.step
            result.isFixedTick = true
        }

        return result
    }
}
