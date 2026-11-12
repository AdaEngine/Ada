#if canImport(AdaWGSLCompiler) && !os(WASI) && !os(Android)
    import AdaWGSLCompiler
    import Foundation
    import Testing

    /// The shared helper modules in `Assets/Shaders/WESL` replace the GLSL `#include <AdaEngine/...>` headers.
    /// Each is linked through a tiny entry shader so a port cannot silently stop compiling.
    struct WESLLibraryModuleTests {
        struct Case: CustomTestStringConvertible, Sendable {
            let name: String
            let source: String
            var featureSets: [[String]] = [[]]

            var testDescription: String { name }
        }

        static let cases: [Case] = [
            Case(
                name: "tonemapping",
                source: """
                import ada_engine::tonemapping::{adaOutputTransform, adaDitherDisplay};
                @fragment fn main(@builtin(position) p: vec4f) -> @location(0) vec4f {
                    return vec4f(adaDitherDisplay(adaOutputTransform(p.xyz, p.w), p.xy), 1.0);
                }
                """
            ),
            Case(
                name: "color_grading",
                source: """
                import ada_engine::color_grading::{adaGradeLinear, adaApplyLut};
                @group(0) @binding(0) var gradingLUT: texture_2d<f32>;
                @group(0) @binding(1) var gradingSampler: sampler;
                @fragment fn main(@builtin(position) p: vec4f) -> @location(0) vec4f {
                    let graded = adaGradeLinear(p.xyz, p, p, p.xy);
                    return vec4f(adaApplyLut(gradingLUT, gradingSampler, graded, p.w), 1.0);
                }
                """
            ),
            Case(
                name: "shadow_pcf",
                source: """
                import ada_engine::shadow_pcf::{adaDirectionalShadowPCF, adaDirectionalShadowPCSS};
                @group(0) @binding(0) var atlasTexture: texture_2d<f32>;
                @group(0) @binding(1) var atlasSampler: sampler;
                @fragment fn main(@builtin(position) p: vec4f) -> @location(0) vec4f {
                    let a = adaDirectionalShadowPCF(atlasTexture, atlasSampler, p.xy, p.zw, p.xy, p.zw, p.x);
                    let b = adaDirectionalShadowPCSS(atlasTexture, atlasSampler, p.xy, p.zw, p.xy, p.zw, p.x, mat4x4f(), p, 2.0);
                    return vec4f(a, b, 0.0, 1.0);
                }
                """
            ),
            Case(
                name: "distance_field",
                source: """
                import ada_engine::distance_field::adaDistanceFieldVisibility;
                @fragment fn main(@builtin(position) p: vec4f) -> @location(0) vec4f {
                    return vec4f(adaDistanceFieldVisibility(p.xyz, p.xyz, p.xyz, p.w));
                }
                """
            ),
            Case(
                name: "morph",
                source: """
                @if(ADA_MORPH) import ada_engine::morph::{applyMorph, applyMorphPosition, previousMorphedPosition};
                @vertex fn main(@builtin(vertex_index) index: u32, @location(0) position: vec3f) -> @builtin(position) vec4f {
                    @if(ADA_MORPH) {
                        let morphed = applyMorph(index, position, position, position);
                        return vec4f(applyMorphPosition(index, morphed.position) + previousMorphedPosition(index, morphed.normal), 1.0);
                    }
                    return vec4f(position, 1.0);
                }
                """,
                featureSets: [[], ["ADA_MORPH"]]
            ),
            Case(
                name: "baked_diffuse",
                source: """
                import ada_engine::baked_diffuse::adaBakedDiffuse;
                @fragment fn main(@builtin(position) p: vec4f) -> @location(0) vec4f {
                    return adaBakedDiffuse(p.xyz, p.xyz, p.xy, p, p);
                }
                """,
                featureSets: [[], ["ADA_LIGHTMAP"], ["ADA_IRRADIANCE_GRID"], ["ADA_LIGHTMAP", "ADA_IRRADIANCE_GRID"]]
            ),
        ]

        private static var shaderPackage: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/AdaRender/Assets/Shaders/WESL")
        }

        private func link(_ item: Case, features: [String]) throws -> WESLHostCompiler.Artifact {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("main.wesl")
            try item.source.write(to: file, atomically: true, encoding: .utf8)
            return try WESLHostCompiler.compile(
                sourceFile: file,
                packageRoot: root,
                features: Dictionary(uniqueKeysWithValues: features.map { ($0, true) }),
                dependencies: ["ada_engine": Self.shaderPackage]
            )
        }

        @Test(arguments: cases)
        func linksAndCompilesToMetal(item: Case) throws {
            for features in item.featureSets {
                let module = try link(item, features: features)
                #expect(module.entryPoints.map(\.name) == ["main"], "features: \(features)")
                _ = try WESLBackendCompiler.compile(module, to: .msl)
            }
        }

        @Test func morphDeclaresNothingWithoutItsFeature() throws {
            let morph = try #require(Self.cases.first { $0.name == "morph" })
            #expect(!(try link(morph, features: [])).wgsl.contains("u_MorphDeltas"))
            #expect(try link(morph, features: ["ADA_MORPH"]).wgsl.contains("u_MorphDeltas"))
        }
    }
#endif
