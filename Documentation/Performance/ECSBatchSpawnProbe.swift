import AdaECS
import AdaUtils
import Darwin
import Dispatch
import Foundation

@Component
struct BatchPosition { var x: Int; var y: Int }
@Component
struct BatchVelocity: DefaultValue {
    var x: Int
    var y: Int
    static var defaultValue: Self { Self(x: 1, y: -1) }
}
@Component
struct BatchParent { var value: Int }
@Component(required: [BatchVelocity.self])
struct BatchStaticParent { var value: Int }
@Component
struct BatchTag {}

let health = RuntimeComponentDescriptor(stableID: "probe.batch.health", name: "Health", fieldNames: ["value"], defaultValues: [.int(3)])
let score = RuntimeComponentDescriptor(stableID: "probe.batch.score", name: "Score", fieldNames: ["value"], defaultValues: [.int(7)])

func cpuNanoseconds() -> UInt64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return UInt64(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000_000_000
        + UInt64(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) * 1_000
}

enum Scenario: String, CaseIterable {
    case native, registeredRequirement, staticRequirement, runtime, mixed

    func configure(_ world: World) {
        if self == .registeredRequirement {
            world.registerRequiredComponent(BatchVelocity.self, for: BatchParent.self) { BatchVelocity(x: 1, y: -1) }
        }
    }

    @ComponentsBuilder
    func bundle(_ index: Int) -> ComponentsBundle {
        switch self {
        case .native:
            BatchPosition(x: index, y: index)
            BatchVelocity(x: 1, y: -1)
        case .registeredRequirement:
            BatchParent(value: index)
        case .staticRequirement:
            BatchStaticParent(value: index)
        case .runtime:
            health.makeDefault()
            score.makeDefault()
        case .mixed:
            BatchPosition(x: index, y: index)
            BatchVelocity(x: 1, y: -1)
            if index % 2 == 1 { BatchTag() }
        }
    }

    @inline(never)
    func single(_ world: World, count: Int) -> [Entity] {
        var result: [Entity] = []
        result.reserveCapacity(count)
        for index in 0..<count { result.append(world.spawn(bundle: bundle(index))) }
        return result
    }

    #if BATCH_SPAWN_PROBE
    @inline(never)
    func batch(_ world: World, count: Int) -> [Entity] {
        world.spawnBatch(count: count, components: bundle)
    }
    #endif

    func verify(_ world: World, entities: [Entity], count: Int) {
        precondition(entities.count == count && world.getEntities().count == count)
        for index in 0..<count {
            let entity = entities[index]
            switch self {
            case .native, .mixed:
                precondition(world.get(BatchPosition.self, from: entity.id)?.x == index)
                precondition(world.get(BatchVelocity.self, from: entity.id)?.y == -1)
                if self == .mixed { precondition(world.has(BatchTag.self, in: entity.id) == (index % 2 == 1)) }
            case .registeredRequirement:
                precondition(world.get(BatchParent.self, from: entity.id)?.value == index)
                precondition(world.get(BatchVelocity.self, from: entity.id)?.y == -1)
            case .staticRequirement:
                precondition(world.get(BatchStaticParent.self, from: entity.id)?.value == index)
                precondition(world.get(BatchVelocity.self, from: entity.id)?.y == -1)
            case .runtime:
                precondition(world.getRuntimeComponent(health.componentID, from: entity.id)?.values == [.int(3)])
                precondition(world.getRuntimeComponent(score.componentID, from: entity.id)?.values == [.int(7)])
            }
        }
    }
}

let samples = 30
var results: [[String: Any]] = []
for count in [4_000, 16_000, 64_000] {
    for scenario in Scenario.allCases {
        var modes = ["single"]
        #if BATCH_SPAWN_PROBE
        modes.append("batch")
        #endif
        for mode in modes {
            var wall: [UInt64] = []
            var cpu: [UInt64] = []
            for sample in -3..<samples {
                let world = World()
                scenario.configure(world)
                let cpuStart = cpuNanoseconds()
                let start = DispatchTime.now().uptimeNanoseconds
                let entities: [Entity]
                #if BATCH_SPAWN_PROBE
                entities = mode == "batch" ? scenario.batch(world, count: count) : scenario.single(world, count: count)
                #else
                entities = scenario.single(world, count: count)
                #endif
                let end = DispatchTime.now().uptimeNanoseconds
                let cpuEnd = cpuNanoseconds()
                scenario.verify(world, entities: entities, count: count)
                if sample >= 0 { wall.append(end - start); cpu.append(cpuEnd - cpuStart) }
                world.clear()
            }
            wall.sort()
            cpu.sort()
            let row: [String: Any] = ["scenario": scenario.rawValue, "mode": mode, "entities": count, "samples": samples,
                "cpu_p50_ns": cpu[samples / 2], "cpu_p25_ns": cpu[samples / 4], "cpu_p75_ns": cpu[samples * 3 / 4],
                "wall_p50_ns": wall[samples / 2], "wall_p25_ns": wall[samples / 4], "wall_p75_ns": wall[samples * 3 / 4]]
            results.append(row)
            print(String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
            fflush(stdout)
        }
    }
}
try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
