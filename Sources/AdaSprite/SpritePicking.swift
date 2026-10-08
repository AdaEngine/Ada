import AdaAssets
import AdaECS
import AdaRender
import AdaUtils
import Math

/// Alpha uses nearest base-level texels and multiplies by the sprite tint's alpha.
public enum SpritePickingMode: Codable, Hashable, Sendable {
    case bounds
    case alphaThreshold(Float)
}

/// Policy for GPU-only images or textures whose CPU alpha was invalidated by an upload.
public enum SpritePickingAlphaFallback: String, Codable, Sendable {
    case bounds
    case ignore
}

/// Opt-in runtime pointer interaction for a sprite. Nonblocking hits also deliver to lower sprites.
@Component
public struct SpritePickable: Codable {
    public var isEnabled: Bool
    public var mode: SpritePickingMode
    public var alphaFallback: SpritePickingAlphaFallback
    public var blocksLower: Bool

    public init(
        isEnabled: Bool = true,
        mode: SpritePickingMode = .alphaThreshold(0.1),
        alphaFallback: SpritePickingAlphaFallback = .bounds,
        blocksLower: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.mode = mode
        self.alphaFallback = alphaFallback
        self.blocksLower = blocksLower
    }
}

/// A reusable picking snapshot; tools can supply current composed transforms before ECS propagation.
public struct SpritePickingCandidate: Sendable {
    public let entityID: Entity.ID
    public let sprite: Sprite
    public let worldTransform: Transform3D
    public let pickable: SpritePickable

    public init(entityID: Entity.ID, sprite: Sprite, worldTransform: Transform3D, pickable: SpritePickable = SpritePickable()) {
        self.entityID = entityID
        self.sprite = sprite
        self.worldTransform = worldTransform
        self.pickable = pickable
    }
}

public struct SpritePickingRay: Sendable {
    public let ray: Ray
    public let maximumDistance: Float
}

/// Top-left logical viewport coordinates, with a rendered camera's 0...1 clip-depth interval.
public struct SpritePickingCamera: Sendable {
    public let entityID: Entity.ID
    public let viewport: Rect
    public let projection: Transform3D
    public let worldTransform: Transform3D
    public let renderOrder: Int

    public init(entityID: Entity.ID, viewport: Rect, projection: Transform3D, worldTransform: Transform3D, renderOrder: Int = 0) {
        self.entityID = entityID
        self.viewport = viewport
        self.projection = projection
        self.worldTransform = worldTransform
        self.renderOrder = renderOrder
    }

    public func ray(at point: Point) -> SpritePickingRay? {
        guard viewport.size.width > 0, viewport.size.height > 0,
            viewport.origin.x.isFinite, viewport.origin.y.isFinite,
            viewport.size.width.isFinite, viewport.size.height.isFinite,
            point.x.isFinite, point.y.isFinite,
            point.x >= viewport.minX, point.x < viewport.maxX, point.y >= viewport.minY, point.y < viewport.maxY,
            projection.determinant.isFinite, projection.determinant != 0 else {
            return nil
        }
        let ndc = Vector2((point.x - viewport.minX) / viewport.size.width * 2 - 1, 1 - (point.y - viewport.minY) / viewport.size.height * 2)
        let inverse = worldTransform * projection.inverse
        let near = inverse * Vector4(ndc.x, ndc.y, 0, 1)
        let far = inverse * Vector4(ndc.x, ndc.y, 1, 1)
        guard abs(near.w) > 0.000001, abs(far.w) > 0.000001 else {
            return nil
        }
        let origin = near.xyz / near.w
        let delta = far.xyz / far.w - origin
        let length = delta.length
        guard origin.x.isFinite, origin.y.isFinite, origin.z.isFinite, length.isFinite, length > 0 else {
            return nil
        }
        return SpritePickingRay(ray: Ray(origin: origin, direction: delta / length), maximumDistance: length)
    }
}

public struct SpritePickHit: Sendable {
    public let entityID: Entity.ID
    public let cameraID: Entity.ID
    public let worldPosition: Vector3
    public let localPosition: Vector2
    /// UV in the backing GPU texture, including atlas region, image mode and flips.
    public let textureCoordinate: Vector2
    public let distance: Float
}

/// Shared runtime/editor sprite picking. No method performs GPU readback.
public enum SpritePicker {
    /// Returns front-to-back hits, stopping at the first blocking candidate.
    /// Order matches the existing 2D painter order: higher world Z draws last.
    /// Equal-Z hits use descending entity ID for deterministic selection.
    public static func pick(at point: Point, camera: SpritePickingCamera, candidates: [SpritePickingCandidate]) -> [SpritePickHit] {
        guard let segment = camera.ray(at: point) else {
            return []
        }
        let hits = candidates.compactMap { candidate -> (SpritePickHit, Bool, Float)? in
            guard let hit = hitTest(candidate, ray: segment.ray, maximumDistance: segment.maximumDistance, cameraID: camera.entityID) else {
                return nil
            }
            return (hit, candidate.pickable.blocksLower, candidate.worldTransform.origin.z)
        }.sorted {
            if $0.2 != $1.2 {
                return $0.2 > $1.2
            }
            return $0.0.entityID > $1.0.entityID
        }
        var result: [SpritePickHit] = []
        for (hit, blocksLower, _) in hits {
            result.append(hit)
            if blocksLower {
                break
            }
        }
        return result
    }

    /// Intersects a world-space ray with the sprite's local plane and its rendered geometry.
    public static func hitTest(
        _ candidate: SpritePickingCandidate,
        ray: Ray,
        maximumDistance: Float = .infinity,
        cameraID: Entity.ID = 0
    ) -> SpritePickHit? {
        let matrix = candidate.worldTransform
        guard candidate.pickable.isEnabled, matrix.determinant.isFinite, matrix.determinant != 0 else {
            return nil
        }
        let inverse = matrix.inverse
        let localOrigin = inverse * Vector4(ray.origin, 1)
        let localDirection = inverse * Vector4(ray.direction, 0)
        guard localDirection.z.isFinite, abs(localDirection.z) > 0.000001 else {
            return nil
        }
        let distance = -localOrigin.z / localDirection.z
        guard distance.isFinite, distance >= 0, distance <= maximumDistance else {
            return nil
        }
        let point = (localOrigin + localDirection * distance).xyz.xy
        guard point.x.isFinite, point.y.isFinite else {
            return nil
        }
        let sprite = candidate.sprite
        let texture = sprite.texture?.asset
        let sourceSize = texture?.size.toSize().asVector2 ?? Vector2.one
        let geometry = SpriteGeometry(
            size: sprite.size?.asVector2 ?? sourceSize,
            sourceSize: sourceSize,
            anchor: sprite.anchor,
            imageMode: sprite.imageMode,
            flipX: sprite.flipX,
            flipY: sprite.flipY
        )
        guard var sampled = geometry.sourcePoint(at: point) else {
            return nil
        }
        if sprite.flipX { sampled.x = 1 - sampled.x }
        if sprite.flipY { sampled.y = 1 - sampled.y }
        let coordinates = texture?.textureCoordinates ?? [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
        guard coordinates.count == 4 else {
            return nil
        }
        let bottom = coordinates[0] + (coordinates[1] - coordinates[0]) * sampled.x
        let top = coordinates[3] + (coordinates[2] - coordinates[3]) * sampled.x
        let uv = bottom + (top - bottom) * sampled.y
        guard uv.x.isFinite, uv.y.isFinite else {
            return nil
        }
        if case let .alphaThreshold(threshold) = candidate.pickable.mode {
            guard threshold.isFinite, threshold >= 0, threshold <= 1, sprite.tintColor.alpha.isFinite else {
                return nil
            }
            let alpha: Float
            if let texture {
                if let mask = texture.pickingAlphaMask, let sampledAlpha = mask.alpha(at: uv) {
                    alpha = sampledAlpha
                } else if candidate.pickable.alphaFallback == .bounds {
                    alpha = 1
                } else {
                    return nil
                }
            } else {
                alpha = 1
            }
            guard min(1, max(0, alpha * sprite.tintColor.alpha)) > threshold else {
                return nil
            }
        }
        return SpritePickHit(
            entityID: candidate.entityID,
            cameraID: cameraID,
            worldPosition: ray.origin + ray.direction * distance,
            localPosition: point,
            textureCoordinate: uv,
            distance: distance
        )
    }
}
