//
//  PerspectiveCamera.swift
//  AdaEngine
//
//  Created by v.prusakov on 2/10/23.
//

import AdaAudio
import AdaCorePipelines
import AdaECS
import AdaRender
import AdaTransform

/// A virtual camera that establishes the rendering perspective.
public typealias Camera3D = PerspectiveCameraBundle

/// A virtual camera that establishes the rendering perspective.
@Bundle
public struct PerspectiveCameraBundle {
    public var camera: Camera
    public var visibleEntities = VisibleEntities()
    public var globalViewUniform = GlobalViewUniform()
    public var audioReceiver = AudioReceiver()
    public var transform = Transform()
    public var cameraRenderGraph: CameraRenderGraph
    public var visibility: Visibility = .visible
    public var environment: Environment3D

    /// Create a new perspective camera for rendering 2D and 3D items on screen.
    public init(
        camera: Camera,
        perspectiveProjection: PerspectiveProjection = PerspectiveProjection(),
        visibleEntities: VisibleEntities = VisibleEntities(),
        globalViewUniform: GlobalViewUniform = GlobalViewUniform(),
        audioReceiver: AudioReceiver = AudioReceiver(),
        transform: Transform = Transform(),
        environment: Environment3D = Environment3D()
    ) {
        self.camera = camera
        self.camera.projection = .perspective(perspectiveProjection)
        self.visibleEntities = visibleEntities
        self.globalViewUniform = globalViewUniform
        self.audioReceiver = audioReceiver
        self.transform = transform
        self.environment = environment
        self.cameraRenderGraph = CameraRenderGraph(subgraphLabel: .main3D, inputSlot: Core3DPlugin.InputNode.view)
    }
}
