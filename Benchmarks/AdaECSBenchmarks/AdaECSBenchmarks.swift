import AdaECS
import Benchmark
import Foundation

// MARK: - Components

@Component
private struct Position {
    var x: Float
    var y: Float
}

@Component
private struct Velocity {
    var x: Float
    var y: Float
}

@Component
private struct CompA {
    var value: Float
}

@Component
private struct CompB {
    var value: Float
}

@Component
private struct CompC {
    var value: Float
}

@Component
private struct FragData {
    var value: Float
}

@Component
private struct Matrix4x4 {
    var m00: Float, m01: Float, m02: Float, m03: Float
    var m10: Float, m11: Float, m12: Float, m13: Float
    var m20: Float, m21: Float, m22: Float, m23: Float
    var m30: Float, m31: Float, m32: Float, m33: Float
}

extension Matrix4x4 {
    /// Rotate the first two columns of every row; values stay bounded across samples.
    mutating func rotate() {
        let cosine: Float = 0.9998000
        let sine: Float = 0.019998667
        let x0 = m00 * cosine - m01 * sine
        m01 = m00 * sine + m01 * cosine
        m00 = x0
        let x1 = m10 * cosine - m11 * sine
        m11 = m10 * sine + m11 * cosine
        m10 = x1
        let x2 = m20 * cosine - m21 * sine
        m21 = m20 * sine + m21 * cosine
        m20 = x2
        let x3 = m30 * cosine - m31 * sine
        m31 = m30 * sine + m31 * cosine
        m30 = x3
    }
}

@Component
private struct CoWData {
    var values: [Int]
    var label: String
}

// MARK: - Constants

private enum BenchConstants {
    static let smoke = ProcessInfo.processInfo.environment["ADAENGINE_BENCHMARK_SMOKE"] == "1"
    static let spawnEntities = smoke ? 1_000 : 100_000
    static let simpleIterEntities = smoke ? 1_000 : 100_000
    static let fragmentedEntitiesPerType = smoke ? 334 : 33_334
    static let heavyComputeEntities = smoke ? 100 : 1_000
    static let heavyComputeIterations = 100
    static let addRemoveEntities = smoke ? 1_000 : 100_000
}

// MARK: - Setup Helpers

private func makeSimpleIterWorld(entityCount: Int) -> (World, Query<Ref<Position>, Velocity>) {
    let world = World()
    for i in 0..<entityCount {
        world.spawn {
            Position(x: Float(i), y: Float(i))
            Velocity(x: 1, y: -1)
        }
    }

    let query = Query<Ref<Position>, Velocity>()
    query.update(from: world)

    precondition(query.count == entityCount, "Benchmark query must visit every fixture entity")
    return (world, query)
}

private func makeFragmentedIterWorld(entitiesPerType: Int) -> (World, Query<Ref<FragData>>) {
    let world = World()

    for i in 0..<entitiesPerType {
        world.spawn {
            CompA(value: Float(i))
            FragData(value: Float(i))
        }
    }
    for i in 0..<entitiesPerType {
        world.spawn {
            CompB(value: Float(i))
            FragData(value: Float(i))
        }
    }
    for i in 0..<entitiesPerType {
        world.spawn {
            CompC(value: Float(i))
            FragData(value: Float(i))
        }
    }

    let query = Query<Ref<FragData>>()
    query.update(from: world)

    precondition(query.count == entitiesPerType * 3, "Fragmented query must visit all three archetypes")
    return (world, query)
}

private func makeHeavyComputeWorld(entityCount: Int) -> (World, Query<Ref<Matrix4x4>>) {
    let world = World()
    for _ in 0..<entityCount {
        world.spawn {
            Matrix4x4(
                m00: 1, m01: 0, m02: 0, m03: 0,
                m10: 0, m11: 1, m12: 0, m13: 0,
                m20: 0, m21: 0, m22: 1, m23: 0,
                m30: 0, m31: 0, m32: 0, m33: 1
            )
        }
    }

    let query = Query<Ref<Matrix4x4>>()
    query.update(from: world)

    precondition(query.count == entityCount, "Heavy-compute query must visit every fixture entity")
    return (world, query)
}

private func makeAddRemoveWorld(entityCount: Int) -> (World, [Entity.ID]) {
    let world = World()
    var ids: [Entity.ID] = []
    ids.reserveCapacity(entityCount)

    for i in 0..<entityCount {
        let entity = world.spawn {
            Position(x: Float(i), y: Float(i))
        }
        ids.append(entity.id)
    }

    return (world, ids)
}

// MARK: - Benchmarks

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .cpuTotal, .mallocCountTotal, .retainCount, .releaseCount],
        warmupIterations: 1,
        scalingFactor: .one,
        maxDuration: BenchConstants.smoke ? .milliseconds(100) : .seconds(2),
        maxIterations: BenchConstants.smoke ? 3 : 100
    )

    Benchmark("AdaECS.Spawn") { benchmark in
        let world = World()
        benchmark.startMeasurement()
        for _ in 0..<BenchConstants.spawnEntities {
            world.spawn()
        }
        benchmark.stopMeasurement()
        blackHole(world)
        if BenchConstants.smoke {
            precondition(world.getEntities().count == BenchConstants.spawnEntities)
        }
        world.clear()
    }

    Benchmark(
        "AdaECS.SimpleIter",
        closure: { benchmark, state in
            let (world, query) = state
            for _ in benchmark.scaledIterations {
                query.forEach { position, velocity in
                    position.x += velocity.x
                    position.y += velocity.y
                }
            }
            benchmark.stopMeasurement()
            blackHole(world)
            if BenchConstants.smoke {
                precondition((query.first?.0.x ?? 0) > 0)
            }
        },
        setup: {
            makeSimpleIterWorld(entityCount: BenchConstants.simpleIterEntities)
        }
    )

    Benchmark(
        "AdaECS.FragmentedIter",
        closure: { benchmark, state in
            let (world, query) = state
            for _ in benchmark.scaledIterations {
                for data in query {
                    data.value += 1.0
                }
            }
            benchmark.stopMeasurement()
            blackHole(world)
            if BenchConstants.smoke {
                precondition((query.first?.value ?? 0) > 0)
            }
        },
        setup: {
            makeFragmentedIterWorld(entitiesPerType: BenchConstants.fragmentedEntitiesPerType)
        }
    )

    Benchmark(
        "AdaECS.HeavyCompute",
        closure: { benchmark, state in
            let (world, query) = state
            for _ in benchmark.scaledIterations {
                for transform in query {
                    var matrix = transform.wrappedValue
                    for _ in 0..<BenchConstants.heavyComputeIterations {
                        matrix.rotate()
                    }
                    transform.wrappedValue = matrix
                }
            }
            benchmark.stopMeasurement()
            blackHole(world)
            if BenchConstants.smoke {
                precondition(query.first?.m00.isFinite == true)
                precondition(query.first?.m00 != 1)
            }
        },
        setup: {
            makeHeavyComputeWorld(entityCount: BenchConstants.heavyComputeEntities)
        }
    )

    Benchmark(
        "AdaECS.AddRemove",
        closure: { benchmark, state in
            let (world, ids) = state
            for _ in benchmark.scaledIterations {
                for id in ids {
                    world.insert(Velocity(x: 1, y: -1), for: id)
                }
                for id in ids {
                    world.remove(Velocity.self, from: id)
                }
            }
            benchmark.stopMeasurement()
            blackHole(world)
            if BenchConstants.smoke {
                precondition(ids.allSatisfy { !world.has(Velocity.self, in: $0) })
                precondition(Query<Position>(from: world).count == ids.count)
            }
        },
        setup: {
            makeAddRemoveWorld(entityCount: BenchConstants.addRemoveEntities)
        }
    )

    Benchmark(
        "AdaECS.InsertCoW",
        closure: { benchmark, state in
            let (world, ids) = state
            benchmark.startMeasurement()
            for (index, id) in ids.enumerated() {
                let component = CoWData(values: Array(repeating: index, count: 32), label: String(repeating: "ownership-", count: 4))
                world.insert(consume component, for: id)
            }
            benchmark.stopMeasurement()
            blackHole(world)
            if BenchConstants.smoke, let first = ids.first {
                precondition(world.get(CoWData.self, from: first)?.values == Array(repeating: 0, count: 32))
            }
            // Restore the fixture outside measurement; do not overwrite live component storage.
            for id in ids {
                world.remove(CoWData.self, from: id)
            }
        },
        setup: {
            makeAddRemoveWorld(entityCount: BenchConstants.addRemoveEntities)
        }
    )
}
