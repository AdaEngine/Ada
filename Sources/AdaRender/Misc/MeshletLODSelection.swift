import Math

/// Conservative pixel-error selection over an offline prepared forest. This never constructs geometry.
public enum MeshletLODSelection {
  /// Returns a complete, nonoverlapping cut before frustum rejection, in flat node/index order.
  public static func selectedNodes(
    geometry: MeshletLODGeometry, transform: Transform3D, viewProjection: Transform3D,
    viewport: SizeInt, pixelError: Float
  ) -> [Int] {
    let context = Projection(
      transform: transform, viewProjection: viewProjection, viewport: viewport)
    var pending = geometry.roots
    var selected: [Int] = []
    while let index = pending.popLast() {
      let node = geometry.nodes[index]
      if node.childCount == 0
        || (pixelError.isFinite && pixelError > 0 && context.error(node) <= pixelError)
      {
        selected.append(index)
      } else {
        pending.append(contentsOf: node.firstChild..<(node.firstChild + node.childCount))
      }
    }
    selected.sort()
    return selected
  }

  /// Upper bound for affine transformation of an absolute model-space displacement, including shear.
  public static func scaleBound(_ transform: Transform3D) -> Float {
    let norm1 = max(
      abs(transform.x.x) + abs(transform.x.y) + abs(transform.x.z),
      max(
        abs(transform.y.x) + abs(transform.y.y) + abs(transform.y.z),
        abs(transform.z.x) + abs(transform.z.y) + abs(transform.z.z)))
    let normInfinity = max(
      abs(transform.x.x) + abs(transform.y.x) + abs(transform.z.x),
      max(
        abs(transform.x.y) + abs(transform.y.y) + abs(transform.z.y),
        abs(transform.x.z) + abs(transform.y.z) + abs(transform.z.z)))
    return (norm1 * normInfinity).squareRoot()
  }

  private struct Projection {
    let transform: Transform3D
    let x: Vector4
    let y: Vector4
    let w: Vector4
    let pixelScale: Vector2
    let modelScale: Float
    let rowLengths: Vector3

    init(transform: Transform3D, viewProjection: Transform3D, viewport: SizeInt) {
      self.transform = transform
      x = viewProjection.row(at: 0)
      y = viewProjection.row(at: 1)
      w = viewProjection.row(at: 3)
      pixelScale = [Float(max(0, viewport.width)) * 0.5, Float(max(0, viewport.height)) * 0.5]
      modelScale = MeshletLODSelection.scaleBound(transform)
      rowLengths = [x.xyz.length, y.xyz.length, w.xyz.length]
    }

    func error(_ node: MeshletLODNode) -> Float {
      guard pixelScale.x > 0, pixelScale.y > 0 else { return .infinity }
      let localCenter = (node.minimum + node.maximum) * 0.5
      let e = (node.maximum - node.minimum) * 0.5
      let center = (transform * Vector4(localCenter, 1)).xyz
      let extent = Vector3(
        abs(transform.x.x) * e.x + abs(transform.y.x) * e.y + abs(transform.z.x) * e.z,
        abs(transform.x.y) * e.x + abs(transform.y.y) * e.y + abs(transform.z.y) * e.z,
        abs(transform.x.z) * e.x + abs(transform.y.z) * e.y + abs(transform.z.z) * e.z)
      func radius(_ row: Vector4) -> Float {
        abs(row.x) * extent.x + abs(row.y) * extent.y + abs(row.z) * extent.z
      }
      let minimumW = w.xyz.dot(center) + w.w - radius(w)
      let displacement = node.error * modelScale
      let deltaW = displacement * rowLengths.z
      let expandedW = minimumW - deltaW
      guard minimumW.isFinite, expandedW > 0.0001 else { return .infinity }
      let maximumX = abs(x.xyz.dot(center) + x.w) + radius(x)
      let maximumY = abs(y.xyz.dot(center) + y.w) + radius(y)
      let xError = (displacement * rowLengths.x + maximumX / minimumW * deltaW) / expandedW
      let yError = (displacement * rowLengths.y + maximumY / minimumW * deltaW) / expandedW
      let pixels = max(xError * pixelScale.x, yError * pixelScale.y)
      return pixels.isFinite ? pixels : .infinity
    }
  }
}

/// Explicit 48-byte storage ABI, independent of CPU hierarchy/optional layout.
struct MeshletLODNodeGPU: Sendable {
  var minimum: Vector4
  var maximum: Vector4
  /// Parent ID (UInt32.max for a root), child count, first cluster, cluster count.
  var metadata: SIMD4<UInt32>

  init(_ node: MeshletLODNode) {
    minimum = Vector4(node.minimum, node.error)
    maximum = Vector4(node.maximum, Float(node.level))
    metadata = SIMD4(
      node.parent.map { UInt32($0) } ?? UInt32.max, UInt32(node.childCount),
      UInt32(node.firstCluster), UInt32(node.clusterCount))
  }
}
