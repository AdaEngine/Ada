import AdaEngine

/// Translates focused physical keys; printable Unicode arrives separately through TextInputEvent.
enum EditorTerminalKeyboard {
    static func isClipboardChord(_ modifiers: KeyModifier) -> Bool {
        #if os(macOS)
        modifiers.contains(.main)
        #else
        modifiers.contains(.control) && modifiers.contains(.shift)
        #endif
    }

    static func sequence(_ event: KeyEvent, applicationCursor: Bool) -> String? {
        if event.modifiers.contains(.control), event.keyCode == .space { return "\u{0}" }
        if event.modifiers.contains(.control), let byte = event.keyCode.rawValue.utf8.first,
           event.keyCode.rawValue.utf8.count == 1, byte >= 64 && byte <= 122 {
            return String(UnicodeScalar(byte & 31))
        }
        let prefix = applicationCursor ? "\u{1b}O" : "\u{1b}["
        let text: String? = switch event.keyCode {
        case .enter: "\r"
        case .tab: event.modifiers.contains(.shift) ? "\u{1b}[Z" : "\t"
        case .escape: "\u{1b}"
        case .delete: "\u{1b}[3~"
        case .arrowUp: prefix + "A"
        case .arrowDown: prefix + "B"
        case .arrowRight: prefix + "C"
        case .arrowLeft: prefix + "D"
        case .home: prefix + "H"
        case .pageUp: "\u{1b}[5~"
        case .pageDown: "\u{1b}[6~"
        case .f1: "\u{1b}OP"
        case .f2: "\u{1b}OQ"
        case .f3: "\u{1b}OR"
        case .f4: "\u{1b}OS"
        case .f5: "\u{1b}[15~"
        case .f6: "\u{1b}[17~"
        case .f7: "\u{1b}[18~"
        case .f8: "\u{1b}[19~"
        case .f9: "\u{1b}[20~"
        case .f10: "\u{1b}[21~"
        case .f11: "\u{1b}[23~"
        case .f12: "\u{1b}[24~"
        default: nil
        }
        return text
    }
}
