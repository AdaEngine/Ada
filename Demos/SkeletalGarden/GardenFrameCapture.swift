import AdaEngine
@_spi(Internal) import AdaRender

#if os(macOS)
    struct GardenCaptureState: Resource {
        var frame = 0
        var captured = 0
        let directory: URL
        var reportedTimings = false
    }

    /// Optional demo-only readback on the same command queue as the 3D graph.
    struct GardenFrameCapture: RenderNode {
        @Query<Entity, RenderViewTarget> private var views
        @ResMut<GardenCaptureState> private var state
        @Res<Render3DPerformanceMetrics?> private var metrics
        @Res<Render3DVisibilityStatistics?> private var visibility
        @Res<Render3DTemporalStatistics?> private var temporal

        func update(from world: World) {
            views.update(from: world)
            _state.update(from: world)
            _metrics.update(from: world)
            _visibility.update(from: world)
            _temporal.update(from: world)
        }

        func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
            // Read back the window camera; additional texture cameras keep independent histories.
            guard let current = context.viewEntity,
                  let camera = current.components[Camera.self], case .window = camera.renderTarget
            else { return [] }
            state.frame += 1
            if state.frame >= 160, !state.reportedTimings, let metrics {
                let samples = metrics.samples
                let data = try JSONEncoder().encode(samples)
                try data.write(to: state.directory.appendingPathComponent("gpu-timings.json"))
                gardenLog("[SkeletalGarden] GPU timings \(String(data: data, encoding: .utf8) ?? "unavailable")")
                if let visibility {
                    let counters = try JSONEncoder().encode(visibility.snapshots)
                    try counters.write(to: state.directory.appendingPathComponent("visibility.json"))
                    gardenLog("[SkeletalGarden] visibility \(String(data: counters, encoding: .utf8) ?? "unavailable")")
                }
                if let temporal {
                    try JSONEncoder().encode(temporal.snapshots).write(to: state.directory.appendingPathComponent("temporal.json"))
                }
                state.reportedTimings = true
            }
            guard state.frame == 30 || state.frame == 50, let view = context.viewEntity else {
                return []
            }
            var target: RenderTexture?
            var motion: RenderTexture?
            views.forEach { entity, value in
                if entity == view {
                    target = value.outputTexture ?? value.mainTexture
                    motion = value.temporalMotionTexture
                }
            }
            guard let target, target.pixelFormat == .bgra8 else {
                return []
            }
            if let temporal, !temporal.snapshots.isEmpty {
                let data = try JSONEncoder().encode(temporal.snapshots)
                try data.write(to: state.directory.appendingPathComponent("temporal.json"))
                gardenLog("[SkeletalGarden] temporal \(String(data: data, encoding: .utf8) ?? "unavailable")")
            }
            let width = target.size.width
            let height = target.size.height
            let rowBytes = width * 4
            let alignedRowBytes = (rowBytes + 255) / 256 * 256
            let buffer = renderContext.device.createBuffer(label: "Garden Frame Capture", length: alignedRowBytes * height, options: .storageShared)
            let command = renderContext.commandQueue.makeCommandBuffer()
            let motionRowBytes = motion.map { ($0.size.width * 8 + 255) / 256 * 256 } ?? 0
            let motionBuffer = motion.map { renderContext.device.createBuffer(label: "Motion Readback", length: motionRowBytes * $0.size.height, options: .storageShared) }
            let blit = command.beginBlitPass(BlitPassDescriptor())
            blit.copyTextureToBuffer(
                source: target,
                sourceOrigin: Origin3D(x: 0, y: 0, z: 0),
                sourceMipLevel: 0,
                sourceSlice: 0,
                sourceSize: Size3D(width: width, height: height, depth: 1),
                destination: buffer,
                destinationOffset: 0,
                destinationBytesPerRow: alignedRowBytes,
                destinationBytesPerImage: alignedRowBytes * height
            )
            if let motion, let motionBuffer {
                blit.copyTextureToBuffer(
                    source: motion,
                    sourceOrigin: .init(x: 0, y: 0, z: 0),
                    sourceMipLevel: 0,
                    sourceSlice: 0,
                    sourceSize: .init(width: motion.size.width, height: motion.size.height, depth: 1),
                    destination: motionBuffer,
                    destinationOffset: 0,
                    destinationBytesPerRow: motionRowBytes,
                    destinationBytesPerImage: motionRowBytes * motion.size.height
                )
            }
            blit.endBlitPass()
            await withCheckedContinuation { continuation in
                command.addCompletedHandler { continuation.resume() }
                command.commit()
            }
            if let motion, let motionBuffer {
                let pointer = unsafe motionBuffer.contents()
                var movingPixels = 0, nonfinitePixels = 0
                var maximumPixels: Float = 0
                for y in 0..<motion.size.height {
                    for x in 0..<motion.size.width {
                        let pixel = unsafe pointer.advanced(by: y * motionRowBytes + x * 8)
                        let mx = Float(Float16(bitPattern: unsafe pixel.load(as: UInt16.self))) * Float(motion.size.width)
                        let my = Float(Float16(bitPattern: unsafe pixel.advanced(by: 2).load(as: UInt16.self))) * Float(motion.size.height)
                        if !mx.isFinite || !my.isFinite { nonfinitePixels += 1; continue }
                        let magnitude = max(abs(mx), abs(my))
                        if magnitude > 0.001 { movingPixels += 1 }
                        maximumPixels = max(maximumPixels, magnitude)
                    }
                }
                let summary: [String: Double] = ["movingPixels": Double(movingPixels), "nonfinitePixels": Double(nonfinitePixels), "maximumInputPixels": Double(maximumPixels)]
                try JSONEncoder().encode(summary).write(to: state.directory.appendingPathComponent("motion-\(state.frame).json"))
                gardenLog("[SkeletalGarden] motion frame=\(state.frame) moving=\(movingPixels) nonfinite=\(nonfinitePixels) maxPixels=\(maximumPixels)")
            }
            var bytes = Data()
            bytes.reserveCapacity(rowBytes * height)
            let pointer = unsafe buffer.contents()
            for row in 0 ..< height {
                bytes.append(unsafe Data(bytes: pointer.advanced(by: row * alignedRowBytes), count: rowBytes))
            }
            let image = Image(width: width, height: height, data: bytes, format: .bgra8)
            try FileManager.default.createDirectory(at: state.directory, withIntermediateDirectories: true)
            let url = state.directory.appendingPathComponent("frame-\(state.frame).png")
            try image.pngData().write(to: url)
            state.captured += 1
            gardenLog("[SkeletalGarden] captured \(url.path)")
            return []
        }
    }

    extension GardenPlugin {
        @MainActor
        func installCapture(in app: AppWorlds) {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "--capture-directory"), arguments.indices.contains(index + 1),
                  let render = app.getSubworldBuilder(by: .renderWorld)
            else { return }
            let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            render.insertResource(GardenCaptureState(directory: directory))
            let root = render.main.getRefResource(RenderGraph.self)
            guard var graph = root.wrappedValue.getSubgraph(by: .main3D) else {
                return
            }
            graph.addNode(GardenFrameCapture())
            graph.addNodeEdge(from: UpscaleNode.name, to: GardenFrameCapture.name)
            root.wrappedValue.addSubgraph(graph, name: .main3D)
        }
    }
#endif
