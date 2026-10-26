//
//  SceneViewFrameCapture.swift
//  AdaEngine
//

@_spi(Internal) import AdaApp
import AdaECS
@_spi(Internal) import AdaInput
@_spi(Internal) import AdaRender
import AdaUtils
import Foundation

/// Failures reported when reading a completed frame from a ``SceneView``.
public enum SceneViewFrameCaptureError: Error, LocalizedError, Equatable {
    /// No ``SceneView`` registered for frame capture is alive.
    case noGameView(label: String?)
    /// The scene has not finished rendering its first frame yet.
    case noCompletedFrame
    /// The render backend could not read pixels back from the completed frame.
    case frameUnreadable
    /// The requested camera does not exist in the scene, or exists but is not active.
    case cameraUnavailable(name: String, activeCameras: [String])
    /// No new frame was completed before the deadline.
    case timeout

    public var errorDescription: String? {
        switch self {
        case let .noGameView(label):
            if let label {
                return "No running game view labelled '\(label)'. Start Play first."
            }
            return "No running game view is available for capture. Start Play first."
        case .noCompletedFrame:
            return "The game has not completed a rendered frame yet."
        case .frameUnreadable:
            return "The render backend could not read pixels from the completed game frame."
        case let .cameraUnavailable(name, activeCameras):
            let available = activeCameras.isEmpty ? "none" : activeCameras.joined(separator: ", ")
            return "Camera '\(name)' is not an active camera of the running game. Active cameras: \(available)."
        case .timeout:
            return "No new completed game frame arrived before the deadline."
        }
    }
}

/// A completed frame read back from a ``SceneView``.
public struct SceneViewCapturedFrame: Sendable {
    /// Pixels, possibly downscaled to fit the requested maximum dimension.
    public let image: Image
    /// Monotonic number of the completed frame the pixels came from.
    public let sequence: Int
    /// Width of the rendered frame before any downscaling.
    public let sourceWidth: Int
    /// Height of the rendered frame before any downscaling.
    public let sourceHeight: Int
    /// Active scene cameras whose output is composed into the frame.
    public let activeCameras: [String]
}

/// Reads finished frames of one ``SceneView`` that opted in with `frameCaptureLabel(_:)`.
///
/// The frame is the GPU result of the scene's own cameras (2D or 3D), never the
/// hosting window. Reading happens on the main actor and only touches textures that
/// are no longer a render target.
@MainActor
public final class SceneViewFrameSource {
    /// Label passed to `SceneView.frameCaptureLabel(_:)`.
    public let label: String
    weak var coordinator: SceneViewCoordinator?
    /// Replaceable in tests; headless render backends have no readable pixels.
    var pixelReader: @MainActor (Texture2D) -> Image = { Image(texture: $0) }
    var asyncPixelReader: @MainActor (Texture2D) async throws -> Image? = {
        try await unsafe RenderEngine.shared.renderDevice.readImage(from: $0)
    }

    init(label: String, coordinator: SceneViewCoordinator) {
        self.label = label
        self.coordinator = coordinator
    }

    /// Number of frames that finished rendering and became visible so far.
    public var frameSequence: Int { coordinator?.completedFrameCount ?? 0 }

    /// Names of the active cameras of the scene world.
    public var activeCameraNames: [String] { coordinator?.activeCameraNames ?? [] }

    /// The scene world the frames are rendered from.
    public var world: World? { coordinator?.appWorlds?.main }

    /// Runs inspection with the source game's runtime-service scope, including scriptable factories.
    public func withWorldExecutionContext<Result>(_ operation: (World) throws -> Result) rethrows -> Result? {
        guard let app = coordinator?.appWorlds else { return nil }
        return try app.withExecutionContext { try operation(app.main) }
    }


    /// Active cameras with their entity identifiers.
    public var activeCameras: [(id: Int, name: String)] {
        guard let world else { return [] }
        return world.getEntities()
            .filter { $0.components[Camera.self]?.isActive == true }
            .map { (id: $0.id, name: $0.name) }
            .sorted { $0.name < $1.name }
    }

    /// Delivers an input event to the scene exactly as if it came from its window.
    public func send(_ event: any InputEvent) {
        coordinator?.receiveInputEvent(event)
    }

    /// Moves the scene's pointer without producing a button event.
    public func movePointer(to position: Point) {
        coordinator?.updateMousePosition(position)
    }

    /// `true` while the owning view is alive.
    public var isAlive: Bool { coordinator != nil }

    /// Reads the latest completed frame.
    /// - Parameters:
    ///   - cameraName: Requires this camera to be active in the scene. Frames compose all active cameras.
    ///   - maxDimension: Downscales so neither side exceeds this many pixels. `nil` keeps the full size.
    public func captureFrame(cameraName: String? = nil, maxDimension: Int? = nil) throws -> SceneViewCapturedFrame {
        guard let coordinator else { throw SceneViewFrameCaptureError.noGameView(label: label) }
        let cameras = coordinator.activeCameraNames
        if let cameraName, !cameras.contains(cameraName) {
            throw SceneViewFrameCaptureError.cameraUnavailable(name: cameraName, activeCameras: cameras)
        }
        guard let texture = coordinator.completedFrameTexture else { throw SceneViewFrameCaptureError.noCompletedFrame }
        let image = pixelReader(texture)
        guard !image.data.isEmpty, image.width > 0, image.height > 0 else { throw SceneViewFrameCaptureError.frameUnreadable }
        let output = maxDimension.map { image.scaledToFit(maxDimension: $0) } ?? image
        return SceneViewCapturedFrame(
            image: output,
            sequence: coordinator.completedFrameCount,
            sourceWidth: image.width,
            sourceHeight: image.height,
            activeCameras: cameras
        )
    }

    /// Waits for a frame newer than `sequence`, then reads it, including asynchronous GPU backends.
    ///
    /// Use after sending input to observe its effect: pass ``frameSequence`` from before the input.
    public func captureFrame(
        after sequence: Int,
        cameraName: String? = nil,
        maxDimension: Int? = nil,
        timeout: Duration = .seconds(3)
    ) async throws -> SceneViewCapturedFrame {
        if let cameraName, let coordinator, !coordinator.activeCameraNames.contains(cameraName) {
            throw SceneViewFrameCaptureError.cameraUnavailable(name: cameraName, activeCameras: coordinator.activeCameraNames)
        }
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while frameSequence <= sequence {
            guard isAlive else { throw SceneViewFrameCaptureError.noGameView(label: label) }
            guard clock.now < deadline else { throw SceneViewFrameCaptureError.timeout }
            try await Task.sleep(for: .milliseconds(8))
        }
        do {
            return try captureFrame(cameraName: cameraName, maxDimension: maxDimension)
        } catch SceneViewFrameCaptureError.frameUnreadable {
            guard let coordinator, let texture = coordinator.completedFrameTexture else {
                throw SceneViewFrameCaptureError.noCompletedFrame
            }
            // Snapshot metadata before readback suspends and the next frame is published.
            let sequence = coordinator.completedFrameCount
            let cameras = coordinator.activeCameraNames
            guard let image = try await asyncPixelReader(texture),
                !image.data.isEmpty, image.width > 0, image.height > 0 else {
                throw SceneViewFrameCaptureError.frameUnreadable
            }
            return SceneViewCapturedFrame(
                image: maxDimension.map { image.scaledToFit(maxDimension: $0) } ?? image,
                sequence: sequence,
                sourceWidth: image.width,
                sourceHeight: image.height,
                activeCameras: cameras
            )
        }
    }
}

/// Lookup of the live ``SceneView``s that opted in to frame capture.
@MainActor
public enum SceneViewFrameRegistry {
    private final class WeakSource {
        weak var source: SceneViewFrameSource?
        init(_ source: SceneViewFrameSource) { self.source = source }
    }

    private static var entries: [WeakSource] = []

    /// Live sources, oldest first.
    public static var sources: [SceneViewFrameSource] {
        entries.removeAll { $0.source?.isAlive != true }
        return entries.compactMap(\.source)
    }

    /// The newest live source, optionally restricted to a label.
    public static func latest(label: String? = nil) -> SceneViewFrameSource? {
        sources.last { label == nil || $0.label == label }
    }

    static func register(_ source: SceneViewFrameSource) {
        entries.removeAll { $0.source == nil || $0.source === source }
        entries.append(WeakSource(source))
    }

    static func unregister(_ source: SceneViewFrameSource) {
        entries.removeAll { $0.source == nil || $0.source === source }
    }
}

extension Image {
    /// Nearest-neighbour downscale so neither side exceeds `maxDimension`. Never upscales.
    func scaledToFit(maxDimension: Int) -> Image {
        let limit = max(1, maxDimension)
        guard max(width, height) > limit else { return self }
        let scale = Double(limit) / Double(max(width, height))
        let newWidth = max(1, Int((Double(width) * scale).rounded()))
        let newHeight = max(1, Int((Double(height) * scale).rounded()))
        let stride: Int
        switch format {
        case .rgba8, .bgra8, .bgra8_sRGB: stride = 4
        case .rgb8: stride = 3
        case .gray: stride = 1
        }
        guard data.count >= width * height * stride else { return self }
        let source = [UInt8](data)
        var output = [UInt8](repeating: 0, count: newWidth * newHeight * stride)
        for y in 0..<newHeight {
            let sourceY = min(height - 1, y * height / newHeight)
            for x in 0..<newWidth {
                let sourceX = min(width - 1, x * width / newWidth)
                let from = (sourceY * width + sourceX) * stride
                let to = (y * newWidth + x) * stride
                for channel in 0..<stride {
                    output[to + channel] = source[from + channel]
                }
            }
        }
        return Image(width: newWidth, height: newHeight, data: Data(output), format: format)
    }
}


/// A scene that renders into offscreen textures without any window or view.
///
/// It behaves like a ``SceneView`` configured with `useSceneCameras`: the same
/// coordinator, render targets and completed-frame handling, driven by an internal
/// timer. Use it to run a game next to the editor for automated checks.
@MainActor
public final class OffscreenSceneRuntime {
    public enum Failure: Error, LocalizedError {
        case startTimeout

        public var errorDescription: String? {
            "The offscreen scene did not finish starting in time."
        }
    }

    public let frameSource: SceneViewFrameSource
    private let coordinator: SceneViewCoordinator
    private let size: SizeInt
    private var driver: Task<Void, Never>?

    public init(
        label: String,
        size: SizeInt,
        useSceneCameras: Bool,
        make: @escaping @MainActor (inout AppWorlds) -> Void
    ) {
        self.size = size
        let coordinator = SceneViewCoordinator(
            useSceneCameras: useSceneCameras,
            make: make,
            updateContent: { _, _ in },
            frameCaptureLabel: label,
            joinsHostSession: false
        )
        self.coordinator = coordinator
        // A labelled coordinator always owns a frame source.
        self.frameSource = coordinator.frameSource ?? SceneViewFrameSource(label: label, coordinator: coordinator)
    }

    /// Builds the world, allocates targets and starts ticking at roughly 60 Hz.
    public func start(timeout: Duration = .seconds(10)) async throws {
        coordinator.bootstrapIfNeeded()
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while coordinator.appWorlds == nil {
            guard clock.now < deadline else {
                stop()
                throw Failure.startTimeout
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        coordinator.updateSize(size, scaleFactor: 1)
        let coordinator = coordinator
        driver = Task { @MainActor in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                let now = ContinuousClock.now
                let delta = last.duration(to: now)
                last = now
                let seconds = Double(delta.components.seconds) + Double(delta.components.attoseconds) / 1e18
                coordinator.tick(AdaUtils.TimeInterval(min(seconds, 0.1)))
            }
        }
    }

    public func stop() {
        driver?.cancel()
        driver = nil
        coordinator.shutdown()
    }
}
