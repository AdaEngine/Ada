import AdaECS
import Gravity
import Testing

@testable import AdaScripting

@Suite("AdaScript reflected value bridge", .serialized)
struct AdaScriptValueBridgeTests {
    @Test("Immediate scalar lists round trip during frequent collection")
    func scalarLists() throws {
        try withBridgeVM { vm in
            vm.setGCAllocationBudget(1)
            let values: [ReflectedFieldValue] = [
                .array([]),
                .array([.int(Int.max), .int(Int.min), .int(0)]),
                .array([.double(-0.0), .double(1e-200), .double(1e200)]),
                .array([.bool(true), .bool(false), .null, .double(1.5), .int(-42)])
            ]
            for _ in 0..<100 {
                for value in values {
                    let encoded = AnnotatedGravityValueBridge.makeGravityValue(value, virtualMachine: vm)
                    #expect(AnnotatedGravityValueBridge.makeReflectedFieldValue(encoded) == value)
                }
            }
            let signedZero = AnnotatedGravityValueBridge.makeGravityValue(.array([.double(-0.0)]), virtualMachine: vm)
            #expect(signedZero.toList[0].toDouble.sign == .minus)
        }
    }

    @Test("Nested/string lists and color channel order retain their representation")
    func compositeValues() throws {
        try withBridgeVM { vm in
            let nested: ReflectedFieldValue = .array([
                .string("Ветер 🍁"), .array([.int(7), .null, .bool(true)]), .array([])
            ])
            let encoded = AnnotatedGravityValueBridge.makeGravityValue(nested, virtualMachine: vm)
            #expect(AnnotatedGravityValueBridge.makeReflectedFieldValue(encoded) == nested)
            let color = AnnotatedGravityValueBridge.makeGravityValue(.object([
                "blue": .double(0.3), "alpha": .double(0.4), "red": .double(0.1), "green": .double(0.2)
            ]), virtualMachine: vm)
            #expect(AnnotatedGravityValueBridge.makeReflectedFieldValue(color) == .array([
                .double(0.1), .double(0.2), .double(0.3), .double(0.4)
            ]))
            #expect(AnnotatedGravityValueBridge.makeReflectedFieldValue(GSValue(undefinedIn: vm)) == .null)
            #expect(AnnotatedGravityValueBridge.makeReflectedFieldValue(GSValue(range: 1..<4, in: vm)) == nil)
        }
    }
}

private func withBridgeVM(_ body: (GravityVirtualMachine) throws -> Void) throws {
    AdaScriptRuntimeCoordinator.lock.lock()
    defer { AdaScriptRuntimeCoordinator.lock.unlock() }
    let module = try GravityScriptModuleResolver.resolve([.init(path: "Bridge.ada", source: "var marker = 0;")])
    let delegate = AnnotatedGravityRuntimeDelegate(module: module)
    let vm = GravityVirtualMachine(settings: .init(), delegate: delegate)
    vm.load(vm.loadGravityFile(from: "var marker = 0;"))
    try body(vm)
    #expect(delegate.errors.isEmpty, "\(delegate.errors)")
}
