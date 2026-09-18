import Foundation

#if canImport(AppKit)
    import AppKit
#endif

@MainActor
enum EditorPlatformFileActions {
    @discardableResult
    static func copyToClipboard(_ value: String) -> Bool {
        #if canImport(AppKit)
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(value, forType: .string)
        #else
            return false
        #endif
    }

    @discardableResult
    static func reveal(_ url: URL) -> Bool {
        #if canImport(AppKit)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return true
        #else
            return false
        #endif
    }

    @discardableResult
    static func openInDefaultApplication(_ url: URL) -> Bool {
        #if canImport(AppKit)
            return NSWorkspace.shared.open(url)
        #else
            return false
        #endif
    }

    @discardableResult
    static func openInTerminal(_ url: URL) -> Bool {
        #if os(macOS)
            let directoryURL = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open", isDirectory: false)
            process.arguments = ["-a", "Terminal", directoryURL.path]
            do {
                try process.run()
                return true
            } catch {
                return false
            }
        #else
            return false
        #endif
    }
}
