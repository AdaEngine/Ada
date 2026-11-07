import Foundation

/// Shared only by value readers within one synchronous decode; no reference escapes the call.
final class VOXDecodeBudget {
    private var remaining: Int

    private init(remaining: Int) { self.remaining = remaining }

    static func make(rootBytes: Int, limits: ModelImportLimits?) throws -> VOXDecodeBudget? {
        guard let limits else {
            return nil
        }
        guard limits.maximumEncodedBytes > 0, limits.maximumDecodedBytes > 0 else { throw ModelImportLimitError.invalidLimits }
        guard rootBytes <= limits.maximumEncodedBytes else { throw ModelImportLimitError.encodedBudgetExceeded }
        guard limits.maximumDecodedBytes >= 4_096, rootBytes <= (limits.maximumDecodedBytes - 4_096) / 16 else {
            throw ModelImportLimitError.decodedBudgetExceeded
        }
        return .init(remaining: limits.maximumDecodedBytes - 4_096 - rootBytes * 16)
    }

    func records<T>(_ type: T.Type, count: Int) throws {
        try charge(count, stride: max(1, MemoryLayout<T>.stride))
    }

    func charge(_ count: Int, stride: Int) throws {
        guard count >= 0, count <= remaining / stride else { throw ModelImportLimitError.decodedBudgetExceeded }
        remaining -= count * stride
    }
}
