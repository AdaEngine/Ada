/// Removes zero-thickness coincident sheets created by exact sampled contacts.
enum ScalarSurfaceTopology {
    private struct Face: Hashable {
        let a: UInt32
        let b: UInt32
        let c: UInt32

        init(_ first: UInt32, _ second: UInt32, _ third: UInt32) {
            var x = first, y = second, z = third
            if x > y { swap(&x, &y) }
            if y > z { swap(&y, &z) }
            if x > y { swap(&x, &y) }
            a = x; b = y; c = z
        }
    }

    private struct Occurrences {
        var balance = 0
        var positive = -1
        var negative = -1
    }

    static func cancelCoincidentFaces(_ indices: inout [UInt32]) throws {
        var faces: [Face: Occurrences] = [:]
        for index in stride(from: 0, to: indices.count, by: 3) {
            if index.isMultiple(of: 768) { try Task.checkCancellation() }
            let a = indices[index], b = indices[index + 1], c = indices[index + 2]
            let key = Face(a, b, c)
            let inversions = (a > b ? 1 : 0) + (a > c ? 1 : 0) + (b > c ? 1 : 0)
            var occurrence = faces[key] ?? .init()
            if inversions.isMultiple(of: 2) {
                occurrence.balance += 1
                if occurrence.positive < 0 { occurrence.positive = index }
            } else {
                occurrence.balance -= 1
                if occurrence.negative < 0 { occurrence.negative = index }
            }
            faces[key] = occurrence
        }
        let originalCount = indices.count
        var count = 0
        for index in stride(from: 0, to: originalCount, by: 3) {
            if index.isMultiple(of: 768) { try Task.checkCancellation() }
            let a = indices[index], b = indices[index + 1], c = indices[index + 2]
            guard let face = faces[Face(a, b, c)], face.balance > 0 ? face.positive == index : face.balance < 0 && face.negative == index else { continue }
            indices[count] = a; indices[count + 1] = b; indices[count + 2] = c
            count += 3
        }
        indices.removeLast(originalCount - count)
    }
}
