import CGravity
import Synchronization
import Testing

@testable import AdaScripting

@Suite("Gravity allocation-count collection budget", .serialized)
struct GravityGCAllocationBudgetTests {
    @Test("The object budget collects temporaries and preserves reachable lists")
    func budgetCollectsGarbage() throws {
        try withProbeVM { vm in
            let kept = try #require(gravity_list_new(vm, 0))
            gravity_list_push_value(kept, gravity_value_from_int(19))
            "kept".withCString { gravity_vm_setvalue(vm, $0, gravity_value_from_object(kept)) }
            gravity_gc_start(vm)
            gravity_gc_set_allocation_budget(vm, 4)

            for _ in 0..<4 { try makeDiscardedList(vm) }
            #expect(GCAllocationProbe.frees.withLock { $0 } == 0)
            try makeDiscardedList(vm)
            #expect(GCAllocationProbe.frees.withLock { $0 } == 4)
            #expect(kept.pointee.array.n == 1)
            #expect(kept.pointee.array.p[0].n == 19)
        }
    }

    @Test("Suspended collection protects a native binding until it is rooted")
    func suspendedBindings() throws {
        try withProbeVM { vm in
            gravity_gc_set_allocation_budget(vm, 4)
            gravity_gc_setenabled(vm, false)
            let kept = try #require(gravity_list_new(vm, 0))
            gravity_list_push_value(kept, gravity_value_from_int(42))
            for _ in 0..<12 { try makeDiscardedList(vm) }
            #expect(GCAllocationProbe.frees.withLock { $0 } == 0)
            "kept".withCString { gravity_vm_setvalue(vm, $0, gravity_value_from_object(kept)) }
            gravity_gc_setenabled(vm, true)
            #expect(GCAllocationProbe.frees.withLock { $0 } == 12)
            #expect(kept.pointee.array.p[0].n == 42)
        }
    }

    @Test("Zero disables only the object-count trigger")
    func originalPolicy() throws {
        try withProbeVM { vm in
            gravity_gc_set_allocation_budget(vm, 0)
            for _ in 0..<64 { try makeDiscardedList(vm) }
            #expect(GCAllocationProbe.frees.withLock { $0 } == 0)
            gravity_gc_start(vm)
            #expect(GCAllocationProbe.frees.withLock { $0 } == 64)
        }
    }
}

private enum GCAllocationProbe {
    static let frees = Mutex(0)
}

private func withProbeVM(_ body: (OpaquePointer) throws -> Void) throws {
    // Gravity's process-wide core classes share the scripting runtime lock.
    AdaScriptRuntimeCoordinator.lock.lock()
    defer { AdaScriptRuntimeCoordinator.lock.unlock() }
    let vm = try #require(gravity_vm_new(nil))
    defer { gravity_vm_free(vm) }
    let fiber = try #require(gravity_fiber_new(vm, nil, 256, 16))
    gravity_vm_setfiber(vm, fiber)
    gravity_gc_setvalues(vm, 100_000_000, 100_000_000, 100)
    gravity_gc_start(vm)
    GCAllocationProbe.frees.withLock { $0 = 0 }
    try body(vm)
}

private func makeDiscardedList(_ vm: OpaquePointer) throws {
    let list = try #require(gravity_list_new(vm, 0))
    let object = UnsafeMutableRawPointer(list).assumingMemoryBound(to: gravity_object_t.self)
    object.pointee.gc.free = { vm, object in
        guard let object else { return 0 }
        GCAllocationProbe.frees.withLock { $0 += 1 }
        gravity_list_free(vm, UnsafeMutableRawPointer(object).assumingMemoryBound(to: gravity_list_t.self))
        return 0
    }
}
