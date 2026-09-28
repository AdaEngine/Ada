import AdaEngine
import Foundation
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

/// Stores a scene thumbnail beside project metadata, independently of the client UI.
struct EditorProjectPreviewStore: Sendable {
    let projectURL: URL

    var imageURL: URL { projectURL.appendingPathComponent(".ada/preview.png") }

    func load() -> Image? {
        try? Image(contentsOf: imageURL)
    }

    @concurrent
    func save(_ image: Image) async throws {
        try Task.checkCancellation()
        guard image.width > 0, image.height > 0, !image.data.isEmpty else { throw Failure.invalidImage }
        #if canImport(CoreGraphics) && canImport(ImageIO)
        let data = try image.pngData()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 640
              ] as CFDictionary) else { throw Failure.invalidImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.encodingFailed
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodingFailed }
        try Task.checkCancellation()
        // Do not recreate a project deleted while this frame was being encoded.
        guard FileManager.default.fileExists(atPath: projectURL.path) else { throw Failure.projectUnavailable }
        let directory = imageURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        try (output as Data).write(to: imageURL, options: .atomic)
        #else
        throw Failure.encodingFailed
        #endif
    }

    enum Failure: Error, Equatable {
        case invalidImage
        case encodingFailed
        case projectUnavailable
    }
}

/// Reads only completed GPU frames; PNG encoding and disk writes run off the main actor.
@MainActor
final class EditorProjectPreviewCapture {
    private let store: EditorProjectPreviewStore
    private var lastCaptureTime: ContinuousClock.Instant?
    private var saveTask: Task<Void, Never>?
    private var isStopped = false
    private var frameRequest: (@MainActor (Image) -> Void)?

    init(projectURL: URL) {
        store = EditorProjectPreviewStore(projectURL: projectURL)
    }

    func capture(_ texture: Texture2D) {
        guard !isStopped else { return }
        if let request = frameRequest {
            let image = Image(texture: texture)
            if !image.data.isEmpty {
                frameRequest = nil
                request(image)
            }
        }
        guard !isStopped, saveTask == nil else {
            return
        }
        let now = ContinuousClock.now
        if let lastCaptureTime, now - lastCaptureTime < .seconds(10) {
            return
        }
        lastCaptureTime = now
        let image = Image(texture: texture)
        guard !image.data.isEmpty else {
            return
        }
        saveTask = Task { [weak self, store] in
            defer { self?.saveTask = nil }
            do {
                try await store.save(image)
            } catch is CancellationError {
                return
            } catch {
                print("Unable to save project preview: \(error)")
            }
        }
    }

    /// Reads the next completed frame, independently of thumbnail throttling.
    func requestFrame(_ completion: @escaping @MainActor (Image) -> Void) {
        guard !isStopped else { return }
        frameRequest = completion
    }

    func cancelFrameRequest() {
        frameRequest = nil
    }

    func stop() {
        isStopped = true
        frameRequest = nil
        saveTask?.cancel()
        saveTask = nil
    }
}
