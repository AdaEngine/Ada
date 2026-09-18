import AdaUtils
import Logging
import Tracing

/// Represents a scheduler stage in the ECS update loop.
public struct SchedulerName: Hashable, Equatable, RawRepresentable, CustomStringConvertible, Sendable {
    /// The raw value of the scheduler name.
    public let rawValue: String

    /// The description of the scheduler name.
    public var description: String { rawValue }

    /// Initialize a new scheduler name.
    /// - Parameter rawValue: The raw value of the scheduler name.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension SchedulerName: ExpressibleByStringLiteral {
    public init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }
}

/// Default schedulers.
extension SchedulerName {
    /// The startup scheduler that will run once per world.
    public static let startup = SchedulerName(rawValue: "startup")

    /// The pre-update scheduler.
    public static let preUpdate = SchedulerName(rawValue: "preUpdate")

    /// The update scheduler.
    public static let update = SchedulerName(rawValue: "update")

    /// The post-update scheduler.
    public static let postUpdate = SchedulerName(rawValue: "postUpdate")

    /// The default scheduler order.
    public static var `default`: [SchedulerName] {
        return [
            .preUpdate,
            .update,
            .postUpdate,
        ]
    }
}

/// Internal structure to manage schedulers and their order.
public final class Schedulers: @unchecked Sendable {
    private(set) var schedulerLabels: [SchedulerName]
    private var schedulers: [SchedulerName: Scheduler]
    private let logger: Logger = Logger(label: "org.adaengine.ecs.schedulers")

    /// Initialize a new schedulers.
    /// - Parameter schedulers: The schedulers to initialize.
    public init(_ schedulers: [SchedulerName] = []) {
        self.schedulerLabels = schedulers
        self.schedulers = Dictionary(
            uniqueKeysWithValues: schedulerLabels.map { ($0, Scheduler(name: $0)) }
        )
    }

    /// Set the schedulers.
    /// - Parameter schedulers: The schedulers to set.
    public func setSchedulers(_ schedulers: [SchedulerName]) {
        self.schedulerLabels = schedulers
        self.schedulers = Dictionary(
            uniqueKeysWithValues: schedulerLabels.map { ($0, Scheduler(name: $0)) }
        )
    }

    /// Append a scheduler.
    /// - Parameter scheduler: The scheduler to append.
    public func append(_ scheduler: Scheduler) {
        schedulerLabels.append(scheduler.name)
        schedulers[scheduler.name] = scheduler
    }

    /// Insert a scheduler after a specific scheduler.
    /// - Parameter scheduler: The scheduler to insert.
    /// - Parameter after: The scheduler to insert after.
    public func insert(_ scheduler: Scheduler, after: SchedulerName) {
        if schedulers[scheduler.name] != nil {
            logger.error("Scheduler already exists")
            return
        }

        if let idx = schedulerLabels.firstIndex(of: after) {
            schedulerLabels.insert(scheduler.name, at: idx + 1)
        } else {
            schedulerLabels.append(scheduler.name)
        }
    }

    /// Check if the schedulers contains a specific scheduler.
    /// - Parameter scheduler: The scheduler to check.
    /// - Returns: True if the schedulers contains the scheduler, otherwise false.
    public func contains(_ scheduler: SchedulerName) -> Bool {
        self.schedulers[scheduler] != nil
    }

    /// Insert a scheduler before a specific scheduler.
    /// - Parameter scheduler: The scheduler to insert.
    /// - Parameter before: The scheduler to insert before.
    public func insert(_ scheduler: Scheduler, before: SchedulerName) {
        if schedulers[scheduler.name] != nil {
            logger.error("Scheduler already exists")
            return
        }

        if let idx = schedulerLabels.firstIndex(of: before) {
            schedulerLabels.insert(scheduler.name, at: idx)
        } else {
            schedulerLabels.append(scheduler.name)
        }
    }

    /// Get a scheduler by its name.
    /// - Parameter scheduler: The name of the scheduler.
    /// - Returns: The scheduler if it exists, otherwise nil.
    public func getScheduler(_ scheduler: SchedulerName) -> Scheduler? {
        self.schedulers[scheduler]
    }

    public func getScope(
        for schedulerName: SchedulerName,
        scopeBlock: (inout Scheduler) async -> Void
    ) async {
        if var scheduler = self.schedulers[schedulerName] {
            await scopeBlock(&scheduler)
            self.schedulers[schedulerName] = scheduler
        } else {
            logger.error("Scheduler \(schedulerName) not found")
        }
    }

    /// Add system to scheduler. If scheduler not exists, than we create it.
    public func addSystem<T: System>(_ system: T, for schedulerName: SchedulerName) {
        if schedulers[schedulerName] == nil {
            schedulerLabels.append(schedulerName)
        }
        self.schedulers[schedulerName, default: Scheduler(name: schedulerName)]
            .systemGraph
            .addSystem(system)
    }

    public func removeSystem<T: System>(_ system: T.Type, for schedulerName: SchedulerName) {
        guard var scheduler = schedulers[schedulerName] else {
            return
        }
        scheduler.systemGraph.removeSystem(system)
        self.schedulers[schedulerName] = scheduler
    }
}

/// A resource that contains the delta time.
public struct DeltaTime: Resource {
    /// The delta time.
    public let deltaTime: AdaUtils.TimeInterval

    /// Initialize a new delta time.
    /// - Parameter deltaTime: The delta time.
    public init(deltaTime: AdaUtils.TimeInterval) {
        self.deltaTime = deltaTime
    }
}

/// A resource that contains the delta time.
public struct FixedTime: Resource {
    /// The delta time.
    public let deltaTime: AdaUtils.TimeInterval

    /// Initialize a new delta time.
    /// - Parameter deltaTime: The delta time.
    public init(deltaTime: AdaUtils.TimeInterval) {
        self.deltaTime = deltaTime
    }
}

/// A resource that contains the elapsed time from launch.
public struct ElapsedTime: Resource {
    /// The elaped time.
    public let elapsedTime: AdaUtils.TimeInterval

    /// Initialize a new delta time.
    /// - Parameter deltaTime: The delta time.
    public init(elapsedTime: AdaUtils.TimeInterval = 0.0) {
        self.elapsedTime = elapsedTime
    }
}

/// A resource that contains the order of the default scheduler.
public struct DefaultSchedulerOrder: Resource {
    public let order: [SchedulerName]

    public init(order: [SchedulerName] = [.preUpdate, .update, .postUpdate]) {
        self.order = order
    }
}

/// A system that runs the default scheduler.
@PlainSystem
public struct DefaultSchedulerRunner: Sendable {
    @Res
    private var order: DefaultSchedulerOrder?

    @Local
    private var lastUpdate: LongTimeInterval = 0

    @Local
    private var isFirstRun = true

    public init(world _: World) {}

    public func update(context: UpdateContext) async {
        let world = context.world
        /// Run startup scheduler once per app run.
        if isFirstRun {
            await world.runScheduler(.startup)
            isFirstRun = false
        }
        let order = order?.order ?? []
        for scheduler in order {
            await world.runScheduler(scheduler)
        }
    }
}

/// A scheduler that runs systems in a specific order.
public struct Scheduler: Sendable {
    public typealias RunnerBlock = (any System) -> Void

    private static func defaultGraphExecutor() -> any SystemsGraphExecutor {
        #if WASI || SINGLE_THREAD_SCHEDULER
            return SingleThreadedSystemsGraphExecutor()
        #else
            return MultiThreadedSystemsGraphExecutor()
        #endif
    }

    /// The name of the scheduler.
    public let name: SchedulerName

    /// The system graph of the scheduler.
    public var systemGraph: SystemsGraph = SystemsGraph()

    /// The graph executor of the scheduler.
    public var graphExecutor: any SystemsGraphExecutor

    /// The last update time of the scheduler.
    @Local private var lastUpdate: LongTimeInterval = 0

    /// Initialize a new scheduler.
    /// - Parameter name: The name of the scheduler.
    public init(
        name: SchedulerName,
        graphExecutor: (any SystemsGraphExecutor)? = nil
    ) {
        self.name = name
        self.graphExecutor = graphExecutor ?? Self.defaultGraphExecutor()
    }

    /// Run the scheduler.
    /// - Parameter world: The world to run the scheduler on.
    public mutating func run(world: World) async {
        let now = Time.absolute
        let deltaTime = TimeInterval(max(0, now - self.lastUpdate))
        self.lastUpdate = now

        if self.systemGraph.isChanged {
            self.systemGraph.linkSystems()
            self.graphExecutor.initialize(self.systemGraph)
        }

        let name = self.name
        let elapsedTime = TimeInterval(lastUpdate)
        var executor = self.graphExecutor
        let graph = self.systemGraph

        let span = AdaTrace.startSpan(
            lazyName: "Scheduler.run.\(name.rawValue)",
            attributes: [
                "ada.profile.category": "scheduler",
                "ada.scheduler.name": .string(name.rawValue),
                "ada.world.name": .string(world.name ?? "UnknownWorld"),
            ]
        )
        defer {
            span.end()
        }
        world.insertResource(DeltaTime(deltaTime: deltaTime))
        world.insertResource(ElapsedTime(elapsedTime: elapsedTime))

        await executor.execute(graph, world: world, scheduler: name)
        self.graphExecutor = executor
    }
}
