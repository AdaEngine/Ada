import AdaScripting
import Foundation
import Testing

@Suite("AdaScript vector math paths", .serialized)
struct AdaScriptVectorMathTests {
    @Test("3D operations and arbitrary vector dimensions retain their results", arguments: [1, 2, 3, 4, 7])
    func dimensions(_ count: Int) throws {
        let left = (1...count).map(String.init).joined(separator: ",")
        let right = (1...count).map { String($0 * 2) }.joined(separator: ",")
        let maximum = (1...count).map { String(Double($0) - 0.5) }.joined(separator: ",")
        let squared = (1...count).reduce(0) { $0 + $1 * $1 }
        let magnitude = Double(squared).squareRoot()
        let plugin = try AdaScriptPlugin(sources: [.init(path: "Dimensions.ada", source: """
        func near(actual, expected) { assert(Math.abs(actual - expected) < 0.000000001); }
        @test func vectorResults() {
            var left = [\(left)]; var right = [\(right)];
            var added = Math.addVector(left, right);
            var subtracted = Math.subtractVector(left, right);
            var scaled = Math.scaleVector(left, 2.5);
            var normalized = Math.normalize(left);
            var lerped = Math.lerpVector(left, right, 0.5);
            var clamped = Math.clampVector(left, Math.scaleVector(left, 0), [\(maximum)]);
            assert(added.count == \(count) && normalized.count == \(count));
            for (var index in 0..<\(count)) {
                var value = index + 1;
                near(added[index], value * 3);
                near(subtracted[index], -value);
                near(scaled[index], value * 2.5);
                near(normalized[index], value / \(magnitude));
                near(lerped[index], value * 1.5);
                near(clamped[index], value - 0.5);
            }
            near(Math.dot(left, right), \(squared * 2));
            near(Math.length(left), \(magnitude));
            near(Math.distance(left, right), \(magnitude));
            added[0] = 999;
            assert(left[0] == 1 && right[0] == 2);
        }
        """)], name: "VectorDimensions", includeTests: true)
        let result = try #require(plugin.runTests().first)
        #expect(result.outcome == .passed, "\(result.diagnostics)")
    }

    @Test("3D dot products preserve double accumulation and cancellation order")
    func floatingPointOrder() throws {
        let plugin = try AdaScriptPlugin(sources: [.init(path: "Accumulation.ada", source: """
        @test func accumulation() {
            assert(Math.dot([10000000000000000.0, -10000000000000000.0, 1.0], [1, 1, 1]) == 1.0);
            assert(Math.dot([1, 2, 3], [1, 2, 3]) is Float);
            assert(Math.distance([0.0, -3.0, 4.0], [0, 0, 0]) == 5.0);
        }
        """)], name: "VectorAccumulation", includeTests: true)
        let result = try #require(plugin.runTests().first)
        #expect(result.outcome == .passed, "\(result.diagnostics)")
    }

    @Test("Invalid 3D inputs retain diagnostics", arguments: [
        ["Math.addVector([1,2,3], [1,2])", "Math.addVector requires nonempty vectors of equal length"],
        ["Math.scaleVector([], 2)", "Math.scaleVector requires a nonempty vector"],
        ["Math.dot([1,2,3], [])", "Math.dot requires nonempty vectors of equal length"],
        ["Math.normalize([0,0,0])", "Math.normalize requires a nonzero vector"],
        ["Math.distance([1,2,3], [1,2])", "Math.distance requires nonempty vectors of equal length"],
        ["Math.clampVector([1,2,3], [0,4,0], [2,3,4])", "Math.clamp requires minimum <= maximum"]
    ])
    func diagnostics(_ input: [String]) throws {
        let plugin = try AdaScriptPlugin(sources: [.init(path: "Invalid.ada", source: """
        @test func invalidInput() { var result = \(input[0]); }
        """)], name: "InvalidVector", includeTests: true)
        let result = try #require(plugin.runTests().first)
        #expect(result.outcome == .failed)
        #expect(result.diagnostics.contains { $0.contains(input[1]) }, "\(result.diagnostics)")
    }
}
