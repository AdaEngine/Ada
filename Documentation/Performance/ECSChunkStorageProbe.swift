@testable import AdaECS
import AdaUtils
import Darwin
import Dispatch
import Foundation

@Component
struct ProbePosition { var x: Float; var y: Float }
@Component
struct ProbeVelocity { var x: Float; var y: Float }

func cpuNanoseconds() -> UInt64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return UInt64(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000_000_000
        + UInt64(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) * 1_000
}

let counts = [1_000, 4_000, 16_000, 64_000]
let samples = 30
var results: [[String: Any]] = []
for components in [false, true] {
    for count in counts {
        var wall: [UInt64] = []
        var cpu: [UInt64] = []
        var columnBytes = 0
        for sample in -3..<samples {
            let world = World()
            let cpuStart = cpuNanoseconds()
            let start = DispatchTime.now().uptimeNanoseconds
            for index in 0..<count {
                if components {
                    world.spawn {
                        ProbePosition(x: Float(index), y: Float(index))
                        ProbeVelocity(x: 1, y: -1)
                    }
                } else {
                    world.spawn()
                }
            }
            let end = DispatchTime.now().uptimeNanoseconds
            let cpuEnd = cpuNanoseconds()
            precondition(world.getEntities().count == count)
            if sample >= 0 {
                wall.append(end - start)
                cpu.append(cpuEnd - cpuStart)
            }
            if sample == 0 {
                for archetype in world.archetypes.archetypes {
                    for chunk in archetype.chunks.chunks {
                        for column in chunk.componentsData {
                            for blob in [column.data, column.addedTicks, column.changeTicks] {
                                columnBytes += unsafe blob.buffer.pointer.count + blob.buffer.initialized.count
                            }
                        }
                    }
                }
            }
            world.clear()
        }
        wall.sort(); cpu.sort()
        let row: [String: Any] = ["scenario": components ? "SpawnComponents" : "SpawnEmpty", "entities": count,
            "samples": samples, "wall_p50_ns": wall[samples / 2], "cpu_p50_ns": cpu[samples / 2],
            "wall_p25_ns": wall[samples / 4], "wall_p75_ns": wall[samples * 3 / 4], "column_bytes": columnBytes]
        results.append(row)
        let bytes = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        print(String(decoding: bytes, as: UTF8.self))
        fflush(stdout)
    }
}
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/adaecs-storage-20261009/evidence/probe.json"
try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: output))
