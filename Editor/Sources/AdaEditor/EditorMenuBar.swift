//
//  EditorMenuBar.swift
//  AdaEngine
//

import AdaEngine

#if canImport(AppKit)
    import AppKit
#endif

@MainActor
enum EditorMenuCommand: CaseIterable {
    case checkForUpdates
    case showSettings
    case newFile, newProject, openProject, importAssets, save, saveAll, closeEditor
    case undo, redo, cut, copy, paste, selectAll, findInProject
    case navigateBack, navigateForward, showProjectNavigator, showInspector, showBuildOutput, showProblems, enterFullScreen
    case refreshProjectFiles, revealProject, openProjectInTerminal, showProjectSettings, showProjectDependencies, showPackageTasks
    case build, run, runTests, stop, clean, updateDependencies
    case showPreview, rebuildPreview, closeEditorTab, closeAllEditorTabs, increaseCodeFontSize, decreaseCodeFontSize, resetCodeFontSize
    case minimizeWindow, zoomWindow, bringAllToFront, showDocumentation, showSourceRepository
}

@MainActor
final class EditorMenuCommandRouter {
    static let shared = EditorMenuCommandRouter()

    private weak var owner: AnyObject?
    private var handler: ((EditorMenuCommand) -> Bool)?

    private init() {}

    func install(owner: AnyObject, handler: @escaping (EditorMenuCommand) -> Bool) {
        self.owner = owner
        self.handler = handler
    }

    func uninstall(owner: AnyObject) {
        guard self.owner === owner else {
            return
        }
        self.owner = nil
        self.handler = nil
    }

    @discardableResult
    func perform(_ command: EditorMenuCommand) -> Bool {
        if command == .checkForUpdates {
            EditorUpdateCenter.shared.checkForUpdates()
            return true
        }
        if command == .showDocumentation {
            return EditorDocumentationWindowController.open()
        }
        #if os(macOS)
            if let handled = EditorDocumentationWindowController.handleMenuCommand(command) {
                return handled
            }
        #endif
        if let editingCommand = command.textEditingCommand,
            UIWindowManager.shared?.activeWindow?.uiPerformTextEditingCommand(editingCommand) == true {
            return true
        }
        if performPlatformCommand(command) {
            return true
        }
        guard owner != nil else {
            handler = nil
            return false
        }
        return handler?(command) ?? false
    }

    private func performPlatformCommand(_ command: EditorMenuCommand) -> Bool {
        #if canImport(AppKit)
            switch command {
            case .closeEditor:
                UIWindowManager.shared?.activeWindow?.close()
            case .enterFullScreen:
                NSApp.keyWindow?.toggleFullScreen(nil)
            case .minimizeWindow:
                NSApp.keyWindow?.miniaturize(nil)
            case .zoomWindow:
                NSApp.keyWindow?.zoom(nil)
            case .bringAllToFront:
                NSApp.arrangeInFront(nil)
            case .showSourceRepository:
                guard let url = URL(string: "https://github.com/AdaEngine/AdaEngine") else {
                    return false
                }
                NSWorkspace.shared.open(url)
            default:
                return false
            }
            return true
        #else
            return false
        #endif
    }
}

extension EditorMenuCommand {
    var textEditingCommand: UITextEditingCommand? {
        switch self {
        case .undo: .undo
        case .redo: .redo
        case .cut: .cut
        case .copy: .copy
        case .paste: .paste
        case .selectAll: .selectAll
        default: nil
        }
    }
}

@MainActor
enum EditorMenuBar {
    static func makeMenus() -> [UIMenu] {
        [systemMenu(), fileMenu(), editMenu(), viewMenu(), projectMenu(), buildMenu(), codeMenu(), windowMenu(), helpMenu()]
    }

    private static func systemMenu() -> UIMenu {
        let menu = UIMenu(title: "System", placement: .application)
        menu.add(item("Settings...", command: .showSettings, key: .comma))
        if EditorDistribution.current == .standalone {
            menu.add(item("Check for Updates…", command: .checkForUpdates))
        }
        return menu
    }

    private static func fileMenu() -> UIMenu {
        menu(
            "File",
            items: [
                item("New File", command: .newFile, key: .n),
                item("New Project", command: .newProject, key: .n, modifiers: [.main, .shift]),
                item("Open Project...", command: .openProject, key: .o),
                MenuItem.separator,
                item("Import Assets...", command: .importAssets, key: .i, modifiers: [.main, .shift]),
                MenuItem.separator,
                item("Save", command: .save, key: .s),
                item("Save All", command: .saveAll, key: .s, modifiers: [.main, .alt]),
                MenuItem.separator,
                item("Close Window", command: .closeEditor, key: .w),
            ]
        )
    }

    private static func editMenu() -> UIMenu {
        menu(
            "Edit",
            items: [
                item("Undo", command: .undo, key: .z),
                item("Redo", command: .redo, key: .z, modifiers: [.main, .alt]),
                MenuItem.separator,
                item("Cut", command: .cut, key: .x),
                item("Copy", command: .copy, key: .c),
                item("Paste", command: .paste, key: .v),
                item("Select All", command: .selectAll, key: .a),
                MenuItem.separator,
                item("Find in Project", command: .findInProject, key: .f, modifiers: [.main, .shift]),
            ]
        )
    }

    private static func viewMenu() -> UIMenu {
        menu(
            "View",
            items: [
                item("Navigate Back", command: .navigateBack, key: .leftBracket),
                item("Navigate Forward", command: .navigateForward, key: .rightBracket),
                MenuItem.separator,
                item("Project Navigator", command: .showProjectNavigator, key: .num1),
                item("Inspector", command: .showInspector, key: .num2),
                item("Build Output", command: .showBuildOutput, key: .num3),
                item("Problems", command: .showProblems, key: .num4),
                MenuItem.separator,
                item("Enter Full Screen", command: .enterFullScreen, key: .f, modifiers: [.main, .control]),
            ]
        )
    }

    private static func projectMenu() -> UIMenu {
        menu(
            "Project",
            items: [
                item("Refresh Files", command: .refreshProjectFiles),
                item("Reveal Project in Finder", command: .revealProject),
                item("Open Project in Terminal", command: .openProjectInTerminal),
                MenuItem.separator,
                item("Project Settings", command: .showProjectSettings),
                item("Project Dependencies", command: .showProjectDependencies),
                item("Swift Package Tasks", command: .showPackageTasks),
                item("Update Dependencies", command: .updateDependencies),
            ]
        )
    }

    private static func buildMenu() -> UIMenu {
        menu(
            "Build",
            items: [
                item("Build Project", command: .build, key: .b),
                item("Run", command: .run, key: .r),
                item("Run Tests", command: .runTests, key: .u),
                item("Stop", command: .stop, key: .period),
                MenuItem.separator,
                item("Clean Build Artifacts", command: .clean, key: .k, modifiers: [.main, .shift]),
                item("Show Build Output", command: .showBuildOutput),
            ]
        )
    }

    private static func codeMenu() -> UIMenu {
        menu(
            "Code",
            items: [
                item("Show Preview", command: .showPreview),
                item("Rebuild Preview", command: .rebuildPreview, key: .p, modifiers: [.main, .alt]),
                MenuItem.separator,
                item("Close Editor Tab", command: .closeEditorTab, key: .w, modifiers: [.main, .shift]),
                item("Close All Editor Tabs", command: .closeAllEditorTabs, key: .w, modifiers: [.main, .alt]),
                MenuItem.separator,
                item("Increase Font Size", command: .increaseCodeFontSize, key: .plus),
                item("Decrease Font Size", command: .decreaseCodeFontSize, key: .minus),
                item("Reset Font Size", command: .resetCodeFontSize, key: .num0),
            ]
        )
    }

    private static func windowMenu() -> UIMenu {
        menu(
            "Window",
            items: [
                item("Minimize", command: .minimizeWindow, key: .m),
                item("Zoom", command: .zoomWindow),
                MenuItem.separator,
                item("Bring All to Front", command: .bringAllToFront),
            ]
        )
    }

    private static func helpMenu() -> UIMenu {
        menu(
            "Help",
            items: [
                item("Ada Documentation", command: .showDocumentation),
                item("Ada on GitHub", command: .showSourceRepository),
            ]
        )
    }

    private static func menu(_ title: String, items: [MenuItem]) -> UIMenu {
        let menu = UIMenu(title: title)
        for item in items { menu.add(item) }
        return menu
    }

    private static func item(
        _ title: String,
        command: EditorMenuCommand,
        key: KeyCode? = nil,
        modifiers: KeyModifier? = .main
    ) -> MenuItem {
        MenuItem(
            title: title,
            action: UIEventAction { EditorMenuCommandRouter.shared.perform(command) },
            keyEquivalent: key,
            keyEquivalentModifierMask: modifiers
        )
    }
}
