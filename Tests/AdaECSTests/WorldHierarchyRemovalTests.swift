import Testing
@testable import AdaECS

@Suite
struct WorldHierarchyRemovalTests {
    @Test(arguments: [false, true])
    func recursiveRemovalPreservesDescendantsUntilTraversal(useIdentifier: Bool) {
        let world = World()
        let parent = world.spawn("Parent")
        let child = world.spawn("Child")
        let grandchild = world.spawn("Grandchild")
        let sibling = world.spawn("Sibling")
        let unrelated = world.spawn("Unrelated")
        parent.addChild(child)
        parent.addChild(sibling)
        child.addChild(grandchild)

        if useIdentifier {
            world.removeEntity(parent.id, recursively: true)
        } else {
            world.removeEntity(parent, recursively: true)
        }

        for removed in [parent, child, grandchild, sibling] {
            #expect(world.getEntityByID(removed.id) == nil)
        }
        #expect(world.getEntityByID(unrelated.id) != nil)
    }

    @Test(arguments: [false, true])
    func nonrecursiveRemovalKeepsChildren(useIdentifier: Bool) {
        let world = World()
        let parent = world.spawn("Parent")
        let child = world.spawn("Child")
        parent.addChild(child)

        if useIdentifier {
            world.removeEntity(parent.id)
        } else {
            world.removeEntity(parent)
        }

        #expect(world.getEntityByID(parent.id) == nil)
        #expect(world.getEntityByID(child.id) != nil)
    }
}
