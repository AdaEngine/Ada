import AdaECS
import AdaUtils
import Foundation

/// Opt-in pointer capture for an interactive game world. Capture requires a real,
/// focused native window and is released on world teardown or focus loss.
@Component
public struct MouseCaptureComponent: Codable, Sendable {
    public var isRequested: Bool
    public internal(set) var isCaptured: Bool = false

    public init(isRequested: Bool = false) { self.isRequested = isRequested }

    private enum CodingKeys: CodingKey { case isRequested }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isRequested = try values.decodeIfPresent(Bool.self, forKey: .isRequested) ?? false
    }
}

/// Dependency-inversion boundary: AdaInput never imports a UI/platform module.
/// Each Input owns a distinct lease so one game cannot release another's cursor.
@MainActor
public protocol InputPointerDriver: AnyObject, Sendable {
    func requestMouseMode(_ mode: Input.MouseMode, owner: UUID, window: RID?)
    func releaseMouseMode(owner: UUID)
    func mouseMode(owner: UUID) -> Input.MouseMode
}

@PlainSystem
public struct MouseCaptureSystem {
    @Query<Ref<MouseCaptureComponent>> private var captures
    @ResMut<Input> private var input
    @Local private var wasRequested = false

    public init(world _: World) {}

    @MainActor
    public func update(context _: UpdateContext) {
        var requested = false
        captures.forEach { requested = requested || $0.isRequested }
        if requested != wasRequested {
            input.setMouseMode(requested ? .captured : .visible)
            wasRequested = requested
        }
        let captured = input.getMouseMode() == .captured
        captures.forEach { $0.isCaptured = $0.isRequested && captured }
    }
}
