//
//  LinuxWindowManager.swift
//  AdaEngine
//
//  Created by v.prusakov on 9/2/22.
//

#if LINUX
    import X11

    final class LinuxWindowManager: WindowManager {
        override func createWindow(for _: Window) {
            fatalErrorMethodNotImplemented()
        }
    }

#endif
