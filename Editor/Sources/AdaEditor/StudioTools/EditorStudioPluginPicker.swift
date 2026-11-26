#if canImport(AppKit)
import AppKit
#endif
import Foundation
#if os(macOS)
import UniformTypeIdentifiers
#endif

@MainActor
enum EditorStudioPluginPicker {
    static func pick(title: String, extensions: [String]) async -> URL? {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = L10n.tr(title)
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return await panel.begin() == .OK ? panel.url : nil
        #elseif os(Windows)
        if case let .selected(urls) = await WindowsProjectFilePicker.files(title: L10n.tr(title), extensions: extensions, allowsMultipleSelection: false) {
            return urls.first
        }
        return nil
        #else
        return nil
        #endif
    }

    static func openAccess(_ url: URL) -> () -> Void {
        #if os(macOS)
        let scoped = url.startAccessingSecurityScopedResource()
        return { if scoped { url.stopAccessingSecurityScopedResource() } }
        #else
        return {}
        #endif
    }
}
