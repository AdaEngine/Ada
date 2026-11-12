#if canImport(AdaWGSLCompiler) && !os(WASI) && !os(Android)
    import AdaWGSLCompiler
    import Foundation
    import Testing

    /// Links every built-in shader that has a WESL source and checks its stages and uniform block layout,
    /// so a port cannot silently change entry points or the byte size the materials upload.
    struct BuiltInWESLShaderTests {
        struct Expectation: CustomTestStringConvertible, Sendable {
            let path: String
            let entryPoints: [String: String]
            /// Byte size of each group 0 uniform block the fragment reaches, by binding.
            let uniformBytes: [UInt32: UInt64]
            /// Feature sets to link; each must keep the same entry points and uniform layout.
            var featureSets: [[String]] = [[]]

            var testDescription: String { path }
        }

        /// Vertex layouts a 2D mesh can have; the canvas materials select the vertex stage from these.
        static let meshFeatureSets: [[String]] = [
            [],
            ["VERTEX_POSITIONS"],
            ["VERTEX_POSITIONS", "VERTEX_UVS"],
            ["VERTEX_POSITIONS", "VERTEX_COLORS"],
            ["VERTEX_POSITIONS", "VERTEX_NORMALS", "VERTEX_UVS", "VERTEX_COLORS"],
        ]

        /// Variants the 3D pipeline requests: surface kind, render targets, layered materials and baked lighting.
        static let flat3DFeatureSets: [[String]] = [
            [],
            ["ADA_TERRAIN"],
            ["ADA_WIREFRAME"],
            ["ADA_MORPH"],
            ["ADA_HYBRID_REFLECTION"],
            ["ADA_DIFFUSE_SURFACE"],
            ["ADA_HYBRID_REFLECTION", "ADA_DIFFUSE_SURFACE", "ADA_PATH_TRACING_SURFACE"],
            ["ADA_CLEARCOAT", "ADA_CLEARCOAT_TEXTURE", "ADA_CLEARCOAT_ROUGHNESS_TEXTURE", "ADA_CLEARCOAT_NORMAL_TEXTURE"],
            ["ADA_SHEEN", "ADA_SHEEN_COLOR_TEXTURE", "ADA_SHEEN_ROUGHNESS_TEXTURE"],
            ["ADA_ANISOTROPY", "ADA_ANISOTROPY_TEXTURE", "ADA_SPECULAR_TEXTURE", "ADA_SPECULAR_COLOR_TEXTURE"],
            ["ADA_LIGHTMAP", "ADA_IRRADIANCE_GRID"],
            ["ADA_TERRAIN", "ADA_CLEARCOAT", "ADA_ANISOTROPY", "ADA_LIGHTMAP"],
        ]

        static let expectations: [Expectation] = [
            Expectation(
                path: "Sources/AdaUI/Assets/Shaders/ui_shadow.wesl",
                entryPoints: ["ui_shadow_vertex": "vertex", "ui_shadow_fragment": "fragment"],
                uniformBytes: [0: 48]
            ),
            Expectation(
                path: "Editor/Sources/AdaEditor/Assets/Shaders/agent_activity.wesl",
                entryPoints: ["editor_agent_activity_vertex": "vertex", "editor_agent_activity_fragment": "fragment"],
                uniformBytes: [0: 48]
            ),
            Expectation(
                path: "Editor/Sources/AdaEditor/Assets/Shaders/mobile_voice_orb.wesl",
                entryPoints: ["mobile_voice_orb_vertex": "vertex", "mobile_voice_orb_fragment": "fragment"],
                uniformBytes: [0: 32]
            ),
            Expectation(
                path: "Sources/AdaCorePipelines/Assets/Shaders/glass.wesl",
                entryPoints: ["glass_vertex": "vertex", "glass_fragment": "fragment"],
                uniformBytes: [:]
            ),
            Expectation(
                path: "Sources/AdaRender/Assets/Shaders/mesh2d/mesh2d.wesl",
                entryPoints: ["mesh_vertex": "vertex", "mesh_fragment": "fragment"],
                uniformBytes: [:],
                featureSets: Self.meshFeatureSets
            ),
            Expectation(
                path: "Sources/AdaRender/Assets/Shaders/Materials/color_canvas_material.wesl",
                entryPoints: ["mesh_vertex": "vertex", "color_canvas_mesh_fragment": "fragment"],
                uniformBytes: [0: 16],
                featureSets: Self.meshFeatureSets
            ),
            Expectation(
                path: "Sources/AdaRender/Assets/Shaders/Materials/circle_canvas_material.wesl",
                entryPoints: ["mesh_vertex": "vertex", "circle_canvas_mesh_fragment": "fragment"],
                uniformBytes: [0: 32],
                featureSets: Self.meshFeatureSets
            ),
            Expectation(
                path: "Sources/AdaCorePipelines/Assets/Shaders/flat3d.wesl",
                entryPoints: ["flat3d_vertex": "vertex", "flat3d_fragment": "fragment"],
                uniformBytes: [1: 272, 15: 656],
                featureSets: Self.flat3DFeatureSets
            ),
            Expectation(
                path: "Sources/AdaCorePipelines/Assets/Shaders/path_tracing_3d.wesl",
                entryPoints: ["path_vertex": "vertex", "path_fragment": "fragment"],
                uniformBytes: [4: 400]
            ),
            Expectation(
                path: "Sources/AdaCorePipelines/Assets/Shaders/particles_3d.wesl",
                entryPoints: ["particles_vertex": "vertex", "particles_fragment": "fragment"],
                uniformBytes: [4: 624, 5: 1552],
                featureSets: [[], ["PARTICLE_INDIRECT"], ["PARTICLE_INDIRECT", "PARTICLE_REFLECTION_RESPONSE"]]
            ),
        ]

        private static var repositoryRoot: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        }

        private func link(_ expectation: Expectation, features: [String]) throws -> WESLHostCompiler.Artifact {
            let root = Self.repositoryRoot
            let source = root.appendingPathComponent(expectation.path)
            return try WESLHostCompiler.compile(
                sourceFile: source,
                packageRoot: source.deletingLastPathComponent(),
                features: Dictionary(uniqueKeysWithValues: features.map { ($0, true) }),
                dependencies: ["ada_engine": root.appendingPathComponent("Sources/AdaRender/Assets/Shaders/WESL")]
            )
        }

        @Test(arguments: expectations)
        func linksWithTheExpectedEntryPointsAndMaterialLayout(expectation: Expectation) throws {
            for features in expectation.featureSets {
                let module = try link(expectation, features: features)
                let found = Dictionary(uniqueKeysWithValues: module.entryPoints.map { ($0.name, $0.stage) })
                #expect(found == expectation.entryPoints, "features: \(features)")

                let fragment = try #require(module.entryPoints.first { $0.stage == "fragment" })
                let layouts = try WESLBackendCompiler.webGPUUniformBuffers(module, entryPoint: fragment)
                for (binding, bytes) in expectation.uniformBytes {
                    let layout = try #require(layouts.first { $0.group == 0 && $0.binding == binding }, "binding \(binding), features: \(features)")
                    #expect(layout.minimumByteSize == bytes, "binding \(binding), features: \(features)")
                }
            }
        }

        @Test func particleFeaturesControlTheExtraColorTargets() throws {
            let particles = try #require(Self.expectations.first { $0.path.hasSuffix("particles_3d.wesl") })
            let plain = try link(particles, features: []).wgsl
            let indirect = try link(particles, features: ["PARTICLE_INDIRECT"]).wgsl
            let both = try link(particles, features: ["PARTICLE_INDIRECT", "PARTICLE_REFLECTION_RESPONSE"]).wgsl
            #expect(!plain.contains("indirect") && !plain.contains("reflectionResponse"))
            #expect(indirect.contains("indirect") && !indirect.contains("reflectionResponse"))
            #expect(both.contains("indirect") && both.contains("reflectionResponse"))
        }

        @Test(arguments: expectations)
        func compilesToEveryNativeBackendStage(expectation: Expectation) throws {
            for features in expectation.featureSets {
                let module = try link(expectation, features: features)
                do {
                    let stages = try WESLBackendCompiler.compile(module, to: .msl)
                    #expect(Set(stages.map(\.stage)) == ["vertex", "fragment"], "features: \(features)")
                } catch {
                    Issue.record("features \(features): \(error)")
                }
            }
        }
    }
#endif
