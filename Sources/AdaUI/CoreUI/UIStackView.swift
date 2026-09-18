//
//  UIStackView.swift
//
//
//  Created by Vladislav Prusakov on 20.06.2024.
//

import Math

/// A view that arranges its subviews in a horizontal or vertical stack.
public class UIStackView: UIView {
    /// The axis along which the stack view lays out its subviews.
    public enum Axis {
        case horizontal
        case vertical
    }

    /// The layout rule of the stack view.
    public enum LayoutRule {
        case fillEqually
    }

    /// The axis along which the stack view lays out its subviews.
    public var axis: Axis = .horizontal {
        didSet {
            setNeedsLayout()
        }
    }

    /// The spacing between the subviews of the stack view.
    public var spacing: Float = 0 {
        didSet {
            setNeedsLayout()
        }
    }

    /// The layout rule of the stack view.
    public var layoutRule: LayoutRule = .fillEqually {
        didSet {
            setNeedsLayout()
        }
    }

    /// Initialize a new stack view.
    ///
    /// - Parameters:
    ///   - axis: The axis along which the stack view lays out its subviews.
    ///   - children: The subviews of the stack view.
    public init(_ axis: Axis, children: [UIView]) {
        super.init(frame: .zero)
        self.axis = axis

        children.forEach {
            $0.frame.origin = [0, 0]
            self.addSubview($0)
        }
    }

    /// Initialize a new stack view.
    ///
    /// - Parameter frame: The frame of the stack view.
    public required init(frame: Rect) {
        super.init(frame: frame)
    }

    /// Layout the subviews of the stack view.
    override public func layoutSubviews() {
        if frame == .zero {
            super.layoutSubviews()
            return
        }

        let count = self.subviews.count

        var origin: Point = .zero

        for subview in self.subviews {
            var size: Size = .zero

            switch layoutRule {
            case .fillEqually:
                let proposalWidth = self.axis == .horizontal ? self.frame.width / Float(count) : self.frame.width
                let proposalHeight = self.axis == .vertical ? self.frame.height / Float(count) : self.frame.height
                let proposal = ProposedViewSize(
                    width: proposalWidth,
                    height: proposalHeight
                )

                size = subview.sizeThatFits(proposal)
            }

            subview.frame.size = size
            subview.frame.origin = origin

            if axis == .vertical {
                origin.y += spacing + size.height
            } else {
                origin.x += spacing + size.width
            }
        }

        super.layoutSubviews()
    }
}
