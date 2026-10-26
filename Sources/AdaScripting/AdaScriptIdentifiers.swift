import Foundation
import Gravity
#if canImport(GravityAOT)
import GravityAOT
#endif

private func makeUUID() -> String { Foundation.UUID().uuidString.lowercased() }

/// Stateless host-generated identifiers, independent of game clocks and random seeds.
@GSExportable("AdaIdentifiers")
final class AdaScriptIdentifiers: Sendable {
    func uuid() -> String { makeUUID() }

    @GSExportableIgnore
    static func bind(to virtualMachine: GravityVirtualMachine) throws {
        try virtualMachine.bindClass(with: AdaScriptIdentifiers.self)
        virtualMachine.setValue(AdaScriptIdentifiers(), forKey: "Identifiers")
    }
}

#if canImport(GravityAOT)
final class NativeIdentifiersHost: NativeSuspensionSafeHostObject {
    func call(_ method: String, arguments: [NativeValue]) throws -> NativeValue? {
        guard method == "uuid", arguments.isEmpty else { return nil }
        return .string(makeUUID())
    }
}
#endif
