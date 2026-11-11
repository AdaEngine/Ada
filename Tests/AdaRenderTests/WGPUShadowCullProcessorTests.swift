#if canImport(WebGPU) && !os(WASI) && !os(Android)
    @_spi(Internal) @testable import AdaRender
    import Foundation
    import Math
    import Testing

    // Extends the Hi-Z suite so the WebGPU validation filter and serialization cover it.
    extension WGPUVisibilityProcessorTests {
        @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_WEBGPU_VISIBILITY_SMOKE"] == "1"))
        func shadowCullKeepsEveryCasterTheCPUFrustumTestKeeps() async throws {
            let device = try WebGPURenderBackend.createBackend().createLocalRenderDevice()
            let processor = try #require(device.createGPUShadowCullProcessor())
            var random = SystemRandomNumberGenerator()
            func value(_ range: ClosedRange<Float>) -> Float { Float.random(in: range, using: &random) }

            // Three parts; each caster's record holds a marker word identifying it.
            let partCount = 3
            var casters: [GPUShadowCaster] = []
            var markers: [UInt32] = []
            for part in 0..<partCount {
                for _ in 0..<40 {
                    let center = Vector3(value(-12...12), value(-12...12), value(-12...12))
                    let half = Vector3(value(0.01...2), value(0.01...2), value(0.01...2))
                    casters.append(GPUShadowCaster(
                        bounds: AABB(min: center - half, max: center + half),
                        forceVisible: casters.count % 37 == 0,
                        part: UInt32(part),
                        instance: UInt32(markers.count)
                    ))
                    markers.append(UInt32(1_000 + markers.count))
                }
            }
            var input = GPUShadowCullInput()
            input.casters = casters
            input.instanceStride = 8
            input.copiedBytes = 4
            var words: [UInt32] = []
            for marker in markers { words += [marker, 0] }
            input.instances = unsafe words.withUnsafeBytes { unsafe Array($0) }
            input.parts = []
            for part in 0..<partCount {
                let indexCount = UInt32(3 * (part + 1))
                let firstIndex = UInt32(part * 10)
                input.parts.append(IndexedIndirectArguments(indexCount: indexCount, firstIndex: firstIndex, baseVertex: Int32(part)))
            }
            input.segments = [0, 40, 80]
            input.revision = 1
            #expect(input.isValid)

            // Point-light-like perspective faces in random directions, plus an orthographic cascade.
            var matrices: [Transform3D] = []
            for _ in 0..<5 {
                let eye = Vector3(value(-5...5), value(-5...5), value(-5...5))
                let offset = Vector3(value(-1...1), value(-1...1), value(0.2...1))
                let target = eye + offset
                let projection = Transform3D.perspective(fieldOfView: .degrees(90), aspectRatio: 1, zNear: 0.05, zFar: 15)
                let look = Transform3D.lookAt(eye: eye, center: target, up: [0, 1, 0])
                matrices.append(projection * look)
            }
            matrices.append(Transform3D.orthographic(left: -6, right: 6, top: 6, bottom: -6, zNear: -20, zFar: 20))
            let views = matrices.map { GPUShadowCullView(viewProjection: $0, culls: true) } + [GPUShadowCullView(viewProjection: .identity, culls: false)]

            for firstInstance in [false, true] {
                let command = device.createCommandQueue().makeCommandBuffer()
                let output = try #require(processor.encode(on: command, input: input, views: views, firstInstance: firstInstance))
                command.commit()
                let arguments = Self.shadowWords(try await output.arguments.readData())
                let records = Self.shadowWords(try await output.instances.readData())
                for view in views.indices {
                    for part in 0..<partCount {
                        let base = (view * partCount + part) * 5
                        #expect(arguments[base] == UInt32(3 * (part + 1)))
                        #expect(arguments[base + 2] == UInt32(part * 10))
                        #expect(Int32(bitPattern: arguments[base + 3]) == Int32(part))
                        let start = view * casters.count + Int(input.segments[part])
                        #expect(arguments[base + 4] == (firstInstance ? UInt32(start) : 0))
                        let count = Int(arguments[base + 1])
                        let drawn = Set((0..<count).map { records[(start + $0) * 2] })
                        let expected = casters.indices.filter { casters[$0].part == UInt32(part) }
                        for index in expected where Self.cpuVisible(casters[index], view: views[view], matrix: view < matrices.count ? matrices[view] : nil) {
                            #expect(drawn.contains(markers[index]), "View \(view) dropped caster \(index), which the CPU test keeps")
                        }
                        #expect(drawn.count == count, "Every surviving record is written once")
                        #expect(drawn.isSubset(of: Set(expected.map { markers[$0] })), "Records stay within their part")
                    }
                }
            }
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_WEBGPU_VISIBILITY_SMOKE"] == "1"))
        func shadowCullWritesDistanceFadeAndHonorsTheViewToggle() async throws {
            let device = try WebGPURenderBackend.createBackend().createLocalRenderDevice()
            let processor = try #require(device.createGPUShadowCullProcessor())
            var input = GPUShadowCullInput()
            let distances: [Float] = [4, 8, 12]
            input.casters = distances.enumerated().map { index, distance in
                GPUShadowCaster(
                    bounds: nil,
                    forceVisible: true,
                    part: 0,
                    instance: UInt32(index),
                    position: [distance, 0, 0],
                    maximumDistance: 12,
                    fadeDistance: 8
                )
            }
            // Reconstructing this center from rounded bounds moves it onto the cutoff.
            let boundary = Float(0.1).nextUp
            input.casters.append(GPUShadowCaster(
                bounds: AABB(center: [0.1, 0, 0], halfExtents: [0.2, 0.1, 0.1]),
                forceVisible: false,
                part: 0,
                instance: 3,
                maximumDistance: boundary
            ))
            let records: [UInt32] = [1, 0, 2, 0, 3, 0, 4, 0]
            input.instances = unsafe records.withUnsafeBytes { unsafe Array($0) }
            input.instanceStride = 8
            input.copiedBytes = 8
            input.distanceFadeOffset = 4
            input.parts = [IndexedIndirectArguments(indexCount: 3)]
            input.segments = [0]
            input.revision = 1
            let views = [
                GPUShadowCullView(viewProjection: .identity, culls: false, distanceCamera: .zero),
                GPUShadowCullView(viewProjection: .identity, culls: false)
            ]
            let command = device.createCommandQueue().makeCommandBuffer()
            let output = try #require(processor.encode(on: command, input: input, views: views, firstInstance: false))
            command.commit()
            let arguments = Self.shadowWords(try await output.arguments.readData())
            let compacted = Self.shadowWords(try await output.instances.readData())
            #expect(arguments[1] == 3)
            #expect(arguments[6] == 4)
            let faded = Dictionary(uniqueKeysWithValues: (0..<Int(arguments[1])).map { index in
                (compacted[index * 2], Float(bitPattern: compacted[index * 2 + 1]))
            })
            #expect(faded == [1: 0, 2: 0.5, 4: 0])
            let unfaded = (0..<Int(arguments[6])).map { compacted[(input.casters.count + $0) * 2 + 1] }
            #expect(unfaded == [0, 0, 0, 0])
        }

        private static func shadowWords(_ data: Data) -> [UInt32] {
            data.withUnsafeBytes { raw in
                stride(from: 0, to: raw.count, by: 4).map { unsafe raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self) }
            }
        }

        /// The CPU mesh-visibility frustum test (MeshVisibilityFrustum3D), restated here because AdaRender cannot see it.
        private static func cpuVisible(_ caster: GPUShadowCaster, view: GPUShadowCullView, matrix: Transform3D?) -> Bool {
            guard view.culls != 0, caster.minimum.w == 0, let matrix else { return true }
            let bounds = AABB(min: caster.minimum.xyz, max: caster.maximum.xyz)
            let rows = (0..<4).map { matrix.row(at: $0) }
            let planes = [rows[3] + rows[0], rows[3] - rows[0], rows[3] + rows[1], rows[3] - rows[1], rows[2], rows[3] - rows[2]]
            for plane in planes {
                let radius = abs(plane.x) * bounds.halfExtents.x + abs(plane.y) * bounds.halfExtents.y + abs(plane.z) * bounds.halfExtents.z
                if plane.xyz.dot(bounds.center) + plane.w + radius < -0.0001 { return false }
            }
            return true
        }
    }
#endif
