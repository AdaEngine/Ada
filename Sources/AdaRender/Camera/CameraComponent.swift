//
//  Camera.swift
//  AdaEngine
//
//  Created by v.prusakov on 11/2/21.
//

import AdaAssets
import AdaECS
import AdaUtils
import Math

/// A reference to a window.
public enum WindowRef: Codable, Sendable, Hashable {
    /// The primary window.
    case primary
    /// The window id.
    case windowId(WindowID)
}

extension WindowRef {
    public func getWindowId(from primary: PrimaryWindowId) -> WindowID {
        switch self {
        case .primary:
            primary.windowId
        case let .windowId(windowID):
            windowID
        }
    }
}

public typealias WindowID = RID

/// A viewport.
public struct Viewport: Codable, Equatable, Sendable {
    /// The rectangle of the viewport.
    public var rect: Rect
    /// The depth range of the viewport.
    public var depth: ClosedRange<Float>

    public init(rect: Rect = Rect.zero, depth: ClosedRange<Float> = Float(0.0)...Float(1.0)) {
        self.rect = rect
        self.depth = depth
    }
}

/// A set of flags that determine the clear behavior of a camera.
public struct CameraClearFlags: OptionSet, Codable, Sendable {
    /// The raw value of the flags.
    public var rawValue: UInt8

    /// Initialize a new camera clear flags.
    ///
    /// - Parameter rawValue: The raw value of the flags.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// The solid flag.
    public static let solid = Self(rawValue: 1 << 0)

    /// The depth buffer flag.
    public static let depthBuffer = Self(rawValue: 1 << 1)

    /// The nothing flag.
    public static let nothing: CameraClearFlags = []
}

// TODO: We should translate mouse coordinate space to scene coordinate space
/// This component represent camera on scene. You can create more than one camera for rendering.
/// Each camera has frustum, projection data.
@Component
public struct Camera: Sendable {
    /// Render target where camera will render.
    public enum RenderTarget: Codable, Sendable {
        /// Render camera to window.
        case window(WindowRef)

        /// Render camera to texture.
        case texture(AssetHandle<RenderTexture>)
    }

    // MARK: Properties

    /// Base projection in camera
    public var projection: Projection = .orthographic(OrthographicProjection())

    /// Physical viewport (logicalViewport * scale)
    public var viewport: Viewport = Viewport()

    /// Locial viewport
    public var logicalViewport: Viewport = Viewport()

    /// Set camera is active
    public var isActive = true

    /// Fill color for unused pixel.
    public var backgroundColor: Color = .surfaceClearColor

    /// Contains information about clear flags.
    /// By default contains ``CameraClearFlags/solid`` flag which fill clear color by ``Camera/backgroundColor``.
    public var clearFlags: CameraClearFlags = .solid

    /// Render target for camera.
    /// - Note: You should check that render target will not change while rendering.
    @_spi(Internal)
    public var renderTarget: RenderTarget

    /// The computed data for the camera.
    @_spi(Internal)
    @NoExport
    public var computedData: CameraComputedData = .defaultValue

    /// The render order.
    public var renderOrder: Int = 0

    public var viewMatrix: Transform3D = .identity

    // MARK: - Init

    /// Create a new camera component with specific render target and viewport.
    public init(renderTarget: RenderTexture, viewport: Viewport? = nil) {
        self.renderTarget = .texture(AssetHandle(renderTarget))
        self.viewport = viewport ?? .init()
        self.logicalViewport = viewport ?? .init()
    }

    /// Create a new camera component. By default render target is window.
    public init() {
        self.renderTarget = .window(.primary)
    }

    /// Create a new camera component with specific window.
    ///
    /// - Parameter window: The window.
    public init(window: WindowRef) {
        self.renderTarget = .window(window)
    }
}

extension Camera {
    public func targetWindowId(from primary: PrimaryWindowId) -> WindowID? {
        switch renderTarget {
        case let .window(windowRef):
            return windowRef.getWindowId(from: primary)
        case .texture:
            return nil
        }
    }

    /// Normalized Device Coordinate to world point
    public func ndcToWorld(cameraGlobalTransform: Transform3D, ndc: Vector3) -> Vector3 {
        let matrix = cameraGlobalTransform * self.computedData.projectionMatrix.inverse
        return (matrix * Vector4(ndc, 1)).xyz
    }

    /// Return point from world to Normalized Device Coordinate.
    public func worldToNdc(cameraGlobalTransform: Transform3D, worldPosition: Vector3) -> Vector3 {
        let matrix = self.computedData.projectionMatrix * cameraGlobalTransform.inverse
        return (matrix * Vector4(worldPosition, 1)).xyz
    }

    /// Return point from viewport to 2D world.
    public func viewportToWorld2D(cameraGlobalTransform: Transform3D, viewportPosition: Vector2) -> Vector2? {
        let ndc = viewportPosition * 2 / logicalViewport.rect.size.asVector2 - Vector2.one
        let worldPlane = self.ndcToWorld(cameraGlobalTransform: cameraGlobalTransform, ndc: Vector3(ndc, 1))

        return worldPlane.xy
    }

    /// Return ray from viewport to world. More prefer for 3D space.
    public func viewportToWorld(cameraGlobalTransform: Transform3D, point: Vector2) -> Ray? {
        let ndc = point * 2 / logicalViewport.rect.size.asVector2 - Vector2.one
        let ndcToWorld = cameraGlobalTransform * self.computedData.projectionMatrix.inverse

        let worldPlaneNear = ndcToWorld * Vector4(Vector3(ndc, 0), 1)
        let worldPlaneFar = ndcToWorld * Vector4(Vector3(ndc, 1), 1)

        guard
            !worldPlaneNear.isNaN,
            !worldPlaneFar.isNaN,
            worldPlaneNear.w != 0,
            worldPlaneFar.w != 0
        else {
            return nil
        }

        let nearPoint = worldPlaneNear.xyz / worldPlaneNear.w
        let farPoint = worldPlaneFar.xyz / worldPlaneFar.w
        let direction = farPoint - nearPoint

        guard !direction.isNaN, direction != .zero else {
            return nil
        }

        return Ray(
            origin: nearPoint,
            direction: direction.normalized
        )
    }

    /// Return point from world to viewport.
    public func worldToViewport(cameraGlobalTransform: Transform3D, worldPosition: Vector3) -> Vector2? {
        let size = logicalViewport.rect.size.asVector2
        let ndcSpace = self.worldToNdc(cameraGlobalTransform: cameraGlobalTransform, worldPosition: worldPosition)

        if ndcSpace.z < 0 || ndcSpace.z > 1.0 {
            return nil
        }

        return ndcSpace.xy + Vector2.one / 2.0 * size
    }
}

extension Camera {
    /// A component that contains the computed data for the camera.
    public struct CameraComputedData: DefaultValue, Sendable {
        /// The default value.
        public static let defaultValue: Camera.CameraComputedData = .init()

        /// The projection matrix.
        public var projectionMatrix: Transform3D = .identity
        /// The view matrix.
        public var viewMatrix: Transform3D = .identity
        /// The frustum.
        public var frustum: Frustum = .defaultValue
        /// The target scale factor.
        public var targetScaleFactor: Float = 1
    }
}

/// A component that contains the global view uniform.
@Component
public struct GlobalViewUniform {
    /// The projection matrix.
    public internal(set) var projectionMatrix: Transform3D
    /// The view projection matrix.
    public internal(set) var viewProjectionMatrix: Transform3D
    /// The view matrix.
    public internal(set) var viewMatrix: Transform3D

    /// Initialize a new global view uniform.
    ///
    /// - Parameter projectionMatrix: The projection matrix.
    /// - Parameter viewProjectionMatrix: The view projection matrix.
    /// - Parameter viewMatrix: The view matrix.
    public init(
        projectionMatrix: Transform3D = .identity,
        viewProjectionMatrix: Transform3D = .identity,
        viewMatrix: Transform3D = .identity
    ) {
        self.projectionMatrix = projectionMatrix
        self.viewProjectionMatrix = viewProjectionMatrix
        self.viewMatrix = viewMatrix
    }
}
