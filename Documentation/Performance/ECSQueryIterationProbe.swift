import AdaECS
import Darwin
import Dispatch
import Foundation

@Component
struct ProbePosition { var x: Int; var y: Int }
@Component
struct ProbeVelocity { var x: Int; var y: Int }
@Component
struct ProbeTagA {}
@Component
struct ProbeTagB {}

func cpuNanoseconds() -> UInt64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return UInt64(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000_000_000
        + UInt64(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) * 1_000
}

@inline(never)
func read(_ query: Query<ProbePosition, ProbeVelocity>) -> Int {
    var checksum = 0
    query.forEach { position, velocity in checksum &+= position.x &+ velocity.x }
    return checksum
}

@inline(never)
func write(_ query: Query<Ref<ProbePosition>, ProbeVelocity>) -> Int {
    var checksum = 0
    query.forEach { position, velocity in
        position.wrappedValue.y &+= velocity.y
        checksum &+= position.wrappedValue.x &+ velocity.x
    }
    return checksum
}

@inline(never)
func filtered(_ query: FilterQuery<ProbePosition, ProbeVelocity, With<ProbeTagA>>) -> Int {
    var checksum = 0
    query.forEach { position, velocity in checksum &+= position.x &+ velocity.x }
    return checksum
}

@inline(never)
func changed(_ query: FilterQuery<ProbePosition, ProbeVelocity, Changed<ProbePosition>>) -> Int {
    var checksum = 0
    query.forEach { position, velocity in checksum &+= position.x &+ velocity.x }
    return checksum
}

@inline(never)
func withEntity(_ query: Query<Entity, ProbePosition, ProbeVelocity>) -> Int {
    var checksum = 0
    query.forEach { entity, position, velocity in
        precondition(entity.id >= 0)
        checksum &+= position.x &+ velocity.x
    }
    return checksum
}

@inline(never)
func optional(_ query: Query<ProbePosition, ProbeVelocity?>) -> Int {
    var checksum = 0
    query.forEach { position, velocity in checksum &+= position.x &+ (velocity?.x ?? 0) }
    return checksum
}

let counts = [4_000, 16_000, 64_000]
let iterations = 8
let samples = 30
var results: [[String: Any]] = []
for count in counts {
    let world = World()
    var entities: [Entity] = []
    for index in 0..<count {
        entities.append(world.spawn {
            ProbePosition(x: index, y: 0)
            ProbeVelocity(x: 1, y: 1)
            if index % 4 == 1 || index % 4 == 3 { ProbeTagA() }
            if index % 4 == 2 || index % 4 == 3 { ProbeTagB() }
        })
    }
    world.clearTrackers()
    for index in stride(from: 0, to: count, by: 2) {
        world.insert(ProbePosition(x: index, y: 0), for: entities[index].id)
    }
    let readQuery = Query<ProbePosition, ProbeVelocity>(from: world)
    let writeQuery = Query<Ref<ProbePosition>, ProbeVelocity>(from: world)
    let filteredQuery = FilterQuery<ProbePosition, ProbeVelocity, With<ProbeTagA>>(from: world)
    let changedQuery = FilterQuery<ProbePosition, ProbeVelocity, Changed<ProbePosition>>(from: world)
    let entityQuery = Query<Entity, ProbePosition, ProbeVelocity>(from: world)
    let optionalQuery = Query<ProbePosition, ProbeVelocity?>(from: world)
    let allExpected = count * (count + 1) / 2
    let oddExpected = count / 2 * (count / 2 + 1)
    let evenExpected = count / 2 * (count / 2)
    let scenarios: [(String, Int, () -> Int)] = [
        ("Read", allExpected, { read(readQuery) }),
        ("With", oddExpected, { filtered(filteredQuery) }),
        ("Changed", evenExpected, { changed(changedQuery) }),
        ("Entity", allExpected, { withEntity(entityQuery) }),
        ("Optional", allExpected, { optional(optionalQuery) }),
        // Writes come last, so they do not change the row-filter fixture.
        ("Write", allExpected, { write(writeQuery) })
    ]
    for (name, expected, operation) in scenarios {
        var wall: [UInt64] = []
        var cpu: [UInt64] = []
        for sample in -3..<samples {
            var checksum = 0
            let cpuStart = cpuNanoseconds()
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations { checksum &+= operation() }
            let end = DispatchTime.now().uptimeNanoseconds
            let cpuEnd = cpuNanoseconds()
            precondition(checksum == expected * iterations)
            if sample >= 0 {
                wall.append(end - start)
                cpu.append(cpuEnd - cpuStart)
            }
        }
        wall.sort()
        cpu.sort()
        let row: [String: Any] = ["scenario": name, "entities": count, "iterations": iterations,
            "samples": samples, "wall_p50_ns": wall[samples / 2], "cpu_p50_ns": cpu[samples / 2],
            "wall_p25_ns": wall[samples / 4], "wall_p75_ns": wall[samples * 3 / 4]]
        results.append(row)
        print(String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
        fflush(stdout)
    }
    // Check the mutation itself outside measurement, not only the checksum.
    let expectedY = (samples + 3) * iterations
    for entity in entities { precondition(world.get(ProbePosition.self, from: entity.id)?.y == expectedY) }
    world.clear()
}
let output = CommandLine.arguments[1]
try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
