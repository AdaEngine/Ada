@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorTextureSettingsInspector: View {
    let model: EditorTextureSettingsModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            adaEditorInspectorTitle(theme: theme)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    importSection
                    mipmapSection
                    samplerSection
                    previewSection
                    actions
                }
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("AdaEditor.TextureSettings")
        .task { await model.loadPreviewIfNeeded() }
    }

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            title("TEXTURE")
            selection(
                "Dimension",
                id: "Dimension",
                value: model.settings.dimension.rawValue,
                options: [("texture2D", "2D"), ("cube", "Cube · 6-face strip")]
            ) {
                if let value = TextureImportSettings.Dimension(rawValue: $0) { model.settings.dimension = value }
            }
            selection(
                "Purpose",
                id: "Purpose",
                value: model.settings.purpose.rawValue,
                options: [("color", "Color"), ("normal", "Normal"), ("data", "Data")]
            ) {
                if let value = TextureImportSettings.Purpose(rawValue: $0) {
                    model.settings.purpose = value
                    if value != .color && model.settings.colorSpace == .sRGB { model.settings.colorSpace = .linear }
                }
            }
            selection(
                "Color space",
                id: "ColorSpace",
                value: model.settings.colorSpace.rawValue,
                options: model.settings.purpose == .color
                    ? [("automatic", "Automatic · sRGB"), ("linear", "Linear"), ("sRGB", "sRGB")]
                    : [("automatic", "Automatic · Linear"), ("linear", "Linear")]
            ) {
                if let value = TextureImportSettings.ColorSpace(rawValue: $0) { model.settings.colorSpace = value }
            }
            if model.settings.dimension == .cube {
                hint("Six square faces, left to right: +X, −X, +Y, −Y, +Z, −Z. Requires a cube shader. Skybox panoramas use 2D.")
            }
        }
        .disabled(!model.isEditable || model.isApplying)
    }

    private var mipmapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            title("MIPMAPS")
            Toggle("Generate mipmaps", isOn: Binding(get: { model.settings.generateMipmaps }, set: { model.settings.generateMipmaps = $0 }))
                .accessibilityIdentifier("AdaEditor.TextureSettings.GenerateMipmaps")
            number("Level count", id: "LevelCount", value: Double(model.settings.mipLevelCount), integer: true) {
                model.settings.mipLevelCount = Int($0)
            }
            .disabled(!model.settings.generateMipmaps)
            hint("0 = full chain. Count includes level 0. Available: \(model.sourceImage.map { model.settings.maximumMipLevelCount(for: $0) } ?? 1).")
        }
        .disabled(!model.isEditable || model.isApplying)
    }

    private var samplerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            title("SAMPLER")
            selection("Min filter", id: "MinFilter", value: model.settings.sampler.minFilter.rawValue, options: filters) {
                if let value = SamplerMinMagFilter(rawValue: $0) { model.settings.sampler.minFilter = value }
            }
            selection("Mag filter", id: "MagFilter", value: model.settings.sampler.magFilter.rawValue, options: filters) {
                if let value = SamplerMinMagFilter(rawValue: $0) { model.settings.sampler.magFilter = value }
            }
            selection(
                "Mip filter",
                id: "MipFilter",
                value: model.settings.sampler.mipFilter.rawValue,
                options: [("notMipmapped", "Level 0 only")] + filters
            ) {
                if let value = SamplerMipFilter(rawValue: $0) { model.settings.sampler.mipFilter = value }
            }
            selection("Wrap U", id: "WrapU", value: model.settings.sampler.addressModeU.rawValue, options: wrapping) {
                if let value = SamplerAddressMode(rawValue: $0) { model.settings.sampler.addressModeU = value }
            }
            selection("Wrap V", id: "WrapV", value: model.settings.sampler.addressModeV.rawValue, options: wrapping) {
                if let value = SamplerAddressMode(rawValue: $0) { model.settings.sampler.addressModeV = value }
            }
            if model.settings.dimension == .cube {
                selection("Wrap W", id: "WrapW", value: model.settings.sampler.addressModeW.rawValue, options: wrapping) {
                    if let value = SamplerAddressMode(rawValue: $0) { model.settings.sampler.addressModeW = value }
                }
            }
            number("Min LOD", id: "MinLOD", value: Double(model.settings.sampler.lodMinClamp)) { model.settings.sampler.lodMinClamp = Float($0) }
            number("Max LOD", id: "MaxLOD", value: Double(model.settings.sampler.lodMaxClamp), unlimited: true) {
                model.settings.sampler.lodMaxClamp = Float($0)
            }
        }
        .disabled(!model.isEditable || model.isApplying)
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            title("PREVIEW · APPLIED SETTINGS")
            selection(
                "Mip level",
                id: "PreviewLevel",
                value: String(model.previewLevel),
                options: (0..<model.levelCount).map { (String($0), "Level \($0)") }
            ) {
                if let value = Int($0) { model.previewLevel = value }
            }
            if model.faceCount == 6 {
                selection(
                    "Cube face",
                    id: "PreviewFace",
                    value: String(model.previewFace),
                    options: ["+X", "−X", "+Y", "−Y", "+Z", "−Z"].enumerated().map { (String($0.offset), $0.element) }
                ) {
                    if let value = Int($0) { model.previewFace = value }
                }
            }
            if let image = model.previewImage { hint("\(image.width) × \(image.height) px · \(model.levelCount) level(s)") }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                actionButton(model.isApplying ? "Applying…" : "Apply", primary: true) { model.apply() }
                    .disabled(!model.isEditable || model.isApplying || !model.isDirty)
                    .accessibilityIdentifier("AdaEditor.TextureSettings.Apply")
                actionButton("Reload") { model.reload() }
                    .disabled(model.isApplying)
                    .accessibilityIdentifier("AdaEditor.TextureSettings.Reload")
            }
            if model.isDirty { hint("Unapplied changes") }
            Text(model.statusMessage)
                .font(.system(size: 11))
                .foregroundColor(model.hasError ? Color(red: 0.95, green: 0.35, blue: 0.3) : theme.editorColors.muted)
                .accessibilityIdentifier("AdaEditor.TextureSettings.Status")
        }
    }

    private func actionButton(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(primary ? theme.editorColors.blue : theme.editorColors.text)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    RoundedRectangleShape(cornerRadius: 5)
                        .fill(primary ? theme.editorColors.blue.opacity(0.12) : theme.editorColors.background)
                )
        }
        .buttonStyle(DefaultButtonStyle())
    }

    private var filters: [(String, String)] { [("nearest", "Nearest"), ("linear", "Linear")] }
    private var wrapping: [(String, String)] { [("clampToEdge", "Clamp to Edge"), ("repeat", "Repeat"), ("mirroredRepeat", "Mirrored Repeat")] }

    private func title(_ text: String) -> some View { Text(text).font(.system(size: 12)).foregroundColor(theme.editorColors.blue) }
    private func hint(_ text: String) -> some View { Text(text).font(.system(size: 10)).foregroundColor(theme.editorColors.muted) }

    private func selection(_ label: String, id: String, value: String, options: [(String, String)], set: @escaping (String) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
            Spacer()
            Text((options.first { $0.0 == value }?.1 ?? value) + " ▾")
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.text)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangleShape(cornerRadius: 4).fill(theme.editorColors.background))
                .contextMenu(opensOnPrimaryAction: true) {
                    ForEach(Array(options.indices), id: \.self) { index in
                        ContextMenuOption(options[index].1, isSelected: options[index].0 == value) { set(options[index].0) }
                    }
                }
                .accessibilityIdentifier("AdaEditor.TextureSettings.\(id)")
        }
    }

    private func number(
        _ title: String,
        id: String,
        value: Double,
        integer: Bool = false,
        unlimited: Bool = false,
        set: @escaping (Double) -> Void
    ) -> some View {
        EditorTextureNumberField(title: title, id: id, value: value, integer: integer, unlimited: unlimited, set: set)
    }
}

private struct EditorTextureNumberField: View {
    let title: String
    let id: String
    let value: Double
    let integer: Bool
    let unlimited: Bool
    let set: (Double) -> Void
    @State private var draft = ""
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
            Spacer()
            TextField(title, text: $draft)
                .font(.system(size: 11))
                .textFieldStyle(PlainTextFieldStyle())
                .padding(.horizontal, 8)
                .frame(width: 108, height: 28)
                .background(RoundedRectangleShape(cornerRadius: 4).fill(theme.editorColors.background))
                .accessibilityIdentifier("AdaEditor.TextureSettings.\(id)")
        }
        .onAppear { draft = formattedValue }
        .onChange(of: value) { _, _ in draft = formattedValue }
        .onChange(of: draft) { _, text in
            if unlimited && text.lowercased() == "unlimited" {
                set(Double(Float.greatestFiniteMagnitude))
                return
            }
            if let number = Double(text), number.isFinite, abs(number) < Double(Int.max), !integer || number.rounded() == number { set(number) }
        }
    }

    private var formattedValue: String {
        unlimited && value == Double(Float.greatestFiniteMagnitude) ? "Unlimited" : String(format: "%.6g", value)
    }
}
