@testable import AdaCorePipelines
import Testing

@Suite("Main 3D draw order")
struct Main3DDrawOrderTests {
    private final class Material {}

    @Test
    func opaqueDrawsAreGroupedByMaterialInFirstAppearanceOrder() {
        let stone = Material()
        let brick = Material()
        let ivy = Material()
        let items: [(name: String, material: Material)] = [
            ("stone-0", stone), ("brick-0", brick), ("stone-1", stone), ("ivy-0", ivy), ("brick-1", brick), ("stone-2", stone)
        ]
        let order = Main3DRenderNode.groupedOrder(items) { $0.material }
        #expect(order.map { items[$0].name } == ["stone-0", "stone-1", "stone-2", "brick-0", "brick-1", "ivy-0"])
    }

    @Test
    func distinctMaterialsKeepTheirOriginalOrder() {
        let items = (0 ..< 5).map { _ in Material() }
        #expect(Main3DRenderNode.groupedOrder(items) { $0 } == [0, 1, 2, 3, 4])
        #expect(Main3DRenderNode.firstAppearanceGroups(items) { $0 } == [0, 1, 2, 3, 4])
    }
}
