//
//  ZIndexModifier.swift
//  AdaEngine
//
//  Created by vladislav.prusakov on 31.07.2024.
//

import Math

extension View {
    public func zIndex(_ index: Int) -> some View {
        self.modifier(ZIndexModifier(index: index, content: self))
    }
}

struct ZIndexModifier<Content: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never
    let index: Int
    let content: Content

    func buildViewNode(in context: BuildContext) -> ViewNode {
        let node = ZIndexViewNode(contentNode: context.makeNode(from: content), content: content)
        node.zIndex = index
        return node
    }
}

class ZIndexViewNode: ViewModifierNode {
    var zIndex: Int = 0

    override func draw(with context: UIGraphicsContext) {
        var context = context
        context.concatenate(Transform3D(translation: Vector3(x: 0, y: 0, z: Float(zIndex))))
        self.contentNode.draw(with: context)
    }
}
