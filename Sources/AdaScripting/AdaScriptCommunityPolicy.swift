import Foundation
import Gravity

/// Opt-in limits for downloaded community gameplay systems.
public struct AdaScriptCommunityPolicy: Sendable {
    public let maximumCheckpoints: Int
    public let maximumCallbackSeconds: Double
    public init(maximumCheckpoints: Int = 50_000, maximumCallbackSeconds: Double = 0.05) {
        self.maximumCheckpoints = max(1, maximumCheckpoints)
        self.maximumCallbackSeconds = max(0.001, maximumCallbackSeconds)
    }
}

@GSExportable("AdaUGCBudget")
final class AdaScriptCommunityBudget: @unchecked Sendable {
    @GSExportableIgnore private var remaining = 0
    @GSExportableIgnore private var deadline: UInt64 = 0
    @GSExportableIgnore private var policy = AdaScriptCommunityPolicy()
    @GSExportableIgnore private var spawnedEntities = 0

    @GSExportableIgnore
    func permitSpawn() -> Bool {
        spawnedEntities += 1
        return spawnedEntities <= 2048
    }

    @GSExportableIgnore
    func reset() {
        remaining = policy.maximumCheckpoints
        deadline = DispatchTime.now().uptimeNanoseconds + UInt64(policy.maximumCallbackSeconds * 1_000_000_000)
    }

    func check() -> Bool {
        remaining -= 1
        return remaining >= 0 && DispatchTime.now().uptimeNanoseconds < deadline
    }

    @GSExportableIgnore
    static func install(in vm: GravityVirtualMachine, policy: AdaScriptCommunityPolicy) throws -> AdaScriptCommunityBudget {
        let budget = AdaScriptCommunityBudget()
        budget.policy = policy
        budget.reset()
        try vm.bindClass(with: Self.self)
        vm.setValue(budget, forKey: "__adaUGCBudget")
        // The bridge closure carries the owning C VM. Never mutate shared core classes.
        let type = vm.getValue(forKey: Self.runtimeName)
        let key = GSValue(string: "check", in: vm)
        guard let closure = gravity_class_lookup_closure(type.toGravityClass, key.value), let pointer = closure.pointee.vm else {
            throw AdaScriptError.invalidManifest("Unable to configure community execution limits")
        }
        guard let function = closure.pointee.f else {
            throw AdaScriptError.invalidManifest("Missing community checkpoint function")
        }
        function.pointee.tag = EXEC_TYPE_INTERNAL
        function.pointee.internal = { vm, arguments, _, register in
            guard let vm, let arguments,
                  let opaque = gravity_vm_delegate(vm)?.pointee.xdata,
                  let machine = Unmanaged<AnyObject>.fromOpaque(opaque).takeUnretainedValue() as? GravityVirtualMachine,
                  let budget = GSValue(value: arguments[0], in: machine).toObjectOf(AdaScriptCommunityBudget.self),
                  budget.check() else {
                gravity_vm_setslot(vm, gravity_value_from_null(), register)
                gravity_vm_seterror_string(vm, "Community execution limit exceeded")
                return false
            }
            gravity_vm_setslot(vm, gravity_value_from_bool(true), register)
            return true
        }
        for (key, limit) in [("maxBlock", 8 * 1024 * 1024), ("maxStack", 4096), ("maxRecursionDepth", 128), ("maxCCalls", 128)] {
            _ = gravity_vm_set(pointer, key, GSValue(integer: limit, in: vm).value)
        }
        // System exposes process exit, stdin and mutable VM settings. Remove it in this VM only.
        vm.setValue(GSValue(nullIn: vm), forKey: "System")
        return budget
    }
}
