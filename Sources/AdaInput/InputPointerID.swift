import AdaUtils

/// Stable pointer identity, scoped to a window. Mouse buttons share one hover pointer.
public enum InputPointerID: Hashable, Sendable {
    case mouse(window: RID)
    case touch(window: RID, contact: RID)

    public var windowID: RID {
        switch self {
        case let .mouse(window), let .touch(window, _): window
        }
    }
}
