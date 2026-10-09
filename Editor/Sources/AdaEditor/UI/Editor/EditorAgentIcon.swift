@_spi(AdaEngine) import AdaEngine
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if os(macOS)
    import AppKit
    import CoreGraphics
#endif

struct EditorAgentIcon: View {
    let id: String
    let iconURL: URL?
    @Environment(\.theme) private var theme
    @State private var image: Image?

    var body: some View {
        Group {
            if let image {
                image
                    .resizable()
                    .renderMode(id.hasPrefix("sloppy") ? .original : .template)
                    .scaledToFit()
            } else {
                Text("\u{E322}")
                    .font(AdaEditorMaterialSymbolFont.font(size: 18))
            }
        }
        .foregroundColor(theme.editorColors.muted)
        .frame(width: 20, height: 20)
        .task {
            let loaded = await EditorAgentIconStore.shared.load(id: id, url: iconURL)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run { image = loaded }
        }
    }
}

/// Shared requests keep duplicate registry/local rows from decoding the same logo twice.
@MainActor
final class EditorAgentIconStore {
    static let shared = EditorAgentIconStore()
    private var images: [String: Image] = [:]
    private var requests: [String: Task<Image?, Never>] = [:]

    func load(id: String, url: URL?) async -> Image? {
        let key = "\(id)|\(url?.absoluteString ?? "")"
        if let image = images[key] {
            return image
        }
        if let request = requests[key] {
            return await request.value
        }
        // The store owns the request so one disappearing row cannot cancel another row's logo.
        let request = Task { () -> Image? in
            if let image = Self.bundledImage(id: id) {
                return image
            }
            guard let url, url.scheme == "https", url.user == nil, url.password == nil else {
                return nil
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      data.count <= 512_000 else {
                    return nil
                }
                try Task.checkCancellation()
                return Self.decodeIcon(data)
            } catch {
                return nil
            }
        }
        requests[key] = request
        defer { requests.removeValue(forKey: key) }
        let image = await request.value
        if let image {
            if images.count >= 256 { images.removeAll(keepingCapacity: true) }
            images[key] = image
        }
        return image
    }

    static func bundledImage(id: String) -> Image? {
        let url: URL?
        if id.hasPrefix("sloppy") {
            url = Bundle.editor.url(forResource: "sloppy_logo", withExtension: "png", subdirectory: "Assets/Icons")
        } else {
            guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }) else {
                return nil
            }
            url = Bundle.editor.url(forResource: id, withExtension: "png", subdirectory: "Assets/Icons/Agents")
        }
        return url.flatMap { try? Image(contentsOf: $0) }
    }

    /// Native SVG rasterization stays in the macOS boundary; AdaUI receives a portable alpha mask.
    static func decodeIcon(_ data: Data) -> Image? {
        guard data.count <= 512_000 else {
            return nil
        }
        #if os(macOS)
            let size = 64
            guard let native = NSImage(data: data), native.size.width > 0, native.size.height > 0,
                  native.size.width.isFinite, native.size.height.isFinite else {
                return nil
            }
            let scale = min(CGFloat(size) / native.size.width, CGFloat(size) / native.size.height)
            let width = native.size.width * scale
            let height = native.size.height * scale
            var proposedRect = CGRect(x: 0, y: 0, width: width, height: height)
            guard let source = native.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
                return nil
            }
            var pixels = Data(count: size * size * 4)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress,
                    width: size,
                    height: size,
                    bitsPerComponent: 8,
                    bytesPerRow: size * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else {
                    return false
                }
                context.interpolationQuality = .high
                context.draw(source, in: CGRect(x: (CGFloat(size) - width) / 2, y: (CGFloat(size) - height) / 2, width: width, height: height))
                // Template rendering multiplies RGB by the theme tint, so keep white RGB and the original alpha.
                let bytes = buffer.bindMemory(to: UInt8.self)
                for offset in stride(from: 0, to: bytes.count, by: 4) {
                    bytes[offset] = 255
                    bytes[offset + 1] = 255
                    bytes[offset + 2] = 255
                }
                return true
            }
            return drawn ? Image(width: size, height: size, data: pixels) : nil
        #else
            return try? Image.decode(from: data)
        #endif
    }
}
