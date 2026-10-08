//
//  OrthographicCamera.swift
//  AdaEngine
//
//  Created by v.prusakov on 4/5/23.
//

import AdaAudio
import AdaCorePipelines
import AdaECS
import AdaRender

/// A virtual camera that establishes the rendering orthographic.
public typealias Camera2D = OrthographicCameraBundle

/// A virtual camera that establishes the rendering orthographic.
@Bundle
public struct OrthographicCameraBundle {
    public var camera: Camera
    public var viewUniforms: GlobalViewUniform
    public var visibleEntities: VisibleEntities
    public var audioReceiver: AudioReceiver
    public var transform: Transform
    public var visibility: Visibility
    public let cameraRenderGraph: CameraRenderGraph

    /// Create a new orthograpich camera for rendering 2D and 3D items on screen.
    public init(
        camera: Camera = Camera(),
        orthographicProjection: OrthographicProjection = OrthographicProjection(),
        viewUniforms: GlobalViewUniform = GlobalViewUniform(),
        visibleEntities: VisibleEntities = VisibleEntities(),
        audioReceiver: AudioReceiver = AudioReceiver(),
        transform: Transform = Transform(),
        visibility: Visibility = .visible
    ) {
        self.camera = camera
        self.camera.projection = .orthographic(orthographicProjection)
        self.viewUniforms = viewUniforms
        self.visibleEntities = visibleEntities
        self.audioReceiver = audioReceiver
        self.transform = transform
        self.visibility = visibility
        self.cameraRenderGraph = CameraRenderGraph(
            subgraphLabel: .main2D,
            inputSlot: Main2DRenderNode.InputNode.view
        )
    }
}
