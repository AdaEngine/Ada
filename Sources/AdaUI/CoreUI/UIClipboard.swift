//
//  UIClipboard.swift
//  AdaEngine
//
//  Created by Codex on 19.02.2026.
//

import Foundation

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

/// Clipboard helper used by editable UI controls.
@MainActor
public enum UIClipboard {
    private static var fallbackString: String?

    #if canImport(AppKit)
        private static var fallbackPasteboardChangeCount: Int?
    #endif

    /// Returns plain text from the system clipboard if available.
    public static func getString() -> String? {
        #if canImport(AppKit)
            let pasteboard = NSPasteboard.general
            if let text = pasteboard.string(forType: .string) {
                return text
            }
            if let urls = pasteboard.readObjects(
                // NSPasteboard requires an Objective-C class object here.
                // swiftlint:disable:next legacy_objc_type
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL],
                !urls.isEmpty {
                return urls.map(\.path).joined(separator: "\n")
            }
            if let fileURLString = pasteboard.string(forType: .fileURL),
                let url = URL(string: fileURLString),
                url.isFileURL {
                return url.path
            }
            if fallbackPasteboardChangeCount == pasteboard.changeCount {
                return fallbackString
            }
            return nil
        #elseif canImport(UIKit)
            let pasteboard = UIPasteboard.general
            if let text = pasteboard.string {
                return text
            }
            if let urls = pasteboard.urls, !urls.isEmpty {
                return urls.map { $0.isFileURL ? $0.path : $0.absoluteString }.joined(separator: "\n")
            }
            return nil
        #else
            fallbackString
        #endif
    }

    /// Writes plain text to the clipboard.
    public static func setString(_ value: String) {
        #if canImport(AppKit)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
            fallbackString = value
            fallbackPasteboardChangeCount = pasteboard.changeCount
        #elseif canImport(UIKit)
            UIPasteboard.general.string = value
        #else
            fallbackString = value
        #endif
    }
}
