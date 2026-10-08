//
//  UIViewUpdateRegressionTests.swift
//  AdaEngine
//

import AdaUtils
import Testing
@testable import AdaUI

@MainActor
struct UIViewUpdateRegressionTests {

    @Test
    func internalUpdateVisitsEveryViewExactlyOncePerFrame() {
        let root = UpdateCountingView()
        let child = UpdateCountingView()
        let grandchild = UpdateCountingView()

        root.addSubview(child)
        child.addSubview(grandchild)

        root.internalUpdate(1 / 60)

        #expect(root.updateCount == 1)
        #expect(child.updateCount == 1)
        #expect(grandchild.updateCount == 1)
    }
}

@MainActor
private final class UpdateCountingView: UIView {
    private(set) var updateCount = 0

    override func update(_ deltaTime: TimeInterval) {
        updateCount += 1
    }
}
