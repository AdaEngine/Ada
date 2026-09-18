//
//  UIImageView.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 20.06.2024.
//

import AdaRender
import AdaUtils
import Math

/// A view that displays a single image or a sequence of animated images in your interface.
public class UIImageView: UIView {
    /// The image displayed in the image view.
    public var image: Image? {
        get {
            self.texture?.image
        }
        set {
            self.setImage(newValue)
        }
    }

    /// The texture displayed in the image view.
    public var texture: Texture2D? {
        didSet {
            parentView?.setNeedsLayout()
            setNeedsDisplay()
        }
    }

    /// The tint color of the image view.
    public var tintColor: Color = .white

    /// Initialize a new image view.
    ///
    /// - Parameter image: The image to set.
    public init(image: Image?) {
        super
            .init(
                frame: Rect(
                    origin: .zero,
                    size: Size(
                        width: Float(image?.width ?? 0),
                        height: Float(image?.height ?? 0)
                    )
                )
            )
        self.setImage(image)
    }

    @MainActor public required init(frame: Rect) {
        super.init(frame: frame)
    }

    /// Set the image of the image view.
    ///
    /// - Parameter image: The image to set.
    private func setImage(_ image: Image?) {
        guard let image else {
            self.texture = nil
            return
        }

        self.texture = Texture2D(image: image)
    }

    /// Draw the image view.
    ///
    /// - Parameters:
    ///   - rect: The rect to draw the image view in.
    ///   - context: The context to draw the image view in.
    override public func draw(in rect: Rect, with context: UIGraphicsContext) {
        context.drawRect(rect, texture: self.texture, color: self.tintColor)
    }

    /// The minimum content size of the image view.
    override public var minimumContentSize: Size {
        return Size(width: Float(self.texture?.width ?? 0), height: Float(self.texture?.height ?? 0))
    }
}
