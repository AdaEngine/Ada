import AdaECS
import box2d
import box3d
import Synchronization

/// The physics backend that produced a performance snapshot.
public enum PhysicsPerformanceDimension: String, Codable, CaseIterable, Sendable {
    case twoD = "2D"
    case threeD = "3D"
}

/// A timed phase reported by Box2D or Box3D for one simulation step.
public enum PhysicsPerformancePhase: String, Codable, CaseIterable, Sendable {
    case step
    case pairs
    case collide
    case solve
    case mergeIslands
    case solverSetup
    case constraints
    case prepareStages
    case solveConstraints
    case prepareConstraints
    case integrateVelocities
    case warmStart
    case solveImpulses
    case integratePositions
    case relaxImpulses
    case applyRestitution
    case storeImpulses
    case splitIslands
    case transforms
    case sensorHits
    case jointEvents
    case hitEvents
    case refit
    case bullets
    case sleepIslands
    case sensors

    public var title: String {
        switch self {
        case .step: "Step"
        case .pairs: "Pairs"
        case .collide: "Collide"
        case .solve: "Solve"
        case .mergeIslands: "Merge islands"
        case .solverSetup: "Solver setup"
        case .constraints: "Constraints"
        case .prepareStages: "Prepare stages"
        case .solveConstraints: "Solve constraints"
        case .prepareConstraints: "Prepare constraints"
        case .integrateVelocities: "Integrate velocities"
        case .warmStart: "Warm start"
        case .solveImpulses: "Solve impulses"
        case .integratePositions: "Integrate positions"
        case .relaxImpulses: "Relax impulses"
        case .applyRestitution: "Apply restitution"
        case .storeImpulses: "Store impulses"
        case .splitIslands: "Split islands"
        case .transforms: "Transforms"
        case .sensorHits: "Sensor hits"
        case .jointEvents: "Joint events"
        case .hitEvents: "Hit events"
        case .refit: "Refit"
        case .bullets: "Bullets"
        case .sleepIslands: "Sleep islands"
        case .sensors: "Sensors"
        }
    }
}

/// Current and accumulated timing for a physics phase, in milliseconds.
public struct PhysicsPerformancePhaseSample: Codable, Equatable, Identifiable, Sendable {
    public var id: PhysicsPerformancePhase { phase }
    public let phase: PhysicsPerformancePhase
    public let currentMilliseconds: Double
    public let averageMilliseconds: Double
    public let maximumMilliseconds: Double
}

/// Simulation-size counters captured with a physics profile.
public struct PhysicsPerformanceCounters: Codable, Equatable, Sendable {
    public let bodyCount: Int
    public let shapeCount: Int
    public let contactCount: Int
    public let jointCount: Int
    public let islandCount: Int
    public let taskCount: Int
    public let memoryBytes: Int
    public let treeHeight: Int
}

/// An accumulated profile for one physics backend.
public struct PhysicsPerformanceSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: PhysicsPerformanceDimension { dimension }
    public let dimension: PhysicsPerformanceDimension
    public let stepCount: Int
    public let phases: [PhysicsPerformancePhaseSample]
    public let counters: PhysicsPerformanceCounters

    public var step: PhysicsPerformancePhaseSample? {
        phases.first { $0.phase == .step }
    }
}

/// Opt-in resource that accumulates the native Box2D and Box3D step profiles.
/// Insert it before building an ``AppWorlds`` instance to enable collection.
public final class PhysicsPerformanceMetrics: Resource {
    private struct Statistics: Sendable {
        var current = 0.0
        var total = 0.0
        var maximum = 0.0
        var count = 0
        var isEmpty: Bool { count < 1 }

        mutating func record(_ value: Float) {
            let value = Double(value)
            current = value
            total += value
            maximum = max(maximum, value)
            count += 1
        }
    }

    private struct Recorder: Sendable {
        var phases: [PhysicsPerformancePhase: Statistics] = [:]
        var stepCount = 0
        var counters = PhysicsPerformanceCounters(
            bodyCount: 0,
            shapeCount: 0,
            contactCount: 0,
            jointCount: 0,
            islandCount: 0,
            taskCount: 0,
            memoryBytes: 0,
            treeHeight: 0
        )

        mutating func beginStep(counters: PhysicsPerformanceCounters) {
            stepCount += 1
            self.counters = counters
        }

        mutating func record(_ phase: PhysicsPerformancePhase, _ value: Float) {
            phases[phase, default: Statistics()].record(value)
        }

        mutating func record(_ profile: b2Profile, counters: b2Counters) {
            beginStep(counters: PhysicsPerformanceCounters(from: counters))
            record(.step, profile.step)
            record(.pairs, profile.pairs)
            record(.collide, profile.collide)
            record(.solve, profile.solve)
            record(.mergeIslands, profile.mergeIslands)
            record(.prepareStages, profile.prepareStages)
            record(.solveConstraints, profile.solveConstraints)
            record(.prepareConstraints, profile.prepareConstraints)
            record(.integrateVelocities, profile.integrateVelocities)
            record(.warmStart, profile.warmStart)
            record(.solveImpulses, profile.solveImpulses)
            record(.integratePositions, profile.integratePositions)
            record(.relaxImpulses, profile.relaxImpulses)
            record(.applyRestitution, profile.applyRestitution)
            record(.storeImpulses, profile.storeImpulses)
            record(.splitIslands, profile.splitIslands)
            record(.transforms, profile.transforms)
            record(.hitEvents, profile.hitEvents)
            record(.refit, profile.refit)
            record(.bullets, profile.bullets)
            record(.sleepIslands, profile.sleepIslands)
            record(.sensors, profile.sensors)
        }

        mutating func record(_ profile: b3Profile, counters: b3Counters) {
            beginStep(counters: PhysicsPerformanceCounters(from: counters))
            record(.step, profile.step)
            record(.pairs, profile.pairs)
            record(.collide, profile.collide)
            record(.solve, profile.solve)
            record(.solverSetup, profile.solverSetup)
            record(.constraints, profile.constraints)
            record(.prepareConstraints, profile.prepareConstraints)
            record(.integrateVelocities, profile.integrateVelocities)
            record(.warmStart, profile.warmStart)
            record(.solveImpulses, profile.solveImpulses)
            record(.integratePositions, profile.integratePositions)
            record(.relaxImpulses, profile.relaxImpulses)
            record(.applyRestitution, profile.applyRestitution)
            record(.storeImpulses, profile.storeImpulses)
            record(.splitIslands, profile.splitIslands)
            record(.transforms, profile.transforms)
            record(.sensorHits, profile.sensorHits)
            record(.jointEvents, profile.jointEvents)
            record(.hitEvents, profile.hitEvents)
            record(.refit, profile.refit)
            record(.bullets, profile.bullets)
            record(.sleepIslands, profile.sleepIslands)
            record(.sensors, profile.sensors)
        }

        func snapshot(dimension: PhysicsPerformanceDimension) -> PhysicsPerformanceSnapshot? {
            guard stepCount > 0 else {
                return nil
            }
            let values = PhysicsPerformancePhase.allCases.compactMap { phase -> PhysicsPerformancePhaseSample? in
                guard let statistics = phases[phase], !statistics.isEmpty else {
                    return nil
                }
                return PhysicsPerformancePhaseSample(
                    phase: phase,
                    currentMilliseconds: statistics.current,
                    averageMilliseconds: statistics.total / Double(statistics.count),
                    maximumMilliseconds: statistics.maximum
                )
            }
            return PhysicsPerformanceSnapshot(
                dimension: dimension,
                stepCount: stepCount,
                phases: values,
                counters: counters
            )
        }
    }

    private struct State: Sendable {
        var twoD = Recorder()
        var threeD = Recorder()
    }

    private let state = Mutex(State())

    public init() {}

    public var snapshots: [PhysicsPerformanceSnapshot] {
        state.withLock { state in
            [
                state.twoD.snapshot(dimension: .twoD),
                state.threeD.snapshot(dimension: .threeD),
            ]
            .compactMap { $0 }
        }
    }

    func record(_ profile: b2Profile, counters: b2Counters) {
        state.withLock { state in
            state.twoD.record(profile, counters: counters)
        }
    }

    func record(_ profile: b3Profile, counters: b3Counters) {
        state.withLock { state in
            state.threeD.record(profile, counters: counters)
        }
    }
}

extension PhysicsPerformanceCounters {
    init(from counters: b2Counters) {
        self.init(
            bodyCount: Int(counters.bodyCount),
            shapeCount: Int(counters.shapeCount),
            contactCount: Int(counters.contactCount),
            jointCount: Int(counters.jointCount),
            islandCount: Int(counters.islandCount),
            taskCount: Int(counters.taskCount),
            memoryBytes: Int(counters.byteCount),
            treeHeight: Int(counters.treeHeight)
        )
    }

    init(from counters: b3Counters) {
        self.init(
            bodyCount: Int(counters.bodyCount),
            shapeCount: Int(counters.shapeCount),
            contactCount: Int(counters.contactCount),
            jointCount: Int(counters.jointCount),
            islandCount: Int(counters.islandCount),
            taskCount: Int(counters.taskCount),
            memoryBytes: Int(counters.byteCount),
            treeHeight: Int(counters.treeHeight)
        )
    }
}
