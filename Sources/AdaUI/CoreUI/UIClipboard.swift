//
//  UIClipboard.swift
//  AdaEngine
//
//  Created by Codex on 19.02.2026.
//

import Foundation

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit) && !os(tvOS)
    import UIKit
#elseif os(Windows)
    import WinSDK
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
        #elseif canImport(UIKit) && !os(tvOS)
            let pasteboard = UIPasteboard.general
            if let text = pasteboard.string {
                return text
            }
            if let urls = pasteboard.urls, !urls.isEmpty {
                return urls.map { $0.isFileURL ? $0.path : $0.absoluteString }.joined(separator: "\n")
            }
            return nil
        #elseif os(Windows)
            guard OpenClipboard(GetForegroundWindow()) else { return nil }
            defer { CloseClipboard() }
            guard let handle = GetClipboardData(UINT(CF_UNICODETEXT)), let pointer = GlobalLock(handle) else { return nil }
            defer { GlobalUnlock(handle) }
            let capacity = Int(GlobalSize(handle)) / MemoryLayout<UInt16>.size
            let characters = UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt16.self), count: capacity)
            let end = characters.firstIndex(of: 0) ?? characters.endIndex
            return String(decoding: characters[..<end], as: UTF16.self)
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
        #elseif canImport(UIKit) && !os(tvOS)
            UIPasteboard.general.string = value
        #elseif os(Windows)
            let characters = Array(value.utf16) + [0]
            guard let handle = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(characters.count * MemoryLayout<UInt16>.size)) else { return }
            guard let pointer = GlobalLock(handle) else { GlobalFree(handle); return }
            characters.withUnsafeBytes { buffer in
                if let source = buffer.baseAddress { pointer.copyMemory(from: source, byteCount: buffer.count) }
            }
            GlobalUnlock(handle)
            guard OpenClipboard(GetForegroundWindow()) else { GlobalFree(handle); return }
            defer { CloseClipboard() }
            guard EmptyClipboard(), SetClipboardData(UINT(CF_UNICODETEXT), handle) != nil else { GlobalFree(handle); return }
        #else
            fallbackString = value
        #endif
    }
}
