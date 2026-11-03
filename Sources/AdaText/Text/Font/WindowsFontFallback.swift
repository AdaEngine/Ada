#if os(Windows)
import Foundation

/// Reuse a small atlas for neighboring symbols instead of building a texture for every character.
enum WindowsFontFallback {
    private static let cache = Cache()
    private static let fontsDirectory = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:/Windows",
        isDirectory: true
    ).appendingPathComponent("Fonts", isDirectory: true)

    static func resource(for scalar: UnicodeScalar) -> FontResource? {
        cache.resource(for: scalar)
    }

    /// The lock protects both cached blocks and their one-time atlas generation.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var blocks: [UInt32: [FontResource]] = [:]

        func resource(for scalar: UnicodeScalar) -> FontResource? {
            lock.lock()
            defer { lock.unlock() }
            let firstCodepoint = scalar.value & ~UInt32(127)
            if let fonts = blocks[firstCodepoint] {
                return fonts.first { $0.handle.getGlyph(for: scalar.value) != nil }
            }

            // The question mark keeps atlases for unsupported blocks valid and cacheable.
            let codepoints = [UInt32(0x003F)] + Array(firstCodepoint...(firstCodepoint + 127))
            let fonts = ["seguisym.ttf", "segoeui.ttf"].compactMap { fileName -> FontResource? in
                let fontPath = fontsDirectory.appendingPathComponent(fileName)
                guard FileManager.default.fileExists(atPath: fontPath.path) else { return nil }
                return FontResource.custom(
                    fontPath: fontPath,
                    includeDefaultCharset: false,
                    additionalCodepoints: codepoints
                )
            }
            blocks[firstCodepoint] = fonts
            return fonts.first { $0.handle.getGlyph(for: scalar.value) != nil }
        }
    }
}
#endif
