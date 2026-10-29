import Foundation

/// Serializes entry into the process-wide Ada Script runtime.
enum AdaScriptRuntimeCoordinator {
    static let lock = NSRecursiveLock()
    // Bound queues of small transient values independently of the byte threshold.
    static let garbageCollectionAllocationBudget: UInt32 = 4_096
}
