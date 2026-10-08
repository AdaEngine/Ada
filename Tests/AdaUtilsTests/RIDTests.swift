import AdaUtils
import Testing

@Suite("RID uniqueness")
struct RIDTests {
    @Test("Consecutive resource and input identifiers never share a clock tick")
    func consecutiveIDs() {
        let values = (0..<10_000).map { _ in RID().id }
        #expect(Set(values).count == values.count)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test("Concurrent producers do not reuse identifiers")
    func concurrentIDs() async {
        let values = await withTaskGroup(of: [Int].self) { group in
            for _ in 0..<8 {
                group.addTask { (0..<1_000).map { _ in RID().id } }
            }
            var result: [Int] = []
            for await batch in group { result.append(contentsOf: batch) }
            return result
        }
        #expect(Set(values).count == 8_000)
    }
}
