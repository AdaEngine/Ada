import AdaRender
import AdaUtils

/// Persistent camera settings for a scene file. Runtime render targets, matrices
/// and computed viewport data are rebuilt by the renderer after scene loading.
public struct SceneCameraSettings: Codable, Sendable {
    public let projection: Projection
    public let isActive: Bool
    public let renderOrder: Int
    public let backgroundColor: Color
    public let clearFlags: CameraClearFlags
    public init(camera: Camera) {
        projection = camera.projection
        isActive = camera.isActive
        renderOrder = camera.renderOrder
        backgroundColor = camera.backgroundColor
        clearFlags = camera.clearFlags
    }
    public func makeCamera() -> Camera {
        var camera = Camera()
        camera.projection = projection
        camera.isActive = isActive
        camera.renderOrder = renderOrder
        camera.backgroundColor = backgroundColor
        camera.clearFlags = clearFlags
        return camera
    }
}
