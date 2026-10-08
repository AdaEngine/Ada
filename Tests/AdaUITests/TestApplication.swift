//
//  MockUIWindowManager.swift
//
//
//  Created by vladislav.prusakov on 12.08.2024.
//

@_spi(Internal) @testable import AdaUI
@_spi(Internal) @testable import AdaPlatform
import AdaInput
@testable import AdaRender
import Math

class TestApplication: Application {
    override init(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws {
        try super.init(argc: argc, argv: argv)
        self.windowManager = MockUIWindowManager()
    }

    convenience init() throws {
        try self.init(argc: CommandLine.argc, argv: CommandLine.unsafeArgv)
    }
}

class MockUIWindowManager: UIWindowManager {
    private var cursorShape: Input.CursorShape = .arrow
    private var mouseMode: Input.MouseMode = .visible

    override func setCursorShape(_ shape: Input.CursorShape) {
        self.cursorShape = shape
    }

    override func getCursorShape() -> Input.CursorShape {
        self.cursorShape
    }

    override func setMouseMode(_ mode: Input.MouseMode) {
        self.mouseMode = mode
    }

    override func getMouseMode() -> Input.MouseMode {
        self.mouseMode
    }
}

private final class MockSystemScreen: SystemScreen {}

private final class MockScreenManager: ScreenManager {
    private lazy var screen: Screen = Screen(systemScreen: MockSystemScreen(), screenManager: self)

    func getMainScreen() -> Screen? {
        screen
    }

    func getScreens() -> [Screen] {
        [screen]
    }

    func getScreenScale(for screen: Screen) -> Float {
        1
    }

    func getSize(for screen: Screen) -> Size {
        Size(width: 1920, height: 1080)
    }

    func getBrightness(for screen: Screen) -> Float {
        1
    }

    func makeScreen(from systemScreen: SystemScreen) -> Screen {
        Screen(systemScreen: systemScreen, screenManager: self)
    }
}

extension Application {
    @MainActor
    static func prepareForTest() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        self.shared = try TestApplication()
        UIWindowManager.setShared(self.shared.windowManager)
        Screen.screenManager = MockScreenManager()
    }
}
