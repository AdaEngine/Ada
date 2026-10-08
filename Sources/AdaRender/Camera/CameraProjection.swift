//
//  CameraProjection.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 20.12.2025.
//

import AdaUtils
import Math

/// View projection for camera.
public enum Projection: Sendable, Codable {
    /// Orthographic projection commonly used for 2D space.
    case orthographic(OrthographicProjection)

    /// Perspective projection used for 3D space.
    case perspective(PerspectiveProjection)
    case custom(CameraProjection)

    @inlinable
    public var cameraProjection: CameraProjection {
        switch self {
        case let .orthographic(orthographicProjection):
            return orthographicProjection
        case let .perspective(perspectiveProjection):
            return perspectiveProjection
        case let .custom(cameraProjection):
            return cameraProjection
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    enum ProjectionType: String, Codable {
        case orthographic
        case perspective
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ProjectionType.self, forKey: .type)

        switch type {
        case .orthographic:
            let projection = try container.decode(OrthographicProjection.self, forKey: .value)
            self = .orthographic(projection)
        case .perspective:
            let projection = try container.decode(PerspectiveProjection.self, forKey: .value)
            self = .perspective(projection)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .orthographic(projection):
            try container.encode(ProjectionType.orthographic, forKey: .type)
            try container.encode(projection, forKey: .value)
        case let .perspective(projection):
            try container.encode(ProjectionType.perspective, forKey: .type)
            try container.encode(projection, forKey: .value)
        case .custom:
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Custom projection cannot be encoded"
                )
            )
        }
    }
}

extension Projection: CameraProjection {
    @inlinable
    public var near: Float {
        cameraProjection.near
    }

    @inlinable
    public var far: Float {
        cameraProjection.far
    }

    @inlinable
    public func makeClipView() -> Math.Transform3D {
        cameraProjection.makeClipView()
    }

    @inlinable
    public mutating func updateView(width: Float, height: Float) {
        switch self {
        case var .orthographic(orthographicProjection):
            orthographicProjection.updateView(width: width, height: height)
            self = .orthographic(orthographicProjection)
        case var .perspective(perspectiveProjection):
            perspectiveProjection.updateView(width: width, height: height)
            self = .perspective(perspectiveProjection)
        case var .custom(cameraProjection):
            cameraProjection.updateView(width: width, height: height)
            self = .custom(cameraProjection)
        }
    }
}

public struct OrthographicProjection: CameraProjection {
    /// The closest point relative to camera that drawing will occur.
    public var near: Float

    /// The closest point relative to camera that drawing will occur
    public var far: Float

    /// Viewport center. By default point of view is center [0.5, 0.5]
    public var viewportOrigin: Vector2

    /// Scale of view.
    @MinValue(0.1)
    public var scale: Float = 1

    private var viewportSize: Size = .zero

    public init(
        near: Float = -1,
        far: Float = 1000,
        viewportOrigin: Vector2 = Vector2(0.5, 0.5),
        scale: Float = 1,
        viewportSize: Size = .zero
    ) {
        self.near = near
        self.far = far
        self.viewportOrigin = viewportOrigin
        self.scale = scale
        self.viewportSize = viewportSize
    }

    public func makeClipView() -> Transform3D {
        let totalHeight = viewportSize.height / scale
        let totalWidth = viewportSize.width / scale
        return Transform3D.orthographic(
            left: -totalWidth * viewportOrigin.x,
            right: totalWidth * (1 - viewportOrigin.x),
            top: totalHeight * (1 - viewportOrigin.y),
            bottom: -totalHeight * viewportOrigin.y,
            zNear: near,
            zFar: far
        )
    }

    public mutating func updateView(width: Float, height: Float) {
        assert(width > 0, "Width must be great zero")
        assert(height > 0, "Height must be great zero")
        self.viewportSize = Size(width: width, height: height)
    }
}

public struct PerspectiveProjection: CameraProjection {
    public var near: Float

    public var far: Float

    /// Angle of camera view
    public var fieldOfView: Angle

    public private(set) var aspectRation: Float

    public init(
        near: Float = 0.1,
        far: Float = 1000,
        fieldOfView: Angle = .degrees(70),
        aspectRation: Float = 16 / 9
    ) {
        self.near = near
        self.far = far
        self.fieldOfView = fieldOfView
        self.aspectRation = aspectRation
    }

    public func makeClipView() -> Transform3D {
        Transform3D.perspective(
            fieldOfView: fieldOfView,
            aspectRatio: aspectRation,
            zNear: near,
            zFar: far
        )
    }

    public mutating func updateView(width: Float, height: Float) {
        assert(width > 0, "Width must be great zero")
        assert(height > 0, "Height must be great zero")
        aspectRation = width / height
    }
}

/// Object that calculate camera projection
public protocol CameraProjection: Sendable, Codable {
    /// The closest point relative to camera that drawing will occur.
    var near: Float { get }

    /// The closest point relative to camera that drawing will occur
    var far: Float { get }

    /// Create a clip view.
    func makeClipView() -> Transform3D

    /// Update camera projection data.
    mutating func updateView(width: Float, height: Float)
}

extension CameraProjection {
    /// Make frustum from transform.
    public func makeFrustum(from transform: Transform3D) -> Frustum {
        Frustum.make(from: self.makeClipView() * transform)
    }
}
