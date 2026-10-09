import AdaECS
import AdaUtils
import Darwin
import Dispatch
import Foundation

@Component
struct SpawnPosition { var x: Int; var y: Int }
@Component
struct SpawnVelocity: DefaultValue {
    var x: Int
    var y: Int
    static var defaultValue: Self { Self(x: 1, y: -1) }
}
@Component
struct SpawnParent { var value: Int }
@Component(required: [SpawnVelocity.self])
struct SpawnStaticParent { var value: Int }

let health = RuntimeComponentDescriptor(stableID: "probe.spawn.health", name: "Health", fieldNames: ["value"], defaultValues: [.int(3)])
let score = RuntimeComponentDescriptor(stableID: "probe.spawn.score", name: "Score", fieldNames: ["value"], defaultValues: [.int(7)])

func cpuNanoseconds() -> UInt64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return UInt64(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000_000_000
        + UInt64(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) * 1_000
}

enum Scenario: String, CaseIterable {
    case native, registeredRequirement, staticRequirement, runtime

    func configure(_ world: World) {
        if self == .registeredRequirement {
            world.registerRequiredComponent(SpawnVelocity.self, for: SpawnParent.self) { SpawnVelocity(x: 1, y: -1) }
        }
        if self == .runtime {
            world.registerRuntimeComponent(health)
            world.registerRuntimeComponent(score)
        }
    }

    @inline(never)
    func spawn(in world: World, index: Int) -> Entity {
        switch self {
        case .native:
            world.spawn { SpawnPosition(x: index, y: index); SpawnVelocity(x: 1, y: -1) }
        case .registeredRequirement:
            world.spawn { SpawnParent(value: index) }
        case .staticRequirement:
            world.spawn { SpawnStaticParent(value: index) }
        case .runtime:
            world.spawn { health.makeDefault(); score.makeDefault() }
        }
    }

    func verify(_ world: World, count: Int) {
        precondition(world.getEntities().count == count)
        var checksum = 0
        switch self {
        case .native:
            Query<SpawnPosition, SpawnVelocity>(from: world).forEach { position, velocity in
                precondition(velocity.x == 1 && velocity.y == -1)
                checksum += position.x
            }
        case .registeredRequirement:
            Query<SpawnParent, SpawnVelocity>(from: world).forEach { parent, velocity in
                precondition(velocity.x == 1 && velocity.y == -1)
                checksum += parent.value
            }
        case .staticRequirement:
            Query<SpawnStaticParent, SpawnVelocity>(from: world).forEach { parent, velocity in
                precondition(velocity.x == 1 && velocity.y == -1)
                checksum += parent.value
            }
        case .runtime:
            for entity in world.getEntities() {
                precondition(world.getRuntimeComponent(health.componentID, from: entity.id)?.values == [.int(3)])
                precondition(world.getRuntimeComponent(score.componentID, from: entity.id)?.values == [.int(7)])
            }
            return
        }
        precondition(checksum == count * (count - 1) / 2)
    }
}

let samples = 30
var results: [[String: Any]] = []
for count in [4_000, 16_000, 64_000] {
    for scenario in Scenario.allCases {
        for warm in [false, true] {
            var wall: [UInt64] = []
            var cpu: [UInt64] = []
            for sample in -3..<samples {
                let world = World()
                scenario.configure(world)
                if warm {
                    let first = scenario.spawn(in: world, index: -1)
                    world.removeEntity(first)
                }
                let cpuStart = cpuNanoseconds()
                let start = DispatchTime.now().uptimeNanoseconds
                for index in 0..<count { _ = scenario.spawn(in: world, index: index) }
                let end = DispatchTime.now().uptimeNanoseconds
                let cpuEnd = cpuNanoseconds()
                scenario.verify(world, count: count)
                if sample >= 0 {
                    wall.append(end - start)
                    cpu.append(cpuEnd - cpuStart)
                }
                world.clear()
            }
            wall.sort()
            cpu.sort()
            let row: [String: Any] = ["scenario": scenario.rawValue, "start": warm ? "warm" : "cold",
                "entities": count, "samples": samples, "cpu_p50_ns": cpu[samples / 2],
                "cpu_p25_ns": cpu[samples / 4], "cpu_p75_ns": cpu[samples * 3 / 4],
                "wall_p50_ns": wall[samples / 2], "wall_p25_ns": wall[samples / 4], "wall_p75_ns": wall[samples * 3 / 4]]
            results.append(row)
            print(String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
            fflush(stdout)
        }
    }
}
try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
