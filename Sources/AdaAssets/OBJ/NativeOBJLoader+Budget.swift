import Foundation

/// Conservative request-local accounting before OBJ token arrays or mesh expansion.
struct OBJImportBudget {
    private var remaining: Int?

    init(data: Data) throws {
        guard let limits = ModelImportContext.limits else {
            remaining = nil
            return
        }
        guard limits.maximumEncodedBytes > 0, limits.maximumDecodedBytes > 0 else { throw ModelImportLimitError.invalidLimits }
        guard data.count <= limits.maximumEncodedBytes else { throw ModelImportLimitError.encodedBudgetExceeded }
        remaining = limits.maximumDecodedBytes
        try charge(1, stride: 256)
        // UTF-8 storage and temporary name/number conversions remain bounded too.
        try charge(data.count, stride: 4)
        var lines = 1
        var visits = 0
        for byte in data {
            if byte == 10 { lines += 1 }
            visits += 1
            if visits.isMultiple(of: 65_536) { try Task.checkCancellation() }
        }
        try charge(lines, stride: 64)
    }

    var maximumFields: Int { remaining.map { $0 / 512 } ?? Int.max - 1 }

    mutating func fields(_ count: Int, line: Int) throws {
        try charge(count, stride: 512)
        if remaining != nil, line.isMultiple(of: 256) { try Task.checkCancellation() }
    }

    private mutating func charge(_ count: Int, stride: Int) throws {
        guard let available = remaining else {
            return
        }
        guard count >= 0, count <= available / stride else { throw ModelImportLimitError.decodedBudgetExceeded }
        remaining = available - count * stride
    }
}
