import AdaInput
import Gravity

/// A callback-scoped input snapshot. Access and invalidation are serialized by AdaScriptRuntimeCoordinator.
@GSExportable("AdaInputActions")
final class AdaScriptInputBridge: @unchecked Sendable, AdaScriptNonSendableBridge {
    private var snapshot: Input?

    @GSExportableIgnore
    static func make(_ input: Input?) -> AdaScriptInputBridge {
        AdaScriptInputBridge(input)
    }

    private init(_ input: Input?) { snapshot = input }

    func available() -> Bool { snapshot != nil }

    func isActionPressed(_ name: String) -> Bool { snapshot?.isActionPressed(name) ?? false }
    func isActionJustPressed(_ name: String) -> Bool { snapshot?.isActionJustPressed(name) ?? false }
    func isActionJustReleased(_ name: String) -> Bool { snapshot?.isActionJustReleased(name) ?? false }
    func getActionStrength(_ name: String) -> Double { Double(snapshot?.getActionStrength(name) ?? 0) }

    @GSExportableIgnore
    func invalidate() { snapshot = nil }
}
