import Foundation

#if canImport(AppKit)
    import AppKit
    import UniformTypeIdentifiers
#elseif canImport(UIKit)
    import UIKit
#endif

@MainActor
enum EditorPerformanceExport {
    static func save(_ data: Data, name: String, completion: @escaping @MainActor (String?) -> Void) {
        #if canImport(AppKit)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.allowedContentTypes = [.json]
            panel.begin { result in
                guard result == .OK, let url = panel.url else {
                    return
                }
                do {
                    try data.write(to: url, options: .atomic)
                    completion(nil)
                } catch { completion(error.localizedDescription) }
            }
        #elseif canImport(UIKit)
            let root = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first(where: \.isKeyWindow)?
                .rootViewController
            var presenter = root
            while let presented = presenter?.presentedViewController { presenter = presented }
            guard let presenter else {
                completion("No window available for export.")
                return
            }
            do {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AdaEditorPerformanceExport", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent(name)
                try data.write(to: url, options: .atomic)
                let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
                presenter.present(picker, animated: true)
                completion(nil)
            } catch { completion(error.localizedDescription) }
        #else
            completion("Trace export is unavailable on this platform.")
        #endif
    }
}
