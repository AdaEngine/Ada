import AdaUtils
import Math

/// A magnification input event available to systems through `Input.getInputEvents()`.
/// Scale is relative to gesture start (1 is unchanged). Position uses window coordinates.
public struct PinchEvent: InputEvent {
    public enum Phase: String, Hashable, Sendable {
        case began
        case changed
        case ended
        case cancelled
    }

    public let id = RID()
    public let window: RID
    public let time: TimeInterval
    public let location: Point
    public let scale: Float
    public let phase: Phase

    public init(window: RID, location: Point, scale: Float, phase: Phase, time: TimeInterval) {
        self.window = window
        self.location = location
        self.scale = scale
        self.phase = phase
        self.time = time
    }
}
