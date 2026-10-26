import AdaInput
import Gravity
import Math

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
    /// Pointer coordinates in the active window; zero after this callback's lease expires.
    var mouseX: Double { Double(snapshot?.getMousePosition().x ?? 0) }
    var mouseY: Double { Double(snapshot?.getMousePosition().y ?? 0) }
    var mouseDeltaX: Double { Double(snapshot?.getMouseDelta().x ?? 0) }
    var mouseDeltaY: Double { Double(snapshot?.getMouseDelta().y ?? 0) }

    @GSExportableIgnore
    func invalidate() { snapshot = nil }
}
