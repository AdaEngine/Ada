import AdaEngine
import Foundation

#if canImport(CoreGraphics) && canImport(ImageIO)
    import CoreGraphics
    import ImageIO
#endif

enum EditorImageAttachment {
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "heif", "gif", "tiff"]

    static func image(at url: URL) -> Image? {
        guard extensions.contains(url.pathExtension.lowercased()) else {
            return nil
        }
        if let image = try? Image(contentsOf: url) {
            return image
        }
        return thumbnail(at: url, maximum: 2048)
    }

    static func thumbnail(at url: URL, maximum: Int = 160) -> Image? {
        #if canImport(CoreGraphics) && canImport(ImageIO)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let cgImage = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: maximum,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                    ] as CFDictionary
                )
            else {
                return nil
            }
            var pixels = Data(count: cgImage.width * cgImage.height * 4)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard
                    let context = CGContext(
                        data: buffer.baseAddress,
                        width: cgImage.width,
                        height: cgImage.height,
                        bitsPerComponent: 8,
                        bytesPerRow: cgImage.width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    )
                else {
                    return false
                }
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
                return true
            }
            return drawn ? Image(width: cgImage.width, height: cgImage.height, data: pixels) : nil
        #else
            return try? Image(contentsOf: url)
        #endif
    }

    static func encodePNG(_ image: Image) throws -> Data {
        #if canImport(CoreGraphics) && canImport(ImageIO)
            return try image.pngData()
        #else
            throw CocoaError(.featureUnsupported)
        #endif
    }

    /// Model transport uses supported PNG bytes even when the user selected a different image format.
    static func pngData(at url: URL) throws -> Data {
        guard let image = image(at: url) else { throw CocoaError(.fileReadCorruptFile) }
        let normalized = max(image.width, image.height) > 2048 ? (thumbnail(at: url, maximum: 2048) ?? image) : image
        return try encodePNG(normalized)
    }
}

#if os(iOS)
    import UIKit

    @MainActor
    enum MobileEditorImagePaste {
        static func files() throws -> [URL] {
            let images = UIPasteboard.general.images ?? []
            if images.isEmpty {
                return try (UIPasteboard.general.urls ?? []).filter { $0.isFileURL && EditorImageAttachment.extensions.contains($0.pathExtension.lowercased()) }.prefix(8).map { source in
                    let accessed = source.startAccessingSecurityScopedResource()
                    defer { if accessed { source.stopAccessingSecurityScopedResource() } }
                    let data = try EditorImageAttachment.pngData(at: source)
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Pasted-\(UUID()).png")
                    try data.write(to: url, options: .atomic)
                    return url
                }
            }
            return try images.prefix(8).map { image in
                guard let data = image.pngData(), data.count <= 8 * 1024 * 1024 else {
                    throw CocoaError(.fileReadTooLarge)
                }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Pasted-\(UUID()).png")
                try data.write(to: url, options: .atomic)
                return url
            }
        }

        #if DEBUG && targetEnvironment(simulator)
            static func seedPreviewQA() throws {
                var image = Image(width: 96, height: 96, color: Color(red: 0.12, green: 0.55, blue: 0.85))
                for y in 16..<80 { for x in 16..<80 where (x / 16 + y / 16) % 2 == 0 { image.setPixel(in: [Float(x), Float(y)], color: Color(red: 1, green: 0.78, blue: 0.18)) } }
                let png = try EditorImageAttachment.encodePNG(image)
                guard let picture = UIImage(data: png) else { throw CocoaError(.fileReadCorruptFile) }
                UIPasteboard.general.image = picture
            }
        #endif
    }

    struct MobileEditorAttachmentPreviews: View {
        @Environment(\.theme) private var theme
        let urls: [URL]
        var remove: ((URL) -> Void)?

        var body: some View {
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 8) {
                    ForEach(urls, id: \.path) { url in
                        ZStack(anchor: .topTrailing) {
                            MobileEditorAttachmentThumbnail(url: url)
                            if let remove {
                                Button {
                                    remove(url)
                                } label: {
                                    Text("\u{E5CD}").font(AdaEditorMaterialSymbolFont.font(size: 16))
                                        .foregroundColor(theme.editorColors.text)
                                        .frame(width: 26, height: 26)
                                        .background(Circle().fill(theme.editorColors.surface))
                                }
                                .accessibilityIdentifier("AdaEditor.Mobile.RemoveAttachment.\(url.lastPathComponent)")
                            }
                        }
                    }
                }
            }
            .frame(height: 76)
            .accessibilityIdentifier("AdaEditor.Mobile.AttachmentPreviews")
        }
    }

    private struct MobileEditorAttachmentThumbnail: View {
        @Environment(\.theme) private var theme
        @State private var image: Image?
        let url: URL
        var body: some View {
            Group {
                if let image {
                    image.resizable().scaledToFit()
                } else {
                    Text(url.lastPathComponent).font(MobileEditorFont.font(size: 11)).lineLimit(2)
                }
            }
            .frame(width: 80, height: 72)
            .background(theme.editorColors.background)
            .mask(RoundedRectangleShape(cornerRadius: 8))
            .accessibilityIdentifier("AdaEditor.Mobile.AttachmentImage.\(url.lastPathComponent)")
            .onAppear { image = EditorImageAttachment.thumbnail(at: url) }
        }
    }
#endif
