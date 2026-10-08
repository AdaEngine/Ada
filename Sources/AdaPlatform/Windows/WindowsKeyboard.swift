#if os(Windows)
    import AdaInput
    import WinSDK

    final class WindowsKeyboard: Keyboard {
        nonisolated(unsafe) static var shared = WindowsKeyboard()

        override private init() {
            super.init()
        }

        override func initialize(keycodes: inout KeyCodeHashMap) {
            keycodes[0x20] = KeyCode.space  // VK_SPACE
            keycodes[0x0D] = KeyCode.enter  // VK_RETURN
            keycodes[0x1B] = KeyCode.escape  // VK_ESCAPE
            keycodes[0x08] = KeyCode.backspace  // VK_BACK
            keycodes[0x09] = KeyCode.tab  // VK_TAB
            keycodes[0x2E] = KeyCode.delete  // VK_DELETE
            keycodes[0x24] = KeyCode.home  // VK_HOME
            keycodes[0x21] = KeyCode.pageUp  // VK_PRIOR
            keycodes[0x22] = KeyCode.pageDown  // VK_NEXT
            keycodes[0x25] = KeyCode.arrowLeft  // VK_LEFT
            keycodes[0x27] = KeyCode.arrowRight  // VK_RIGHT
            keycodes[0x26] = KeyCode.arrowUp  // VK_UP
            keycodes[0x28] = KeyCode.arrowDown  // VK_DOWN
            keycodes[0x10] = KeyCode.shift  // VK_SHIFT
            keycodes[0x11] = KeyCode.ctrl  // VK_CONTROL
            keycodes[0x12] = KeyCode.alt  // VK_MENU
            keycodes[0x5B] = KeyCode.meta  // VK_LWIN
            keycodes[0x5C] = KeyCode.meta  // VK_RWIN
            keycodes[0x14] = KeyCode.capslock  // VK_CAPITAL
            keycodes[0x70] = KeyCode.f1  // VK_F1
            keycodes[0x71] = KeyCode.f2  // VK_F2
            keycodes[0x72] = KeyCode.f3  // VK_F3
            keycodes[0x73] = KeyCode.f4  // VK_F4
            keycodes[0x74] = KeyCode.f5  // VK_F5
            keycodes[0x75] = KeyCode.f6  // VK_F6
            keycodes[0x76] = KeyCode.f7  // VK_F7
            keycodes[0x77] = KeyCode.f8  // VK_F8
            keycodes[0x78] = KeyCode.f9  // VK_F9
            keycodes[0x79] = KeyCode.f10  // VK_F10
            keycodes[0x7A] = KeyCode.f11  // VK_F11
            keycodes[0x7B] = KeyCode.f12  // VK_F12
            keycodes[0x30] = KeyCode.num0  // VK_0
            keycodes[0x31] = KeyCode.num1  // VK_1
            keycodes[0x32] = KeyCode.num2  // VK_2
            keycodes[0x33] = KeyCode.num3  // VK_3
            keycodes[0x34] = KeyCode.num4  // VK_4
            keycodes[0x35] = KeyCode.num5  // VK_5
            keycodes[0x36] = KeyCode.num6  // VK_6
            keycodes[0x37] = KeyCode.num7  // VK_7
            keycodes[0x38] = KeyCode.num8  // VK_8
            keycodes[0x39] = KeyCode.num9  // VK_9
            keycodes[0x41] = KeyCode.a  // VK_A
            keycodes[0x42] = KeyCode.b  // VK_B
            keycodes[0x43] = KeyCode.c  // VK_C
            keycodes[0x44] = KeyCode.d  // VK_D
            keycodes[0x45] = KeyCode.e  // VK_E
            keycodes[0x46] = KeyCode.f  // VK_F
            keycodes[0x47] = KeyCode.g  // VK_G
            keycodes[0x48] = KeyCode.h  // VK_H
            keycodes[0x49] = KeyCode.i  // VK_I
            keycodes[0x4A] = KeyCode.j  // VK_J
            keycodes[0x4B] = KeyCode.k  // VK_K
            keycodes[0x4C] = KeyCode.l  // VK_L
            keycodes[0x4D] = KeyCode.m  // VK_M
            keycodes[0x4E] = KeyCode.n  // VK_N
            keycodes[0x4F] = KeyCode.o  // VK_O
            keycodes[0x50] = KeyCode.p  // VK_P
            keycodes[0x51] = KeyCode.q  // VK_Q
            keycodes[0x52] = KeyCode.r  // VK_R
            keycodes[0x53] = KeyCode.s  // VK_S
            keycodes[0x54] = KeyCode.t  // VK_T
            keycodes[0x55] = KeyCode.u  // VK_U
            keycodes[0x56] = KeyCode.v  // VK_V
            keycodes[0x57] = KeyCode.w  // VK_W
            keycodes[0x58] = KeyCode.x  // VK_X
            keycodes[0x59] = KeyCode.y  // VK_Y
            keycodes[0x5A] = KeyCode.z  // VK_Z
            //        keycodes[0x0a] = KeyCode.SECTION
            //        keycodes[0x32] = KeyCode.QUOTELEFT
            //        keycodes[0x41] = KeyCode.KP_PERIOD
            //        keycodes[0x43] = KeyCode.KP_MULTIPLY
            //        keycodes[0x45] = KeyCode.KP_ADD
            //        keycodes[0x47] = KeyCode.NUMLOCK
            //        keycodes[0x4b] = KeyCode.KP_DIVIDE
            //        keycodes[0x4c] = KeyCode.KP_ENTER
            //        keycodes[0x4e] = KeyCode.KP_SUBTRACT
            //        keycodes[0x52] = KeyCode.KP_0
            //        keycodes[0x53] = KeyCode.KP_1
            //        keycodes[0x54] = KeyCode.KP_2
            //        keycodes[0x55] = KeyCode.KP_3
            //        keycodes[0x56] = KeyCode.KP_4
            //        keycodes[0x57] = KeyCode.KP_5
            //        keycodes[0x58] = KeyCode.KP_6
            //        keycodes[0x59] = KeyCode.KP_7
            //        keycodes[0x5b] = KeyCode.KP_8
            //        keycodes[0x5c] = KeyCode.KP_9
            //        keycodes[0x5d] = KeyCode.YEN
            //        keycodes[0x66] = KeyCode.JIS_EISU
            //        keycodes[0x68] = KeyCode.JIS_KANA
            //        keycodes[0x6e] = KeyCode.MENU
            //        keycodes[0x77] = KeyCode.END
        }

        func translateKey(from osKeyCode: UInt16) -> KeyCode {
            return self.keycodes[osKeyCode] ?? KeyCode.none
        }

        func osKeyCode(from key: KeyCode) -> UInt16 {
            return self.keycodesInverse[key] ?? 0
        }
    }
#endif
