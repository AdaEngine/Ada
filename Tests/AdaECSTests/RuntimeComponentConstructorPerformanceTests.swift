import AdaECS
import Foundation
import Math
import Testing

@Suite("Runtime component constructor performance")
struct RuntimeComponentConstructorPerformanceTests {
    @Test("Generated constructor avoids reflection lookup overhead")
    func generatedConstructorProbe() throws {
        guard ProcessInfo.processInfo.environment["ADAENGINE_RUN_PERF_PROBES"] == "1" else {
            return
        }

        let iterations = 100_000
        let arguments: [ReflectedFieldValue?] = [
            .array([.double(4), .double(5), .double(6)]),
            .int(7),
        ]
        let descriptor = RuntimeConstructorBenchmarkProbe.runtimeComponentConstructor
        let reflectedFields = RuntimeConstructorBenchmarkProbe.componentDescriptor.fields
        var generatedChecksum = 0
        let generatedDuration = ContinuousClock().measure {
            for _ in 0..<iterations {
                let component = try? descriptor.apply(
                    to: RuntimeConstructorBenchmarkProbe(),
                    arguments: arguments
                )
                generatedChecksum += (component as? RuntimeConstructorBenchmarkProbe)?.count ?? 0
            }
        }

        var reflectedChecksum = 0
        let reflectedDuration = ContinuousClock().measure {
            for _ in 0..<iterations {
                let fields = Dictionary(uniqueKeysWithValues: reflectedFields.map { ($0.key, $0) })
                var component: any Component = RuntimeConstructorBenchmarkProbe()
                for (name, value) in zip(["position", "count"], arguments) {
                    guard let value, let updated = fields[name]?.write(component, value) else {
                        continue
                    }
                    component = updated
                }
                reflectedChecksum += (component as? RuntimeConstructorBenchmarkProbe)?.count ?? 0
            }
        }

        #expect(generatedChecksum == reflectedChecksum)
        print(
            "Runtime constructor probe: generated=\(generatedDuration), "
                + "reflection=\(reflectedDuration), iterations=\(iterations)"
        )
    }
}

@Component
private struct RuntimeConstructorBenchmarkProbe {
    var position: Vector3 = .zero
    var count: Int = 0
}
