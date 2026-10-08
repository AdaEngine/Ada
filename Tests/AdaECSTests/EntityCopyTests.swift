import Testing
@testable import AdaECS

@Suite
struct EntityCopyTests {
    @Test(arguments: [false, true])
    func copyKeepsComponentsWhenInsertedIntoAnotherWorld(attached: Bool) throws {
        let sourceWorld = World()
        let original = Entity(name: "Template") {
            ComponentA(value: 42)
            ComponentB(value: "Original")
        }
        original.isActive = false
        if attached {
            sourceWorld.addEntity(original)
        }

        let copy = original.copy()
        #expect(copy !== original)
        #expect(copy.world == nil)
        #expect(copy.name == original.name)
        #expect(!copy.isActive)
        #expect(copy.components[ComponentA.self]?.value == 42)

        let destinationWorld = World()
        destinationWorld.addEntity(copy)
        copy.components[ComponentA.self]?.value = 17

        #expect(copy.components[ComponentA.self]?.value == 17)
        #expect(copy.components[ComponentB.self]?.value == "Original")
        #expect(original.components[ComponentA.self]?.value == 42)
        if attached {
            #expect(sourceWorld.getEntityByID(original.id) != nil)
        }
    }
}
