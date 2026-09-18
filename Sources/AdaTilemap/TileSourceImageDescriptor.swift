import AdaAssets
import Foundation
import Math

/// Portable image and slicing settings stored inside a texture tile source.
public struct TileSourceImageDescriptor: Codable, Equatable, Sendable {
    public var path: String
    public var tileSize: SizeInt
    /// Empty border around the image, in pixels on each side.
    public var margin: SizeInt
    /// Gap between neighboring tiles, in pixels.
    public var spacing: SizeInt

    public init(path: String, tileSize: SizeInt = [16, 16], margin: SizeInt = .zero, spacing: SizeInt = .zero) {
        self.path = path
        self.tileSize = tileSize
        self.margin = margin
        self.spacing = spacing
    }

    public func validate() throws {
        let dimensions = [tileSize.width, tileSize.height, margin.width, margin.height, spacing.width, spacing.height]
        guard
            !path.isEmpty, tileSize.width > 0, tileSize.height > 0,
            dimensions.allSatisfy({ (0...1_048_576).contains($0) })
        else {
            throw AssetDecodingError.decodingProblem("Tile source needs an image, positive tile dimensions and nonnegative margin/spacing.")
        }
    }

    /// Number of complete tiles; partial cells at the right and bottom are excluded.
    public func gridSize(imageSize: SizeInt) -> SizeInt {
        guard (try? validate()) != nil else {
            return .zero
        }
        return SizeInt(
            width: max(0, imageSize.width - 2 * margin.width + spacing.width) / (tileSize.width + spacing.width),
            height: max(0, imageSize.height - 2 * margin.height + spacing.height) / (tileSize.height + spacing.height)
        )
    }

    public func resolvedPath(relativeTo directory: URL) -> String {
        if path.hasPrefix("@res://") || path.hasPrefix("file://") || path.hasPrefix("/") || path.hasPrefix("\\\\") || (path.count > 2 && path.dropFirst().hasPrefix(":")) {
            return path
        }
        return directory.appendingPathComponent(path).standardizedFileURL.path
    }
}
