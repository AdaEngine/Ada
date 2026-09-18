//
//  AppleEmbeddedKeyboard.swift
//  AdaEngine
//
//  Created by v.prusakov on 2/5/26.
//

#if canImport(UIKit)
    import AdaInput
    import UIKit

    /// iOS keyboard implementation using HID usage codes.
    /// UIKeyboardHIDUsage already follows the USB HID standard.
    final class AppleEmbeddedKeyboard: Keyboard {
        @MainActor static let shared = AppleEmbeddedKeyboard()

        override private init() {
            super.init()
        }

        override func initialize(keycodes: inout KeyCodeHashMap) {
            // Letters (HID codes 0x04 - 0x1D)
            keycodes[0x04] = KeyCode.a  // keyboardA
            keycodes[0x05] = KeyCode.b  // keyboardB
            keycodes[0x06] = KeyCode.c  // keyboardC
            keycodes[0x07] = KeyCode.d  // keyboardD
            keycodes[0x08] = KeyCode.e  // keyboardE
            keycodes[0x09] = KeyCode.f  // keyboardF
            keycodes[0x0A] = KeyCode.g  // keyboardG
            keycodes[0x0B] = KeyCode.h  // keyboardH
            keycodes[0x0C] = KeyCode.i  // keyboardI
            keycodes[0x0D] = KeyCode.j  // keyboardJ
            keycodes[0x0E] = KeyCode.k  // keyboardK
            keycodes[0x0F] = KeyCode.l  // keyboardL
            keycodes[0x10] = KeyCode.m  // keyboardM
            keycodes[0x11] = KeyCode.n  // keyboardN
            keycodes[0x12] = KeyCode.o  // keyboardO
            keycodes[0x13] = KeyCode.p  // keyboardP
            keycodes[0x14] = KeyCode.q  // keyboardQ
            keycodes[0x15] = KeyCode.r  // keyboardR
            keycodes[0x16] = KeyCode.s  // keyboardS
            keycodes[0x17] = KeyCode.t  // keyboardT
            keycodes[0x18] = KeyCode.u  // keyboardU
            keycodes[0x19] = KeyCode.v  // keyboardV
            keycodes[0x1A] = KeyCode.w  // keyboardW
            keycodes[0x1B] = KeyCode.x  // keyboardX
            keycodes[0x1C] = KeyCode.y  // keyboardY
            keycodes[0x1D] = KeyCode.z  // keyboardZ

            // Numbers (HID codes 0x1E - 0x27)
            keycodes[0x1E] = KeyCode.num1  // keyboard1
            keycodes[0x1F] = KeyCode.num2  // keyboard2
            keycodes[0x20] = KeyCode.num3  // keyboard3
            keycodes[0x21] = KeyCode.num4  // keyboard4
            keycodes[0x22] = KeyCode.num5  // keyboard5
            keycodes[0x23] = KeyCode.num6  // keyboard6
            keycodes[0x24] = KeyCode.num7  // keyboard7
            keycodes[0x25] = KeyCode.num8  // keyboard8
            keycodes[0x26] = KeyCode.num9  // keyboard9
            keycodes[0x27] = KeyCode.num0  // keyboard0

            // Control keys
            keycodes[0x28] = KeyCode.enter  // keyboardReturnOrEnter
            keycodes[0x29] = KeyCode.escape  // keyboardEscape
            keycodes[0x2A] = KeyCode.backspace  // keyboardDeleteOrBackspace
            keycodes[0x2B] = KeyCode.tab  // keyboardTab
            keycodes[0x2C] = KeyCode.space  // keyboardSpacebar

            // Punctuation and symbols
            keycodes[0x2D] = KeyCode.minus  // keyboardHyphen (-)
            keycodes[0x2E] = KeyCode.equals  // keyboardEqualSign (=)
            keycodes[0x2F] = KeyCode.leftBracket  // keyboardOpenBracket ([)
            keycodes[0x30] = KeyCode.rightBracket  // keyboardCloseBracket (])
            keycodes[0x31] = KeyCode.backslash  // keyboardBackslash
            // 0x32 - keyboardNonUSPound
            keycodes[0x33] = KeyCode.semicolon  // keyboardSemicolon
            keycodes[0x34] = KeyCode.apostrophe  // keyboardQuote
            keycodes[0x35] = KeyCode.backquote  // keyboardGraveAccentAndTilde
            keycodes[0x36] = KeyCode.comma  // keyboardComma
            keycodes[0x37] = KeyCode.period  // keyboardPeriod
            keycodes[0x38] = KeyCode.slash  // keyboardSlash

            // Modifier keys
            keycodes[0x39] = KeyCode.capslock  // keyboardCapsLock

            // Function keys (HID codes 0x3A - 0x45 for F1-F12)
            keycodes[0x3A] = KeyCode.f1  // keyboardF1
            keycodes[0x3B] = KeyCode.f2  // keyboardF2
            keycodes[0x3C] = KeyCode.f3  // keyboardF3
            keycodes[0x3D] = KeyCode.f4  // keyboardF4
            keycodes[0x3E] = KeyCode.f5  // keyboardF5
            keycodes[0x3F] = KeyCode.f6  // keyboardF6
            keycodes[0x40] = KeyCode.f7  // keyboardF7
            keycodes[0x41] = KeyCode.f8  // keyboardF8
            keycodes[0x42] = KeyCode.f9  // keyboardF9
            keycodes[0x43] = KeyCode.f10  // keyboardF10
            keycodes[0x44] = KeyCode.f11  // keyboardF11
            keycodes[0x45] = KeyCode.f12  // keyboardF12

            // Extended function keys
            keycodes[0x68] = KeyCode.f13  // keyboardF13
            keycodes[0x69] = KeyCode.f14  // keyboardF14
            keycodes[0x6A] = KeyCode.f15  // keyboardF15
            keycodes[0x6B] = KeyCode.f16  // keyboardF16
            keycodes[0x6C] = KeyCode.f17  // keyboardF17
            keycodes[0x6D] = KeyCode.f18  // keyboardF18
            keycodes[0x6E] = KeyCode.f19  // keyboardF19
            keycodes[0x6F] = KeyCode.f20  // keyboardF20

            // Navigation keys
            keycodes[0x49] = KeyCode.insert  // keyboardInsert
            keycodes[0x4A] = KeyCode.home  // keyboardHome
            keycodes[0x4B] = KeyCode.pageUp  // keyboardPageUp
            keycodes[0x4C] = KeyCode.delete  // keyboardDeleteForward
            // 0x4D - keyboardEnd (not in KeyCode)
            keycodes[0x4E] = KeyCode.pageDown  // keyboardPageDown

            // Arrow keys
            keycodes[0x4F] = KeyCode.arrowRight  // keyboardRightArrow
            keycodes[0x50] = KeyCode.arrowLeft  // keyboardLeftArrow
            keycodes[0x51] = KeyCode.arrowDown  // keyboardDownArrow
            keycodes[0x52] = KeyCode.arrowUp  // keyboardUpArrow

            // Modifier keys (left side)
            keycodes[0xE0] = KeyCode.ctrl  // keyboardLeftControl
            keycodes[0xE1] = KeyCode.shift  // keyboardLeftShift
            keycodes[0xE2] = KeyCode.alt  // keyboardLeftAlt
            keycodes[0xE3] = KeyCode.meta  // keyboardLeftGUI (Command)

            // Modifier keys (right side)
            keycodes[0xE4] = KeyCode.ctrl  // keyboardRightControl
            keycodes[0xE5] = KeyCode.shift  // keyboardRightShift
            keycodes[0xE6] = KeyCode.alt  // keyboardRightAlt
            keycodes[0xE7] = KeyCode.meta  // keyboardRightGUI (Command)

            // Media keys (Consumer page - using Apple's mapping)
            keycodes[0x80] = KeyCode.volumeMute  // keyboardMute
            keycodes[0x81] = KeyCode.volumeUp  // keyboardVolumeUp
            keycodes[0x82] = KeyCode.volumeDown  // keyboardVolumeDown
        }

        /// Translate iOS HID usage code to engine KeyCode.
        /// - Parameter hidUsage: The UIKeyboardHIDUsage raw value.
        /// - Returns: The corresponding KeyCode, or .none if not found.
        func translateKey(from hidUsage: UIKeyboardHIDUsage) -> KeyCode {
            return self.keycodes[UInt16(hidUsage.rawValue)] ?? KeyCode.none
        }

        /// Translate from raw HID usage code to engine KeyCode.
        /// - Parameter rawHIDCode: The raw HID usage code as Int.
        /// - Returns: The corresponding KeyCode, or .none if not found.
        func translateKey(from rawHIDCode: Int) -> KeyCode {
            return self.keycodes[UInt16(rawHIDCode)] ?? KeyCode.none
        }

        func osKeyCode(from key: KeyCode) -> UInt16 {
            return self.keycodesInverse[key] ?? 0
        }
    }

#endif
