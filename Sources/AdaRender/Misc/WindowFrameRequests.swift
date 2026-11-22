import AdaECS
import AdaUtils

/// A UI window camera whose unchanged contents do not need another drawable.
/// Other active window cameras targeting the same surface keep it continuous.
@Component
public struct WindowRenderOnDemand: Sendable {
    public init() {}
}

/// Presentation requests produced by the UI runtime each frame.
/// Geometry rebuilds and presentation of an updated retained texture are independent.
public struct WindowFrameRequests: Resource {
    package var requestedWindowIDs: Set<WindowID> = []
    private var onDemandWindowIDs: Set<WindowID> = []
    private var continuousWindowIDs: Set<WindowID> = []

    public init() {}

    package mutating func beginFrame() {
        requestedWindowIDs.removeAll(keepingCapacity: true)
        clearCameraModes()
    }

    mutating func clearCameraModes() {
        onDemandWindowIDs.removeAll(keepingCapacity: true)
        continuousWindowIDs.removeAll(keepingCapacity: true)
    }

    package mutating func include(_ window: WindowRef, primary: WindowID?, onDemand: Bool) {
        let id: WindowID
        switch window {
        case .primary:
            guard let primary else {
                return
            }
            id = primary
        case .windowId(let windowID): id = windowID
        }
        if onDemand { onDemandWindowIDs.insert(id) } else { continuousWindowIDs.insert(id) }
    }

    package func shouldRender(_ id: WindowID) -> Bool {
        !onDemandWindowIDs.contains(id) || continuousWindowIDs.contains(id) || requestedWindowIDs.contains(id)
    }

    // Preserve ordinary display pacing when no on-demand cameras participate.
    var hasOnDemandWindows: Bool { !onDemandWindowIDs.isEmpty }

    package var expectsPresentation: Bool {
        onDemandWindowIDs.isEmpty || !continuousWindowIDs.isEmpty || !requestedWindowIDs.isEmpty
    }
}

/// Keeps on-demand updates alive when resizing or surface recovery temporarily
/// prevents acquisition. Owned by the render world's surface system.
package struct PendingWindowFrameRequests {
    private var windowIDs: Set<WindowID> = []

    var isEmpty: Bool { windowIDs.isEmpty }

    package mutating func include(_ requests: WindowFrameRequests?) {
        if let requests { windowIDs.formUnion(requests.requestedWindowIDs) }
    }

    package mutating func retainWindows(_ windows: some Sequence<WindowID>) {
        windowIDs.formIntersection(windows)
    }

    package mutating func shouldAcquireDrawable(for id: WindowID, requests: WindowFrameRequests?) -> Bool {
        if requests?.shouldRender(id) != false { windowIDs.insert(id) }
        return windowIDs.contains(id)
    }

    package mutating func didAcquireDrawable(for id: WindowID) {
        windowIDs.remove(id)
    }
}
