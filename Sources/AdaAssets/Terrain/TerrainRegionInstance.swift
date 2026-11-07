import Math

/// Attachment and optional nearby collision requests. Decorative placements have no collision by default.
public struct TerrainInstanceFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let anchored = Self(rawValue: 1)
    public static let alignToNormal = Self(rawValue: 2)
    public static let collision = Self(rawValue: 4)
}

/// One compact placement; position and offset use base-cell units relative to the region's origin.
/// Quaternion/normal channels use signed16-bit encoding; tints use normalized RGBA8.
public struct TerrainRegionInstance: Equatable, Sendable {
    public let id: UInt64
    public let prototypeID: UInt16
    public let localPosition: Vector3
    public let scale: Vector3
    public let seed: UInt32
    public let flags: TerrainInstanceFlags
    public let anchorOffset: Float
    // Preserve encoded channels across load/save without renormalization/requantization drift.
    let rotationBits: UInt64
    let tintBits: UInt32
    let normalBits: UInt32

    public var rotation: Quat {
        let x = Self.snorm(UInt16(truncatingIfNeeded: rotationBits))
        let y = Self.snorm(UInt16(truncatingIfNeeded: rotationBits >> 16))
        let z = Self.snorm(UInt16(truncatingIfNeeded: rotationBits >> 32))
        let w = Self.snorm(UInt16(truncatingIfNeeded: rotationBits >> 48))
        let length = (x * x + y * y + z * z + w * w).squareRoot()
        return Quat(x: Float(x / length), y: Float(y / length), z: Float(z / length), w: Float(w / length))
    }

    public var tint: Vector4 {
        Vector4(Float(tintBits & 255), Float((tintBits >> 8) & 255), Float((tintBits >> 16) & 255), Float(tintBits >> 24)) / 255
    }

    public var anchorNormal: Vector3 {
        var x = Self.snorm(UInt16(truncatingIfNeeded: normalBits))
        var z = Self.snorm(UInt16(truncatingIfNeeded: normalBits >> 16))
        let y = 1 - abs(x) - abs(z)
        if y < 0 {
            let previousX = x
            x = (1 - abs(z)) * Self.sign(x)
            z = (1 - abs(previousX)) * Self.sign(z)
        }
        let length = (x * x + y * y + z * z).squareRoot()
        return Vector3(Float(x / length), Float(y / length), Float(z / length))
    }

    public init(
        id: UInt64,
        prototypeID: UInt16,
        localPosition: Vector3,
        rotation: Quat = .identity,
        scale: Vector3 = .one,
        tint: Vector4 = .one,
        seed: UInt32 = 0,
        flags: TerrainInstanceFlags = [.anchored],
        anchorNormal: Vector3 = [0, 1, 0],
        anchorOffset: Float = 0
    ) throws {
        guard rotation.x.isFinite, rotation.y.isFinite, rotation.z.isFinite, rotation.w.isFinite,
            anchorNormal.x.isFinite, anchorNormal.y.isFinite, anchorNormal.z.isFinite,
            (0...1).contains(tint.x), (0...1).contains(tint.y), (0...1).contains(tint.z), (0...1).contains(tint.w)
        else {
            throw TerrainRegionError.malformed("invalid instance rotation, normal or tint")
        }
        let qx = Double(rotation.x), qy = Double(rotation.y), qz = Double(rotation.z), qw = Double(rotation.w)
        let qLength = (qx * qx + qy * qy + qz * qz + qw * qw).squareRoot()
        let nx = Double(anchorNormal.x), ny = Double(anchorNormal.y), nz = Double(anchorNormal.z)
        let nLength = abs(nx) + abs(ny) + abs(nz)
        guard qLength > 0, nLength > 0 else {
            throw TerrainRegionError.malformed("instance rotation and attachment normal must be nonzero")
        }
        let flip = qw < 0 || (qw == 0 && (qx < 0 || (qx == 0 && (qy < 0 || (qy == 0 && qz < 0)))))
        let divisor = flip ? -qLength : qLength
        let packedRotation =
            UInt64(Self.pack(qx / divisor)) | UInt64(Self.pack(qy / divisor)) << 16
            | UInt64(Self.pack(qz / divisor)) << 32 | UInt64(Self.pack(qw / divisor)) << 48
        var ox = nx / nLength, oz = nz / nLength
        if ny < 0 {
            let previousX = ox
            ox = (1 - abs(oz)) * Self.sign(ox)
            oz = (1 - abs(previousX)) * Self.sign(oz)
        }
        let packedNormal = UInt32(Self.pack(ox)) | UInt32(Self.pack(oz)) << 16
        let packedTint =
            UInt32((tint.x * 255).rounded()) | UInt32((tint.y * 255).rounded()) << 8
            | UInt32((tint.z * 255).rounded()) << 16 | UInt32((tint.w * 255).rounded()) << 24
        try self.init(
            id: id,
            prototypeID: prototypeID,
            localPosition: localPosition,
            rotationBits: packedRotation,
            scale: scale,
            tintBits: packedTint,
            seed: seed,
            flags: flags,
            normalBits: packedNormal,
            anchorOffset: anchorOffset
        )
    }

    init(
        id: UInt64,
        prototypeID: UInt16,
        localPosition: Vector3,
        rotationBits: UInt64,
        scale: Vector3,
        tintBits: UInt32,
        seed: UInt32,
        flags: TerrainInstanceFlags,
        normalBits: UInt32,
        anchorOffset: Float
    ) throws {
        self.id = id; self.prototypeID = prototypeID; self.localPosition = localPosition
        self.rotationBits = rotationBits; self.scale = scale; self.tintBits = tintBits
        self.seed = seed; self.flags = flags; self.normalBits = normalBits; self.anchorOffset = anchorOffset
        try validate()
    }

    /// Updates surface attachment while retaining stable IDs and unrelated compact channels exactly.
    /// Height and offset use base-cell units; nil rotation retains the existing packed quaternion.
    public func updatingAnchor(localHeight: Float, normal: Vector3, rotation: Quat? = nil) throws -> Self {
        let position = Vector3(localPosition.x, localHeight, localPosition.z)
        let channels = try Self(
            id: id,
            prototypeID: prototypeID,
            localPosition: position,
            rotation: rotation ?? .identity,
            scale: scale,
            seed: seed,
            flags: flags,
            anchorNormal: normal,
            anchorOffset: anchorOffset
        )
        return try Self(
            id: id,
            prototypeID: prototypeID,
            localPosition: position,
            rotationBits: rotation == nil ? rotationBits : channels.rotationBits,
            scale: scale,
            tintBits: tintBits,
            seed: seed,
            flags: flags,
            normalBits: channels.normalBits,
            anchorOffset: anchorOffset
        )
    }

    func validate() throws {
        guard (0..<256).contains(localPosition.x), (0..<256).contains(localPosition.z), localPosition.y.isFinite,
            scale.x.isFinite, scale.y.isFinite, scale.z.isFinite,
            (0.0001...10_000).contains(abs(scale.x)), (0.0001...10_000).contains(abs(scale.y)), (0.0001...10_000).contains(abs(scale.z)),
            flags.rawValue & ~UInt16(7) == 0, anchorOffset.isFinite, rotationBits != 0
        else {
            throw TerrainRegionError.malformed("invalid instance position, scale, flags or attachment")
        }
        for shift in stride(from: 0, to: 64, by: 16) where UInt16(truncatingIfNeeded: rotationBits >> shift) == 0x8000 {
            throw TerrainRegionError.malformed("invalid signed rotation channel")
        }
        guard UInt16(truncatingIfNeeded: normalBits) != 0x8000, UInt16(truncatingIfNeeded: normalBits >> 16) != 0x8000 else {
            throw TerrainRegionError.malformed("invalid signed normal channel")
        }
    }

    private static func snorm(_ bits: UInt16) -> Double { Double(Int16(bitPattern: bits)) / 32_767 }
    private static func pack(_ value: Double) -> UInt16 { UInt16(bitPattern: Int16((max(-1, min(1, value)) * 32_767).rounded())) }
    private static func sign(_ value: Double) -> Double { value < 0 ? -1 : 1 }
}
