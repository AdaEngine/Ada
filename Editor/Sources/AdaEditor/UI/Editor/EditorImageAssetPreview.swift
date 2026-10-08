@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorImageAssetPreview: View {
    let document: EditorAssetDocument
    private let previewImage: Image?

    @Environment(\.theme) private var theme

    init(document: EditorAssetDocument, previewImage: Image? = nil) {
        self.document = document
        self.previewImage = previewImage
    }

    var body: some View {
        let loadedImage = image
        VStack(alignment: .leading, spacing: 12) {
            header
            if let loadedImage {
                imageCanvas(loadedImage)
            } else {
                unavailableCanvas
            }
            informationPanel(loadedImage)
        }
        .padding(16)
        .background(theme.editorColors.background)
    }

    private var image: Image? {
        if let previewImage {
            return previewImage
        }
        guard let path = document.absolutePath else {
            return nil
        }
        return try? Image(contentsOf: URL(fileURLWithPath: path, isDirectory: false))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(document.title)
                    .font(.system(size: 15))
                    .foregroundColor(theme.editorColors.text)
                Text(document.assetReference ?? document.relativePath)
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.muted)
                    .lineLimit(1)
            }
            Spacer()
            Text(EditorAssetPreviewFormatting.fileType(document))
                .font(.system(size: 9))
                .foregroundColor(theme.editorColors.blue)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.blue.opacity(0.12)))
        }
    }

    private func imageCanvas(_ image: Image) -> some View {
        ZStack {
            canvasBackground
            image
                .resizable()
                .aspectRatio(Float(image.width) / Float(max(1, image.height)), contentMode: .fit)
                .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .mask(RoundedRectangleShape(cornerRadius: 8))
        .overlay {
            RoundedRectangleShape(cornerRadius: 8)
                .stroke(theme.editorColors.border.opacity(0.82), lineWidth: 1)
        }
        .accessibilityIdentifier("AdaEditor.AssetPreview.Canvas")
    }

    private var unavailableCanvas: some View {
        ZStack {
            canvasBackground
            Text(document.errorMessage ?? "Unable to load image preview.")
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .mask(RoundedRectangleShape(cornerRadius: 8))
        .overlay {
            RoundedRectangleShape(cornerRadius: 8)
                .stroke(theme.editorColors.border.opacity(0.82), lineWidth: 1)
        }
        .accessibilityIdentifier("AdaEditor.AssetPreview.Canvas")
    }

    private var canvasBackground: some View {
        let colors = theme.editorColors
        return Canvas { context, size in
            let tileSize: Float = 24
            let columnCount = max(1, Int(ceil(size.width / tileSize)))
            let rowCount = max(1, Int(ceil(size.height / tileSize)))

            context.drawRect(Rect(origin: .zero, size: size), color: colors.surface)
            for row in 0..<rowCount {
                for column in 0..<columnCount where (row + column).isMultiple(of: 2) {
                    context.drawRect(
                        Rect(
                            x: Float(column) * tileSize,
                            y: Float(row) * tileSize,
                            width: min(tileSize, size.width - Float(column) * tileSize),
                            height: min(tileSize, size.height - Float(row) * tileSize)
                        ),
                        color: colors.surfaceElevated.opacity(0.62)
                    )
                }
            }
        }
    }

    private func informationPanel(_ image: Image?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 0) {
                informationItem("Dimensions", image.map { "\($0.width) × \($0.height) px" } ?? "Unknown")
                informationDivider
                informationItem("File type", EditorAssetPreviewFormatting.fileType(document))
                informationDivider
                informationItem("Pixel format", image.map { EditorAssetPreviewFormatting.pixelFormat($0.format) } ?? "Unknown")
                informationDivider
                informationItem("File size", EditorAssetPreviewFormatting.fileSize(document.byteCount))
            }

            RectangleShape()
                .fill(theme.editorColors.border.opacity(0.62))
                .frame(height: 1)

            metadataRow("Resource", document.assetReference ?? "Not in a resource root")
            metadataRow("Path", document.relativePath)
            if let modifiedAt = document.modifiedAt {
                metadataRow("Modified", modifiedAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .padding(12)
        .background(RoundedRectangleShape(cornerRadius: 8).fill(theme.editorColors.surface))
        .overlay {
            RoundedRectangleShape(cornerRadius: 8)
                .stroke(theme.editorColors.border.opacity(0.72), lineWidth: 1)
        }
        .accessibilityIdentifier("AdaEditor.AssetPreview.Information")
    }

    private func informationItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9))
                .foregroundColor(theme.editorColors.muted)
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.text)
                .lineLimit(1)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var informationDivider: some View {
        RectangleShape()
            .fill(theme.editorColors.border.opacity(0.62))
            .frame(width: 1, height: 30)
            .padding(.horizontal, 12)
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.text)
                .lineLimit(2)
            Spacer()
        }
    }
}

enum EditorAssetPreviewFormatting {
    static func fileType(_ document: EditorAssetDocument) -> String {
        let fileExtension = document.fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return fileExtension.isEmpty ? "Image" : "\(fileExtension.uppercased()) image"
    }

    static func pixelFormat(_ format: Image.Format) -> String {
        switch format {
        case .rgba8:
            return "RGBA8"
        case .rgb8:
            return "RGB8"
        case .bgra8:
            return "BGRA8"
        case .bgra8_sRGB:
            return "BGRA8 sRGB"
        case .gray:
            return "Grayscale"
        }
    }

    static func fileSize(_ byteCount: Int64?) -> String {
        guard let byteCount else {
            return "Unknown"
        }
        return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}
