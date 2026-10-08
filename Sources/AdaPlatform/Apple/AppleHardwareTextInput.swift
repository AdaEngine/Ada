import AdaInput
import Foundation

struct AppleHardwareTextInput {
    struct Payload: Equatable {
        let text: String
        let action: TextInputEvent.Action
    }

    static func payload(
        keyCode: KeyCode,
        modifiers: KeyModifier,
        characters: String
    ) -> Payload? {
        if keyCode == .backspace {
            return Payload(text: "", action: .deleteBackward)
        }

        if modifiers.contains(.main) || modifiers.contains(.control) {
            return nil
        }

        guard !nonTextKeyCodes.contains(keyCode) else {
            return nil
        }

        let sanitizedText =
            characters
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")

        guard !sanitizedText.isEmpty else {
            return nil
        }

        let containsUnsupportedScalars = sanitizedText.unicodeScalars.contains { scalar in
            let value = scalar.value
            return value < 0x20 || value == 0x7F || (0xF700...0xF8FF).contains(value)
        }

        guard !containsUnsupportedScalars else {
            return nil
        }
        return Payload(text: sanitizedText, action: .insert)
    }

    private static let nonTextKeyCodes: Set<KeyCode> = [
        .none,
        .enter,
        .tab,
        .escape,
        .delete,
        .home,
        .pageUp,
        .pageDown,
        .shift,
        .ctrl,
        .alt,
        .meta,
        .capslock,
        .arrowUp,
        .arrowDown,
        .arrowLeft,
        .arrowRight,
        .f1,
        .f2,
        .f3,
        .f4,
        .f5,
        .f6,
        .f7,
        .f8,
        .f9,
        .f10,
        .f11,
        .f12,
        .f13,
        .f14,
        .f15,
        .f16,
        .f17,
        .f18,
        .f19,
        .f20,
        .volumeDown,
        .volumeUp,
        .volumeMute,
    ]
}
