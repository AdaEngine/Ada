@_exported import AdaUIDescription
import Foundation
import Observation

/// Instance-owned UI data and actions. Bind existing game state explicitly with `bind`.
@MainActor @Observable
public final class UIBindingContext {
    public typealias Action = @MainActor ([String: UIValue]) throws -> Void
    private var values: [String: UIValue]
    @ObservationIgnored private var bindings: [String: Binding<UIValue>] = [:]
    @ObservationIgnored private var handlers: [String: Action] = [:]
    public private(set) var diagnostics: [UIDiagnostic] = []
    public private(set) var revision: UInt64 = 0

    @ObservationIgnored private let parent: UIBindingContext?
    public init(values: [String: UIValue] = [:], parent: UIBindingContext? = nil) {
        self.values = values
        self.parent = parent
    }

    public func value(_ path: String) -> UIValue? {
        _ = revision
        if let binding = bindings[path] {
            return binding.wrappedValue
        }
        if let value = values[path] {
            return value
        }
        let parts = path.split(separator: ".").map(String.init)
        guard let first = parts.first else {
            return nil
        }
        return (bindings[first]?.wrappedValue ?? values[first])?.value(at: parts.dropFirst()) ?? parent?.value(path)
    }

    public func set(_ path: String, to value: UIValue) {
        guard self.value(path) != value else {
            return
        }
        if let binding = bindings[path] {
            binding.wrappedValue = value
        } else if values[path] != nil {
            values[path] = value
        } else {
            let parts = path.split(separator: ".").map(String.init)
            if let first = parts.first, parts.count > 1,
                let original = bindings[first]?.wrappedValue ?? values[first],
                let updated = original.setting(value, at: parts.dropFirst()) {
                if let binding = bindings[first] {
                    binding.wrappedValue = updated
                } else {
                    values[first] = updated
                }
            } else if let parent, parent.value(path) != nil {
                parent.set(path, to: value)
            } else {
                values[path] = value
            }
        }
        revision &+= 1
    }

    public func bind(_ name: String, to binding: Binding<UIValue>) {
        let existed = bindings[name] != nil
        bindings[name] = binding
        if !existed {
            revision &+= 1
        }
    }

    public func unbind(_ name: String) { bindings.removeValue(forKey: name) }

    public func binding(_ name: String) -> Binding<UIValue> {
        Binding(get: { self.value(name) ?? .null }, set: { self.set(name, to: $0) })
    }

    public func on(_ name: String, perform action: @escaping Action) { handlers[name] = action }
    public func hasAction(_ name: String) -> Bool { handlers[name] != nil || parent?.hasAction(name) == true }
    public func invalidate() { revision &+= 1 }

    public func perform(_ name: String, arguments: [String: UIValue] = [:]) {
        do {
            guard let action = handlers[name] else {
                if let parent {
                    parent.perform(name, arguments: arguments)
                    return
                }
                throw UIDiagnostic("Missing action '\(name)'.")
            }
            try action(arguments)
            revision &+= 1
        } catch {
            report(UIDiagnostic(error.localizedDescription))
        }
    }

    public func report(_ diagnostic: UIDiagnostic) {
        if diagnostics.last != diagnostic {
            diagnostics.append(diagnostic)
        }
    }

    struct Snapshot {
        let values: [String: UIValue]
        let bindings: [String: Binding<UIValue>]
        let handlers: [String: Action]
    }

    func snapshot() -> Snapshot { Snapshot(values: values, bindings: bindings, handlers: handlers) }
    func restore(_ snapshot: Snapshot) {
        values = snapshot.values
        bindings = snapshot.bindings
        handlers = snapshot.handlers
        revision &+= 1
    }

    public func applyDefaults(_ inputs: [UIParameter]) {
        for input in inputs where value(input.name) == nil {
            if let value = input.defaultValue {
                set(input.name, to: value)
            }
        }
    }
}
