//
//  ShaderEffectModifier.swift
//  AdaEngine
//

import AdaRender
import Math

public enum ShaderEffectPlacement: Sendable {
    case background
    case overlay
}

extension View {
    /// Renders a custom UI shader material in this view's bounds.
    public func shaderEffect<T: UIShaderMaterial>(
        _ material: CustomMaterial<T>,
        placement: ShaderEffectPlacement = .overlay
    ) -> some View {
        self.modifier(
            ShaderEffectModifier(
                content: self,
                material: material,
                placement: placement
            )
        )
    }
}

private struct ShaderEffectModifier<Content: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never

    let content: Content
    let material: Material
    let placement: ShaderEffectPlacement

    func buildViewNode(in context: BuildContext) -> ViewNode {
        let contentNode = context.makeNode(from: content)
        let node = ShaderEffectViewNode(contentNode: contentNode, content: content)
        node.material = material
        node.placement = placement
        return node
    }
}

final class ShaderEffectViewNode: ViewModifierNode {
    var material: Material?
    var placement: ShaderEffectPlacement = .overlay

    override func draw(with context: UIGraphicsContext) {
        var ctx = context
        ctx.translateBy(x: frame.origin.x, y: -frame.origin.y)

        if placement == .background {
            drawShaderEffect(with: ctx)
        }

        contentNode.draw(with: ctx)

        if placement == .overlay {
            drawShaderEffect(with: ctx)
        }
    }

    override func update(from newNode: ViewNode) {
        guard let other = newNode as? ShaderEffectViewNode else {
            return
        }

        super.update(from: other)
        self.material = other.material
        self.placement = other.placement
    }

    private func drawShaderEffect(with context: UIGraphicsContext) {
        guard let material else {
            return
        }

        let rect = Rect(origin: .zero, size: frame.size)
        context.drawShaderEffect(rect, material: material)
    }
}
