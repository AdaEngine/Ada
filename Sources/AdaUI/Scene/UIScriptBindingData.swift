import Foundation
import Logging

package struct UIScriptFieldSnapshot {
    package let owner: ObjectIdentifier
    package let value: UIValue

    package init(owner: ObjectIdentifier, value: UIValue) {
        self.owner = owner
        self.value = value
    }
}

/// Detached UI values. UI callbacks enqueue writes; only the script synchronization system applies them.
@MainActor
final class UIScriptBindingData {
    let context: UIBindingContext
    private var slots: [String: Slot] = [:]

    init(values: [String: UIValue]) { context = UIBindingContext(values: values) }

    func synchronize(
        mappings: [String: UIScriptFieldBinding],
        read: (UIScriptFieldBinding) throws -> UIScriptFieldSnapshot,
        write: (UIScriptFieldBinding, UIValue) throws -> Void
    ) {
        for (name, mapping) in mappings {
            do {
                let slot: Slot
                if let existing = slots[name] {
                    slot = existing
                } else {
                    slot = Slot()
                    slots[name] = slot
                    context.bind(
                        name,
                        to: Binding(
                            get: { slot.value },
                            set: { value in
                                slot.value = value
                                slot.pending = value
                            }
                        )
                    )
                }
                // Validate that the target still exists before consuming a queued UI edit.
                let snapshot = try read(mapping)
                if slot.owner != snapshot.owner {
                    slot.pending = nil
                    slot.owner = snapshot.owner
                }
                let value: UIValue
                if let pending = slot.pending {
                    slot.pending = nil
                    try write(mapping, pending)
                    value = try read(mapping).value
                } else {
                    value = snapshot.value
                }
                if slot.value != value {
                    slot.value = value
                    context.invalidate()
                }
                slot.lastError = nil
            } catch {
                let message = "UI input '\(name)': \(error.localizedDescription)"
                if let slot = slots[name] {
                    slot.pending = nil
                    if slot.value != .null {
                        slot.value = .null
                        context.invalidate()
                    }
                    if slot.lastError != message {
                        context.report(UIDiagnostic(message))
                        Logger(label: "org.adaengine.UIBindings").error("\(message)")
                        slot.lastError = message
                    }
                }
            }
        }
    }

    private final class Slot {
        var value: UIValue = .null
        var pending: UIValue?
        var owner: ObjectIdentifier?
        var lastError: String?
    }
}
