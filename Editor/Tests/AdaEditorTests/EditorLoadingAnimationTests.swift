@_spi(AdaEngine) import AdaEngine
@_spi(Internal) @testable import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@MainActor @Suite(.serialized)
struct EditorLoadingAnimationTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "LoadingAnimation")))
        }
    }

    @Test func spinnerAndFooterGeometryChangeAcrossIdleFrames() async throws {
        let view = EditorFooter(viewModel: .init(leftItems: [], rightItems: []), activities: [.init(id: "agent", kind: .agent, title: "Working")])
            .frame(width: 1000, height: 80).theme(.adaEditor)
        let container = UIContainerView(rootView: view)
        container.frame = Rect(x: 0, y: 0, width: 1000, height: 80)
        container.layoutIfNeeded()
        // Studio's surrounding observable views rebuild while work is active.
        container.updateRootView(view)
        container.layoutIfNeeded()
        let first = paths(container)
        try await Task.sleep(for: .milliseconds(180))
        container.update(0.18)
        container.layoutIfNeeded()
        let second = paths(container)
        #expect(first.count == second.count)
        #expect(zip(first, second).filter { $0 != $1 }.count >= 2)
    }

    private func paths<Content: View>(_ container: UIContainerView<Content>) -> [PaintPath] {
        let context = UIGraphicsContext()
        container.draw(with: context)
        return context.getDrawCommands().compactMap { command in
            guard case let .drawPath(path, transform, _) = command else {
                return nil
            }
            var elements: [Path.Element] = []
            path.forEach { elements.append($0) }
            return PaintPath(elements: elements, transform: transform)
        }
    }
    private struct PaintPath: Equatable {
        let elements: [Path.Element]
        let transform: Transform3D
    }
}
