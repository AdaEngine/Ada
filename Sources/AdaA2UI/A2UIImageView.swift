import AdaAssets
import AdaRender
import AdaUI
import AdaUIDescription
import Foundation

/// Catalog support for the A2UI `Image` component: project-relative PNG/GIF previews rendered
/// with integer nearest-neighbor zoom. GIF files animate by their embedded frame delays.
/// Paths resolve through the session's ``UISceneResources``, so previews cannot leave the project.
@MainActor
enum A2UIImageCatalog {
    /// The A2UI component name agents use in `updateComponents`.
    static let componentType = "Image"
    /// The UI document node type the component maps to.
    static let viewType = "A2UIImage"
    /// Zoom `0` (or omitted) picks the largest integer zoom that keeps the preview compact.
    static let automaticZoomTargetWidth = 256
    static let maximumZoom = 16

    /// The standard Ada catalog plus the image preview descriptor, shared by every surface.
    static let catalog: UICatalog = {
        let descriptor = UINativeViewDescriptor(
            signature: UIDescriptorSignature(
                id: viewType,
                name: viewType,
                parameters: [
                    UIParameter("path", type: .string, defaultValue: .string("")),
                    UIParameter("zoom", type: .number, defaultValue: .number(0))
                ]
            ),
            makeView: { context in
                guard let resources = context.resources else {
                    throw UIDiagnostic("Image previews require a UI resource context.")
                }
                return try makeImageView(context: context, resources: resources)
            }
        )
        guard let catalog = try? UICatalog.standard.adding(views: [descriptor]) else {
            return .standard
        }
        return catalog
    }()

    private static func makeImageView(context: UIFactoryContext, resources: UISceneResources) throws -> AnyView {
        let path = context.string("path")
        let requestedZoom = context.number("zoom")
        if path.lowercased().hasSuffix(".gif") {
            let url = try resources.resolve(path, relativeTo: context.sourceURL)
            let gif = try GIFReader().decode(Data(contentsOf: url, options: .mappedIfSafe))
            let frames = gif.rgbaFrames()
            guard let first = frames.first else {
                throw UIDiagnostic("The GIF holds no frames.")
            }
            let zoom = resolvedZoom(requestedZoom, width: first.width)
            if frames.count == 1, let image = frames.first {
                return AnyView(image.resizable().frame(width: Float(image.width * zoom), height: Float(image.height * zoom)))
            }
            let delays = gif.frames.map { max(Double($0.delayMilliseconds) / 1000, 0.02) }
            return AnyView(A2UIGIFView(frames: frames, delays: delays, zoom: zoom))
        }
        var image = try resources.image(path, relativeTo: context.sourceURL)
        image.samplerDescription.minFilter = .nearest
        image.samplerDescription.magFilter = .nearest
        let zoom = resolvedZoom(requestedZoom, width: image.width)
        return AnyView(image.resizable().frame(width: Float(image.width * zoom), height: Float(image.height * zoom)))
    }

    private static func resolvedZoom(_ requested: Double, width: Int) -> Int {
        if requested > 0 {
            return min(Int(requested), maximumZoom)
        }
        return max(1, min(maximumZoom, automaticZoomTargetWidth / max(width, 1)))
    }
}

/// Cycles predecoded GIF frames on a periodic timeline; the phase is anchored to the Unix epoch
/// so every mounted copy of the same surface advances in lockstep.
struct A2UIGIFView: View {
    let frames: [Image]
    let delays: [Double]
    let zoom: Int

    private var cycle: Double { delays.reduce(0, +) }

    var body: some View {
        TimelineView(.periodic(from: Date(timeIntervalSince1970: 0), by: 0.01)) { context in
            frame(at: context.date)
                .resizable()
                .frame(width: Float(frames[0].width * zoom), height: Float(frames[0].height * zoom))
        }
    }

    private func frame(at date: Date) -> Image {
        var time = date.timeIntervalSince1970.truncatingRemainder(dividingBy: cycle)
        if time < 0 { time += cycle }
        var elapsed = 0.0
        for (index, delay) in delays.enumerated() {
            elapsed += delay
            if time < elapsed {
                return frames[index]
            }
        }
        return frames[frames.count - 1]
    }
}
private extension GIFImage {
    /// Converts indexed frames to RGBA images with nearest filtering for crisp chat previews.
    func rgbaFrames() -> [Image] {
        frames.map { frame in
            var data = Data()
            data.reserveCapacity(width * height * 4)
            for index in frame.indices {
                let color = palette[Int(index)]
                data.append(color.red)
                data.append(color.green)
                data.append(color.blue)
                data.append(color.alpha)
            }
            var image = Image(width: width, height: height, data: data, format: .rgba8)
            image.samplerDescription.minFilter = .nearest
            image.samplerDescription.magFilter = .nearest
            return image
        }
    }
}
