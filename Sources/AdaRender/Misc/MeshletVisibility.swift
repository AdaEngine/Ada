import Foundation
import Math
import Synchronization

/// A singleton coarse draw. Geometry and its source buffer must belong to the same immutable asset generation.
public struct MeshletVisibilityDraw: Sendable {
  public let geometry: MeshletGeometry
  public let sourceIndexBuffer: any IndexBuffer
  public let transform: Transform3D
  public let forceVisible: Bool
  public let lod: MeshletLODGeometry?
  public let lodPixelError: Float
  public let viewport: SizeInt
  public let lodViewProjection: Transform3D?
  /// Offline-validated maximum size of a complete hierarchy cut.
  public var maximumIndexCount: Int { lod?.baseIndexCount ?? geometry.indices.count }
  var cacheID: UUID { lod?.id ?? geometry.id }

  public init(
    geometry: MeshletGeometry, sourceIndexBuffer: any IndexBuffer, transform: Transform3D,
    forceVisible: Bool = false, lod: MeshletLODGeometry? = nil, lodPixelError: Float = 0,
    viewport: SizeInt = .zero, lodViewProjection: Transform3D? = nil
  ) {
    let hierarchy =
      lodPixelError.isFinite && lodPixelError > 0 && viewport.width > 0 && viewport.height > 0
      ? lod : nil
    self.geometry = hierarchy?.geometry ?? geometry
    self.sourceIndexBuffer = sourceIndexBuffer
    self.transform = transform
    self.forceVisible = forceVisible
    self.lod = hierarchy
    self.lodPixelError = hierarchy == nil ? 0 : lodPixelError
    self.viewport = viewport
    self.lodViewProjection = lodViewProjection
  }
}

/// One compacted index segment and one 20-byte indexed-indirect command per input draw, in input order.
public struct MeshletVisibilityOutput: Sendable {
  public let indices: any IndexBuffer
  public let arguments: any Buffer
  public let drawCount: Int

  public init(indices: any IndexBuffer, arguments: any Buffer, drawCount: Int) {
    self.indices = indices
    self.arguments = arguments
    self.drawCount = drawCount
  }
}

/// Per-view portable frustum classification, stable prefix scan and index scatter.
/// The caller must encode ALL consumers of the returned buffers on this same command buffer.
/// A busy frame ring or unsupported/oversized input returns nil before encoding; use original geometry.
/// No GPU counters are read back during normal rendering. Hi-Z and cone culling are not enabled here.
public protocol MeshletVisibilityProcessor: AnyObject, Sendable {
  func encode(
    on command: any CommandBuffer, viewProjection: Transform3D, draws: [MeshletVisibilityDraw]
  ) -> MeshletVisibilityOutput?
}

/// Releases a transient slot on GPU completion, or when an unsubmitted command is discarded.
/// The once guard prevents a later closure destruction from freeing an already-reused slot.
final class MeshletFrameLease: Sendable {
  private let finished = Mutex(false)
  private let releaseSlot: @Sendable () -> Void

  init(release: @escaping @Sendable () -> Void) { releaseSlot = release }

  func release() {
    let first = finished.withLock { value in
      if value { return false }
      value = true
      return true
    }
    if first { releaseSlot() }
  }

  deinit { release() }
}

/// Explicit 64-byte storage ABI; no dependency on Vector3 padding.
struct MeshletGPUDescriptor: Sendable {
  var range: SIMD4<UInt32>
  var minimum: Vector4
  var maximum: Vector4
  var reserved: SIMD4<UInt32> = .zero

  init(_ cluster: MeshletCluster) {
    range = SIMD4(UInt32(cluster.firstIndex), UInt32(cluster.indexCount), 0, 0)
    minimum = Vector4(cluster.minimum, 0)
    maximum = Vector4(cluster.maximum, 0)
  }
}

struct MeshletGPUView: Sendable {
  var projection: Transform3D
  var transform: Transform3D
  /// Output first index, draw ID, number of clusters, force-visible flag.
  var parameters: SIMD4<UInt32>
  /// Unjittered projection keeps the LOD cut stable while raster sampling jitters.
  var lodProjection: Transform3D = .identity
  /// Output viewport width/height, allowed pixel error (zero disables LOD), model displacement scale.
  var lod: Vector4 = .zero
}

enum MeshletVisibilityLimits {
  static let bufferBytes = 128 * 1024 * 1024
  static let persistentBytes = 256 * 1024 * 1024
  static let transientBytes = 192 * 1024 * 1024
  static let clustersPerDraw = 65_536
  static let lodClustersPerDraw = 262_144
  static let totalClusters = 524_288
  static let draws = 65_535
  static let frameDrawCacheBytes = 32 * 1024 * 1024
  static let frameDrawCacheCount = draws

  static func bufferCapacity(required: Int, limit: Int) -> Int {
    guard required > 0, required <= limit else { return 0 }
    var capacity = min(256, limit)
    while capacity < required { capacity = min(capacity * 2, limit) }
    return capacity
  }

  static func finite(_ value: Transform3D) -> Bool {
    for column in [value.x, value.y, value.z, value.w] {
      for index in 0..<4 where !column[index].isFinite { return false }
    }
    return true
  }

  static func affine(_ value: Transform3D) -> Bool {
    value.x.w == 0 && value.y.w == 0 && value.z.w == 0 && value.w.w == 1
  }
}

struct MeshletVisibilityPlan {
  let firstIndices: [Int]
  let indexCount: Int
  let argumentBytes: Int
  let clusterCount: Int

  init?(
    draws: [MeshletVisibilityDraw], projection: Transform3D,
    bufferLimit: Int = MeshletVisibilityLimits.bufferBytes
  ) {
    guard !draws.isEmpty, draws.count <= MeshletVisibilityLimits.draws,
      MeshletVisibilityLimits.finite(projection)
    else { return nil }
    var starts: [Int] = []
    starts.reserveCapacity(draws.count)
    var indices = 0
    var clusters = 0
    for draw in draws {
      let geometry = draw.geometry
      guard !geometry.indices.isEmpty, !geometry.clusters.isEmpty,
        geometry.indices.count <= bufferLimit / 4,
        geometry.clusters.count
          <= (draw.lod == nil
            ? MeshletVisibilityLimits.clustersPerDraw : MeshletVisibilityLimits.lodClustersPerDraw),
        indices <= bufferLimit / 4 - draw.maximumIndexCount,
        clusters <= MeshletVisibilityLimits.totalClusters - geometry.clusters.count,
        MeshletVisibilityLimits.finite(draw.transform),
        MeshletVisibilityLimits.affine(draw.transform)
      else { return nil }
      if let lod = draw.lod {
        guard lod.nodes.count <= MeshletVisibilityLimits.lodClustersPerDraw,
          draw.maximumIndexCount <= geometry.indices.count,
          draw.lodViewProjection.map(MeshletVisibilityLimits.finite) ?? true
        else { return nil }
      }
      starts.append(indices)
      indices += draw.maximumIndexCount
      clusters += geometry.clusters.count
    }
    let args = draws.count * MemoryLayout<IndexedIndirectArguments>.stride
    let groups = draws.reduce(0) { $0 + ($1.geometry.clusters.count + 255) / 256 }
    guard args <= bufferLimit,
      indices * 4 + args + clusters * 8 + groups * 8 <= MeshletVisibilityLimits.transientBytes
    else { return nil }
    firstIndices = starts
    indexCount = indices
    argumentBytes = args
    clusterCount = clusters
  }
}
