//
//  ImageView.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 24.06.2024.
//

import AdaAssets
@_spi(Internal) import AdaRender
import AdaUtils
import Foundation
import Math

/// The render mode of the image view.
public enum ImageRenderMode: Codable, Sendable {
    /// The original render mode.
    case original
    /// The template render mode.
    case template
}

extension Image: View, ViewNodeBuilder {
    public typealias Body = Never
    public var body: Never { fatalError("Unreachable code") }

    func buildViewNode(in context: BuildContext) -> ViewNode {
        ImageViewNode(
            image: self,
            isResizable: self.options[Keys.resizable.rawValue] as? Bool ?? false,
            renderMode: self.options[Keys.renderMode.rawValue] as? ImageRenderMode ?? .original,
            tintColor: context.environment.foregroundColor,
            capInsets: self.options[Keys.capInsets.rawValue] as? ImageCapInsets,
            content: self
        )
    }
}

extension Image {
    private enum Keys: String {
        case capInsets
        case resizable
        case renderMode
    }

    /// Make the image resizable.
    ///
    /// - Returns: The image view.
    public func resizable() -> Image {
        var newValue = self
        newValue.options[Keys.resizable.rawValue] = true
        return newValue
    }

    /// Stretches the center and edges while preserving corners in source-pixel units.
    /// If the destination is smaller than the corners, opposing corners shrink proportionally.
    public func resizable(capInsets: ImageCapInsets) -> Image {
        var image = resizable()
        image.options[Keys.capInsets.rawValue] = capInsets
        return image
    }

    /// Set the render mode.
    ///
    /// - Parameter mode: The render mode.
    /// - Returns: The image view.
    public func renderMode(_ mode: ImageRenderMode) -> Image {
        var newValue = self
        newValue.options[Keys.renderMode.rawValue] = mode
        return newValue
    }
}

final class ImageViewNode: ViewNode {
    /// The texture.
    private(set) var texture: Texture2D
    private var slices: [(column: Int, row: Int, texture: Texture2D)]
    private var sliceGrid: ImageSliceGrid?
    /// A Boolean value indicating whether the image view is resizable.
    private(set) var isResizable: Bool
    /// The render mode.
    private(set) var renderMode: ImageRenderMode
    /// The tint color.
    private(set) var tintColor: Color?

    init<Content: View>(
        image: Image,
        isResizable: Bool,
        renderMode: ImageRenderMode,
        tintColor: Color?,
        capInsets: ImageCapInsets? = nil,
        content: Content
    ) {
        if let capInsets, capInsets != .init(0) {
            let atlas = TextureAtlas(from: image, size: SizeInt(width: image.width, height: image.height))
            let grid = ImageSliceGrid(width: image.width, height: image.height, insets: capInsets)
            self.texture = atlas
            self.sliceGrid = grid
            self.slices = (0..<3)
                .flatMap { row in
                    (0..<3)
                        .compactMap { column in
                            atlas.textureSlice(in: grid.sourceRect(column: column, row: row)).map { (column, row, $0 as Texture2D) }
                        }
                }
        } else {
            self.texture = Texture2D(image: image)
            self.sliceGrid = nil
            self.slices = []
        }
        self.tintColor = tintColor
        self.renderMode = renderMode
        self.isResizable = isResizable
        super.init(content: content)
    }

    override func update(from newNode: ViewNode) {
        guard let otherNode = newNode as? ImageViewNode else {
            super.update(from: newNode)
            return
        }

        super.update(from: otherNode)
        texture = otherNode.texture
        slices = otherNode.slices
        sliceGrid = otherNode.sliceGrid
        isResizable = otherNode.isResizable
        renderMode = otherNode.renderMode
        tintColor = otherNode.tintColor
        markNeedsLayout()
        invalidateNearestLayer()
        owner?.containerView?.setNeedsDisplay(in: visualAbsoluteFrame())
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        if isResizable {
            return proposal.replacingUnspecifiedDimensions(by: Size(width: Float(texture.width), height: Float(texture.height)))
        }

        return proposal.replacingUnspecifiedDimensions()
    }

    override func draw(with context: UIGraphicsContext) {
        let tintColor = renderMode == .original ? .white : tintColor ?? .white
        if let grid = sliceGrid {
            for slice in slices {
                let rect = grid.destinationRect(column: slice.column, row: slice.row, frame: frame)
                if rect.size.width > 0, rect.size.height > 0 {
                    context.drawRect(rect, texture: slice.texture, color: tintColor)
                }
            }
        } else {
            context.drawRect(self.frame, texture: self.texture, color: tintColor)
        }
        super.draw(with: context)
    }
}
