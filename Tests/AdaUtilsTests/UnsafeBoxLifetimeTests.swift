import AdaUtils
import Testing

private final class BoxLifetimeValue: Sendable {
    let value: Int
    init(_ value: Int) { self.value = value }
}

@Suite("UnsafeBox lifetime")
struct UnsafeBoxLifetimeTests {
    @Test("Managed boxes destroy their value after the last alias")
    func managedAliases() {
        var value: BoxLifetimeValue? = BoxLifetimeValue(1)
        weak var weakValue = value
        var box = value.map { UnsafeBox($0) }
        var alias = box
        value = nil
        box = nil
        #expect(alias?.wrappedValue.value == 1)
        #expect(weakValue != nil)
        alias = nil
        #expect(weakValue == nil)
    }

    @Test("A managed lease retains both its value and its allocation owner")
    func retainedOwner() {
        var owner: BoxLifetimeValue? = BoxLifetimeValue(2)
        var value: BoxLifetimeValue? = BoxLifetimeValue(3)
        weak var weakOwner = owner
        weak var weakValue = value
        var box: UnsafeBox<BoxLifetimeValue>?
        if let owner, let value {
            box = UnsafeBox(value, retaining: owner)
        }
        owner = nil
        value = nil
        #expect(box?.wrappedValue.value == 3)
        #expect(weakOwner != nil)
        #expect(weakValue != nil)
        box = nil
        #expect(weakOwner == nil)
        #expect(weakValue == nil)
    }

    @Test("Pointer boxes remain borrowed and never destroy the external value")
    func borrowedPointer() {
        let pointer = UnsafeMutablePointer<BoxLifetimeValue>.allocate(capacity: 1)
        unsafe pointer.initialize(to: BoxLifetimeValue(4))
        weak var weakValue = unsafe pointer.pointee
        func useBoxes() {
            let box = unsafe UnsafeBox<BoxLifetimeValue>(pointer)
            let erased = unsafe UnsafeAnyBox(pointer)
            let opaque = unsafe UnsafeAnyBox(OpaquePointer(pointer))
            #expect(box.wrappedValue.value == 4)
            #expect(erased.bind(to: BoxLifetimeValue.self).wrappedValue.value == 4)
            #expect(opaque.bind(to: BoxLifetimeValue.self).wrappedValue.value == 4)
        }
        useBoxes()
        #expect(weakValue != nil)
        #expect(unsafe pointer.pointee.value == 4)
        unsafe pointer.deinitialize(count: 1)
        unsafe pointer.deallocate()
        #expect(weakValue == nil)
    }
}
