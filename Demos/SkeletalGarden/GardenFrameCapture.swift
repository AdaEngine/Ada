import AdaEngine

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

        func update(from world: World) {
            views.update(from: world)
            _state.update(from: world)
            _metrics.update(from: world)
            _visibility.update(from: world)
        }

        func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
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
                state.reportedTimings = true
            }
            guard state.frame == 30 || state.frame == 50, let view = context.viewEntity else {
                return []
            }
            var target: RenderTexture?
            views.forEach { entity, value in
                if entity == view { target = value.mainTexture }
            }
            guard let target, target.pixelFormat == .bgra8 else {
                return []
            }
            let width = target.size.width
            let height = target.size.height
            let rowBytes = width * 4
            let alignedRowBytes = (rowBytes + 255) / 256 * 256
            let buffer = renderContext.device.createBuffer(label: "Garden Frame Capture", length: alignedRowBytes * height, options: .storageShared)
            let command = renderContext.commandQueue.makeCommandBuffer()
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
            blit.endBlitPass()
            await withCheckedContinuation { continuation in
                command.addCompletedHandler { continuation.resume() }
                command.commit()
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
            graph.addNodeEdge(from: AntiAliasing3DRenderNode.name, to: GardenFrameCapture.name)
            graph.addNodeEdge(from: GardenFrameCapture.name, to: RenderNodeLabel.Main3D.endPass)
            root.wrappedValue.addSubgraph(graph, name: .main3D)
        }
    }
#endif
