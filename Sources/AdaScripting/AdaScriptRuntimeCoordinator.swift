import Foundation

/// Serializes entry into the process-wide Ada Script runtime.
enum AdaScriptRuntimeCoordinator {
    static let lock = NSRecursiveLock()
}
