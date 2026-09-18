//
//  MacOSKeyboard.swift
//
//
//  Created by v.prusakov on 5/1/24.
//

#if MACOS
    import AdaInput
    import AppKit

    final class MacOSKeyboard: Keyboard {
        @MainActor static var shared = MacOSKeyboard()

        override private init() {
            super.init()
        }

        override func initialize(keycodes: inout KeyCodeHashMap) {
            keycodes[0x00] = KeyCode.a
            keycodes[0x01] = KeyCode.s
            keycodes[0x02] = KeyCode.d
            keycodes[0x03] = KeyCode.f
            keycodes[0x04] = KeyCode.h
            keycodes[0x05] = KeyCode.g
            keycodes[0x06] = KeyCode.z
            keycodes[0x07] = KeyCode.x
            keycodes[0x08] = KeyCode.c
            keycodes[0x09] = KeyCode.v
            //        keycodes[0x0a] = KeyCode.SECTION
            keycodes[0x0b] = KeyCode.b
            keycodes[0x0c] = KeyCode.q
            keycodes[0x0d] = KeyCode.w
            keycodes[0x0e] = KeyCode.e
            keycodes[0x0f] = KeyCode.r
            keycodes[0x10] = KeyCode.y
            keycodes[0x11] = KeyCode.t
            keycodes[0x12] = KeyCode.num1
            keycodes[0x13] = KeyCode.num2
            keycodes[0x14] = KeyCode.num3
            keycodes[0x15] = KeyCode.num4
            keycodes[0x16] = KeyCode.num6
            keycodes[0x17] = KeyCode.num5
            keycodes[0x18] = KeyCode.equals
            keycodes[0x19] = KeyCode.num9
            keycodes[0x1a] = KeyCode.num7
            keycodes[0x1b] = KeyCode.minus
            keycodes[0x1c] = KeyCode.num8
            keycodes[0x1d] = KeyCode.num0
            keycodes[0x1e] = KeyCode.rightBracket
            keycodes[0x1f] = KeyCode.o
            keycodes[0x20] = KeyCode.u
            keycodes[0x21] = KeyCode.leftBracket
            keycodes[0x22] = KeyCode.i
            keycodes[0x23] = KeyCode.p
            keycodes[0x24] = KeyCode.enter
            keycodes[0x25] = KeyCode.l
            keycodes[0x26] = KeyCode.j
            keycodes[0x27] = KeyCode.apostrophe
            keycodes[0x28] = KeyCode.k
            keycodes[0x29] = KeyCode.semicolon
            keycodes[0x2a] = KeyCode.backslash
            keycodes[0x2b] = KeyCode.comma
            keycodes[0x2c] = KeyCode.slash
            keycodes[0x2d] = KeyCode.n
            keycodes[0x2e] = KeyCode.m
            keycodes[0x2f] = KeyCode.period
            keycodes[0x30] = KeyCode.tab
            keycodes[0x31] = KeyCode.space
            //        keycodes[0x32] = KeyCode.QUOTELEFT
            keycodes[0x33] = KeyCode.backspace
            keycodes[0x35] = KeyCode.escape
            keycodes[0x36] = KeyCode.meta
            keycodes[0x37] = KeyCode.meta
            keycodes[0x38] = KeyCode.shift
            keycodes[0x39] = KeyCode.capslock
            keycodes[0x3a] = KeyCode.alt
            keycodes[0x3b] = KeyCode.ctrl
            keycodes[0x3c] = KeyCode.shift
            keycodes[0x3d] = KeyCode.alt
            keycodes[0x3e] = KeyCode.ctrl
            keycodes[0x40] = KeyCode.f17
            //        keycodes[0x41] = KeyCode.KP_PERIOD
            //        keycodes[0x43] = KeyCode.KP_MULTIPLY
            //        keycodes[0x45] = KeyCode.KP_ADD
            //        keycodes[0x47] = KeyCode.NUMLOCK
            keycodes[0x48] = KeyCode.volumeUp
            keycodes[0x49] = KeyCode.volumeDown
            keycodes[0x4a] = KeyCode.volumeMute
            //        keycodes[0x4b] = KeyCode.KP_DIVIDE
            //        keycodes[0x4c] = KeyCode.KP_ENTER
            //        keycodes[0x4e] = KeyCode.KP_SUBTRACT
            keycodes[0x4f] = KeyCode.f18
            keycodes[0x50] = KeyCode.f19
            keycodes[0x51] = KeyCode.equals
            //        keycodes[0x52] = KeyCode.KP_0
            //        keycodes[0x53] = KeyCode.KP_1
            //        keycodes[0x54] = KeyCode.KP_2
            //        keycodes[0x55] = KeyCode.KP_3
            //        keycodes[0x56] = KeyCode.KP_4
            //        keycodes[0x57] = KeyCode.KP_5
            //        keycodes[0x58] = KeyCode.KP_6
            //        keycodes[0x59] = KeyCode.KP_7
            keycodes[0x5a] = KeyCode.f20
            //        keycodes[0x5b] = KeyCode.KP_8
            //        keycodes[0x5c] = KeyCode.KP_9
            //        keycodes[0x5d] = KeyCode.YEN
            keycodes[0x5e] = KeyCode.underscore
            keycodes[0x5f] = KeyCode.comma
            keycodes[0x60] = KeyCode.f5
            keycodes[0x61] = KeyCode.f6
            keycodes[0x62] = KeyCode.f7
            keycodes[0x63] = KeyCode.f3
            keycodes[0x64] = KeyCode.f8
            keycodes[0x65] = KeyCode.f9
            //        keycodes[0x66] = KeyCode.JIS_EISU
            keycodes[0x67] = KeyCode.f11
            //        keycodes[0x68] = KeyCode.JIS_KANA
            keycodes[0x69] = KeyCode.f13
            keycodes[0x6a] = KeyCode.f16
            keycodes[0x6b] = KeyCode.f14
            keycodes[0x6d] = KeyCode.f10
            //        keycodes[0x6e] = KeyCode.MENU
            keycodes[0x6f] = KeyCode.f12
            keycodes[0x71] = KeyCode.f15
            keycodes[0x72] = KeyCode.insert
            keycodes[0x73] = KeyCode.home
            keycodes[0x74] = KeyCode.pageUp
            keycodes[0x75] = KeyCode.delete
            keycodes[0x76] = KeyCode.f4
            //        keycodes[0x77] = KeyCode.END
            keycodes[0x78] = KeyCode.f2
            keycodes[0x79] = KeyCode.pageDown
            keycodes[0x7a] = KeyCode.f1
            keycodes[0x7b] = KeyCode.arrowLeft
            keycodes[0x7c] = KeyCode.arrowRight
            keycodes[0x7d] = KeyCode.arrowDown
            keycodes[0x7e] = KeyCode.arrowUp
        }

        func translateKey(from osKeyCode: UInt16) -> KeyCode {
            return self.keycodes[osKeyCode] ?? KeyCode.none
        }

        func osKeyCode(from key: KeyCode) -> UInt16 {
            return self.keycodesInverse[key] ?? 0
        }
    }

#endif
