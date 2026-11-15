#if os(macOS) || os(Windows) || os(Linux)
import AdaAssets
import AdaECS
@_spi(Internal) import AdaRender
@testable import AdaScene
import AdaTransform
import AdaUtils
import Foundation
import Math
import Testing

@testable import AdaCorePipelines

/// How material extension values become shader constants; no GPU needed.
@Suite("3D material extension constants")
struct Render3DMaterialExtensionConstantTests {
    @Test func defaultsGiveTheFourPercentReflectanceAndIdentityTransforms() {
        let uniform = PBR3DUniform(material: PBRMaterial(), descriptor: VertexDescriptor())
        #expect(abs(uniform.dielectric.x - 0.04) < 0.000001 && uniform.dielectric.x == uniform.dielectric.y)
        for transform in [uniform.transform0, uniform.transform1, uniform.transform2, uniform.transform3, uniform.transform4] {
            #expect(transform.matrix == Vector4(1, 0, 0, 1) && transform.offset == .zero)
        }
        let fallback = PBR3DUniform(material: nil, descriptor: VertexDescriptor())
        #expect(abs(fallback.dielectric.x - 0.04) < 0.000001)
    }

    @Test func iorAndSpecularScaleTheDielectricReflectance() {
        let material = PBRMaterial()
        material.ior = 1
        #expect(PBR3DUniform.dielectricReflectance(material) == .zero)
        material.ior = 3
        #expect(abs(PBR3DUniform.dielectricReflectance(material).x - 0.25) < 0.000001)
        material.specularFactor = 0.5
        #expect(abs(PBR3DUniform.dielectricReflectance(material).x - 0.125) < 0.000001)
        material.specularColorFactor = Vector3(1, 0.5, 0)
        let tinted = PBR3DUniform.dielectricReflectance(material)
        #expect(tinted.x > tinted.y && tinted.y > tinted.z && tinted.z == 0)
        material.ior = 100
        material.specularFactor = 1
        material.specularColorFactor = Vector3(50, 50, 50)
        #expect(PBR3DUniform.dielectricReflectance(material).x <= 1, "The tint cannot push reflectance beyond total reflection.")
    }

    @Test func clearcoatDefaultsToOffAndClampsToTheUnitRange() {
        #expect(PBR3DUniform(material: PBRMaterial(), descriptor: VertexDescriptor()).coat == .zero)
        #expect(PBR3DUniform(material: nil, descriptor: VertexDescriptor()).coat == .zero)
        let material = PBRMaterial()
        material.clearcoatFactor = 0.6
        material.clearcoatRoughnessFactor = 0.2
        #expect(PBR3DUniform(material: material, descriptor: VertexDescriptor()).coat == Vector4(0.6, 0.2, 0, 0))
        material.clearcoatFactor = 7
        material.clearcoatRoughnessFactor = .nan
        let wild = PBR3DUniform(material: material, descriptor: VertexDescriptor()).coat
        #expect(wild.x == 1 && wild.y.isFinite)
        let plain = PBR3DUniform(material: PBRMaterial(), descriptor: VertexDescriptor())
        #expect(plain.bitPatterns != PBR3DUniform(material: material, descriptor: VertexDescriptor()).bitPatterns)
    }

    @Test func sheenAndAnisotropyDefaultToOffAndClamp() {
        let plain = PBR3DUniform(material: PBRMaterial(), descriptor: VertexDescriptor())
        #expect(plain.sheen == .zero && plain.anisotropy == .zero)
        let material = PBRMaterial()
        material.sheenColorFactor = Vector3(0.9, 0.5, 0.2)
        material.sheenRoughnessFactor = 0.4
        material.anisotropyStrength = 0.6
        material.anisotropyRotation = 1.2
        let value = PBR3DUniform(material: material, descriptor: VertexDescriptor())
        #expect(value.sheen == Vector4(0.9, 0.5, 0.2, 0.4) && value.anisotropy == Vector4(0.6, 1.2, 0, 0))
        material.sheenColorFactor = Vector3(5, .nan, -1)
        material.anisotropyStrength = .infinity
        let wild = PBR3DUniform(material: material, descriptor: VertexDescriptor())
        #expect(wild.sheen.x == 1 && wild.sheen.y.isFinite && wild.sheen.z == 0 && wild.anisotropy.x.isFinite)
        #expect(plain.bitPatterns != value.bitPatterns && value.bitPatterns != wild.bitPatterns)
    }

    @Test func shaderFeaturesFollowTheLayersInUse() {
        let material = PBRMaterial()
        #expect(material.shaderFeatures.isEmpty && material.shaderFeatures.enablingMacros.isEmpty)
        material.clearcoatFactor = 0.5
        #expect(material.shaderFeatures == [.clearcoat])
        material.sheenColorFactor = Vector3(0, 0.2, 0)
        material.anisotropyStrength = 0.3
        #expect(material.shaderFeatures == .all)
        #expect(Set(material.shaderFeatures.enablingMacros) == ["ADA_CLEARCOAT", "ADA_SHEEN", "ADA_ANISOTROPY"])
        material.clearcoatFactor = 0
        material.anisotropyStrength = 0
        #expect(material.shaderFeatures == [.sheen] && material.shaderFeatures.enablingMacros == ["ADA_SHEEN"])
        // A roughness or rotation alone does not use a layer.
        let inert = PBRMaterial()
        inert.clearcoatRoughnessFactor = 0.4
        inert.sheenRoughnessFactor = 0.4
        inert.anisotropyRotation = 1
        #expect(inert.shaderFeatures.isEmpty)
    }

    @Test func pipelineKeysSplitByFeaturesAndDefaultToThePlainShader() {
        let vertex = VertexDescriptor()
        let plain = PBR3DConfiguration(vertex: vertex, blended: false)
        #expect(plain.features.isEmpty)
        let coated = PBR3DConfiguration(vertex: vertex, blended: false, features: .clearcoat)
        #expect(plain != coated && coated == PBR3DConfiguration(vertex: vertex, blended: false, features: .clearcoat))
        #expect(Set([plain, coated, PBR3DConfiguration(vertex: vertex, blended: false, features: .all)]).count == 3)
    }

    @Test func nonFiniteValuesFallBackToDefaults() {
        let material = PBRMaterial()
        material.ior = .nan
        material.specularFactor = .infinity
        material.specularColorFactor = Vector3(.nan, 1, 1)
        let value = PBR3DUniform.dielectricReflectance(material)
        #expect(value.x.isFinite && value.y.isFinite && value.z.isFinite)
    }

    @Test func textureTransformFollowsTheGlTFMatrix() {
        let rotated = PBR3DTextureTransform(PBRTextureTransform(offset: Vector2(0.5, 0.25), rotation: .pi / 2, scale: Vector2(2, 3)))
        // uv' = [cos*sx*u + sin*sy*v, -sin*sx*u + cos*sy*v] + offset
        #expect(abs(rotated.matrix.x) < 0.00001 && abs(rotated.matrix.y - 3) < 0.00001)
        #expect(abs(rotated.matrix.z + 2) < 0.00001 && abs(rotated.matrix.w) < 0.00001)
        #expect(rotated.offset == Vector4(0.5, 0.25, 0, 0))
    }

    @Test func materialEditsChangeTheRevisionAndTheSharedBuffer() {
        let material = PBRMaterial()
        let before = material.uniformRevision
        material.textureTransforms[0] = PBRTextureTransform(scale: Vector2(2, 2))
        material.ior = 1.8
        #expect(material.uniformRevision > before)
        let plain = PBR3DUniform(material: PBRMaterial(), descriptor: VertexDescriptor())
        let edited = PBR3DUniform(material: material, descriptor: VertexDescriptor())
        #expect(plain != edited && plain.bitPatterns != edited.bitPatterns)
        #expect(plain.bitPatterns == PBR3DUniform(material: PBRMaterial(), descriptor: VertexDescriptor()).bitPatterns)
    }
}

extension Render3DGPUTests {
    /// Run alone: `ADAENGINE_GOLDEN_SAGA=1 swift test --filter Render3DGPUTests/MaterialExtensions`.
    @Suite("3D material extensions on GPU")
    @MainActor
    struct MaterialExtensions {
        private static func checker() -> Texture2D {
            var image = Image(width: 8, height: 8, color: .white)
            for y in 0..<8 {
                for x in 0..<8 where (x / 2 + y / 2) % 2 == 0 {
                    image.setPixel(in: Point(Float(x), Float(y)), color: Color(red: 0.9, green: 0.1, blue: 0.1))
                }
            }
            return Texture2D(image: image)
        }

        /// A large sphere in front of the camera, in the middle of the frame.
        private static func makeScene(polesSideways: Bool = false, _ configure: (PBRMaterial) -> Void) async throws -> (scene: Render3DGPUTests.DebugViews.Scene, material: PBRMaterial) {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            let material = PBRMaterial()
            material.baseColorFactor = [0.5, 0.5, 0.5, 1]
            material.metallicFactor = 0
            material.roughnessFactor = 0.2
            configure(material)
            scene.app.main.spawn("Probe") {
                Mesh3DComponent(mesh: Mesh.generateSphere(radius: 0.5, renderDevice: scene.device), materials: [material])
                Transform(rotation: polesSideways ? Quat(axis: Vector3(0, 0, 1), angle: .pi / 2) : .identity, position: [0, 0.5, -2.2])
            }
            return (scene, material)
        }

        private static func peakHighlight(_ image: Image) -> Color {
            var peak = Color.black
            var best: Float = 0
            for y in stride(from: 130, to: 350, by: 2) {
                for x in stride(from: 170, to: 470, by: 2) {
                    let pixel = image.getPixel(x: x, y: y)
                    let value = pixel.red + pixel.green + pixel.blue
                    if value > best {
                        best = value
                        peak = pixel
                    }
                }
            }
            return peak
        }

        /// The largest brightness a frame gained over `baseline` anywhere in the middle of the frame.
        private static func largestGain(_ image: Image, over baseline: Image) -> Float {
            var gain: Float = 0
            for y in stride(from: 130, to: 350, by: 2) {
                for x in stride(from: 170, to: 470, by: 2) {
                    let now = image.getPixel(x: x, y: y), before = baseline.getPixel(x: x, y: y)
                    gain = max(gain, (now.red + now.green + now.blue) - (before.red + before.green + before.blue))
                }
            }
            return gain
        }

        /// The largest shift toward red (red minus blue) a frame gained over `baseline` in the middle of the frame.
        private static func largestRedShift(_ image: Image, over baseline: Image) -> Float {
            var shift: Float = 0
            for y in stride(from: 130, to: 350, by: 2) {
                for x in stride(from: 170, to: 470, by: 2) {
                    let now = image.getPixel(x: x, y: y), before = baseline.getPixel(x: x, y: y)
                    shift = max(shift, (now.red - now.blue) - (before.red - before.blue))
                }
            }
            return shift
        }

        private static func matches(_ left: Image, _ right: Image) -> Bool {
            GoldenFrame.compare(left, right, tolerance: GoldenFrame.activeTolerance).passes(GoldenFrame.activeTolerance)
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func textureTransformsMoveScaleAndRotateTheTexture() async throws {
            let (scene, material) = try await Self.makeScene { $0.baseColorTexture = Self.checker() }
            let plain = try await scene.render(.none)
            material.textureTransforms[0] = PBRTextureTransform(scale: Vector2(3, 3))
            let scaled = try await scene.render(.none)
            material.textureTransforms[0] = PBRTextureTransform(offset: Vector2(0.3, 0.1))
            let shifted = try await scene.render(.none)
            material.textureTransforms[0] = PBRTextureTransform(rotation: 0.7)
            let rotated = try await scene.render(.none)
            for (name, image) in [("scale", scaled), ("offset", shifted), ("rotation", rotated)] {
                #expect(!Self.matches(plain, image), "A \\(name) transform must change how the texture appears.")
            }
            material.textureTransforms[0] = PBRTextureTransform(rotation: 2 * .pi)
            #expect(Self.matches(plain, try await scene.render(.none)), "A full turn must leave the texture where it was.")
            material.textureTransforms[0] = .identity
            #expect(Self.matches(plain, try await scene.render(.none)), "Resetting to the identity must restore the frame.")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func aHigherIORBrightensTheHighlightAndZeroSpecularRemovesIt() async throws {
            let (scene, material) = try await Self.makeScene { _ in }
            // Leave room for both highlights in the 8-bit presented frame.
            try scene.configure { $0.postProcess.exposureEV = -4 }
            let standard = Self.peakHighlight(try await scene.render(.none))
            material.ior = 3
            let strong = Self.peakHighlight(try await scene.render(.none))
            material.ior = 1.5
            material.specularFactor = 0
            let none = Self.peakHighlight(try await scene.render(.none))
            func total(_ color: Color) -> Float { color.red + color.green + color.blue }
            try #require(total(strong) < 3, "The test exposure must keep the strongest highlight below white.")
            #expect(total(strong) > total(standard), "An IOR of 3 reflects more than 1.5 (\\(total(strong)) vs \\(total(standard))).")
            #expect(total(none) < total(standard), "No specular strength must dim the highlight (\\(total(none)) vs \\(total(standard))).")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func specularColorTintsTheHighlight() async throws {
            let (scene, material) = try await Self.makeScene { $0.ior = 2.5 }
            let neutral = Self.peakHighlight(try await scene.render(.none))
            material.specularColorFactor = Vector3(1, 0, 0)
            let red = Self.peakHighlight(try await scene.render(.none))
            #expect(red.red - red.blue > neutral.red - neutral.blue, "A red specular tint must shift the highlight toward red.")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func clearcoatAddsASharpHighlightToARoughSurface() async throws {
            let (scene, material) = try await Self.makeScene { $0.baseColorFactor = [0.03, 0.03, 0.03, 1]; $0.roughnessFactor = 0.9 }
            let baseline = try await scene.render(.none)
            material.clearcoatFactor = 1
            material.clearcoatRoughnessFactor = 0.05
            let glossy = Self.largestGain(try await scene.render(.none), over: baseline)
            material.clearcoatRoughnessFactor = 0.6
            let blurred = Self.largestGain(try await scene.render(.none), over: baseline)
            #expect(glossy > 0.3, "A smooth coat must add a bright highlight to rough paint (gain \(glossy)).")
            #expect(glossy > blurred, "A rougher coat must spread and dim the highlight (\(glossy) vs \(blurred)).")
            material.clearcoatFactor = 0
            #expect(Self.matches(baseline, try await scene.render(.none)), "Turning the coat off must restore the frame.")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func clearcoatStrengthScalesTheCoatMonotonically() async throws {
            let (scene, material) = try await Self.makeScene { $0.baseColorFactor = [0.03, 0.03, 0.03, 1]; $0.roughnessFactor = 0.9; $0.clearcoatRoughnessFactor = 0.05 }
            let baseline = try await scene.render(.none)
            var gains: [Float] = []
            for strength: Float in [0.3, 0.7, 1] {
                material.clearcoatFactor = strength
                gains.append(Self.largestGain(try await scene.render(.none), over: baseline))
            }
            #expect(zip(gains, gains.dropFirst()).allSatisfy { $0 < $1 }, "The coat's highlight must grow with its strength: \(gains)")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func sheenAddsSoftLightThatGrowsWithItsColorAndTurnsOff() async throws {
            let (scene, material) = try await Self.makeScene { $0.baseColorFactor = [0.03, 0.03, 0.03, 1]; $0.roughnessFactor = 0.9 }
            let baseline = try await scene.render(.none)
            material.sheenRoughnessFactor = 0.4
            var gains: [Float] = []
            for strength: Float in [0.3, 0.7, 1] {
                material.sheenColorFactor = Vector3(strength, strength, strength)
                gains.append(Self.largestGain(try await scene.render(.none), over: baseline))
            }
            #expect(gains[0] > 0.05, "Sheen must add light (gain \(gains[0])).")
            #expect(zip(gains, gains.dropFirst()).allSatisfy { $0 < $1 }, "Sheen must grow with its color: \(gains)")
            material.sheenColorFactor = .zero
            #expect(Self.matches(baseline, try await scene.render(.none)), "Turning sheen off must restore the frame.")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func sheenColorTintsTheAddedLight() async throws {
            let (scene, material) = try await Self.makeScene { $0.baseColorFactor = [0.03, 0.03, 0.03, 1]; $0.roughnessFactor = 0.9; $0.sheenRoughnessFactor = 0.4 }
            material.sheenColorFactor = Vector3(1, 0, 0)
            let red = try await scene.render(.none)
            material.sheenColorFactor = Vector3(0, 0, 1)
            let blue = try await scene.render(.none)
            var redExcess: Float = 0
            for y in stride(from: 130, to: 350, by: 2) {
                for x in stride(from: 170, to: 470, by: 2) {
                    let a = red.getPixel(x: x, y: y), b = blue.getPixel(x: x, y: y)
                    redExcess += (a.red - a.blue) - (b.red - b.blue)
                }
            }
            #expect(redExcess > 0, "A red sheen must leave the surface redder than a blue one (\(redExcess)).")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func anisotropyStretchesTheHighlightAndRotationTurnsIt() async throws {
            let (scene, material) = try await Self.makeScene { $0.baseColorFactor = [0.03, 0.03, 0.03, 1]; $0.roughnessFactor = 0.35 }
            let round = try await scene.render(.none)
            material.anisotropyStrength = 0.8
            let stretched = try await scene.render(.none)
            material.anisotropyRotation = .pi / 2
            let turned = try await scene.render(.none)
            #expect(!Self.matches(round, stretched), "Anisotropy must change the highlight.")
            #expect(!Self.matches(stretched, turned), "Rotating the stretch direction must change the highlight.")
            material.anisotropyRotation = .pi
            #expect(Self.matches(stretched, try await scene.render(.none)), "Half a turn flips the direction and must look the same.")
            material.anisotropyStrength = 0
            material.anisotropyRotation = 0
            #expect(Self.matches(round, try await scene.render(.none)), "Zero strength must restore the round highlight.")
        }

        // MARK: Layer textures

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func layerTexturesSelectShaderFeaturesAndReachTheUniform() async throws {
            _ = try await Render3DDebugViewGPUTests.makeScene()
            let material = PBRMaterial()
            // A layer texture scales its layer's factor, so without the layer it selects nothing.
            material.layerTextures[.clearcoat] = PBRTextureBinding(texture: Self.solid(1))
            material.layerTextures[.sheenColor] = PBRTextureBinding(texture: Self.solid(1))
            #expect(material.shaderFeatures.isEmpty)
            // The specular textures belong to no layer.
            material.layerTextures[.specular] = PBRTextureBinding(texture: Self.solid(1))
            #expect(material.shaderFeatures == PBRLayerTexture.specular.feature)
            material.clearcoatFactor = 1
            #expect(material.shaderFeatures == [.clearcoat, PBRLayerTexture.clearcoat.feature, PBRLayerTexture.specular.feature])
            #expect(Set(material.shaderFeatures.enablingMacros) == ["ADA_CLEARCOAT", "ADA_CLEARCOAT_TEXTURE", "ADA_SPECULAR_TEXTURE"])
            #expect(Set(PBRLayerTexture.allCases.map(\.feature)).count == 8 && PBRLayerTexture.allCases.map(\.binding) == Array(32...39))
            #expect(Set(PBRLayerTexture.allCases.map(\.feature)).isDisjoint(with: [.clearcoat, .sheen, .anisotropy]))

            material.layerTextures[.clearcoatNormal] = PBRTextureBinding(
                texture: Self.solid(1), texCoord: 1, transform: PBRTextureTransform(offset: Vector2(0.5, 0), scale: Vector2(2, 2)), scale: 0.3
            )
            let value = PBR3DUniform(material: material, descriptor: VertexDescriptor())
            #expect(value.layerSets0 == Vector4(0, 0, 1, 0) && value.layerSets1 == .zero)
            #expect(value.layerTransform2.matrix == Vector4(2, 0, 0, 2) && value.layerTransform2.offset == Vector4(0.5, 0, 0, 0))
            #expect(value.layerTransform0.matrix == Vector4(1, 0, 0, 1))
            #expect(value.layerParameters.x == 0.3)
            let plain = PBR3DUniform(material: PBRMaterial(), descriptor: VertexDescriptor())
            #expect(plain.layerSets0 == .zero && plain.layerParameters.x == 1)
            #expect(plain.bitPatterns != value.bitPatterns)
            let revision = material.uniformRevision
            material.layerTextures[.clearcoat] = nil
            #expect(material.uniformRevision > revision, "Adding or removing a layer texture must refresh the shared uniform.")
        }

        private static func solid(_ red: Float, _ green: Float = 0, _ blue: Float = 0, _ alpha: Float = 1) -> Texture2D {
            Texture2D(image: Image(width: 1, height: 1, color: Color(red: red, green: green, blue: blue, alpha: alpha)))
        }

        /// Eight texels that are black on the left half and white on the right half.
        private static func halves() -> Texture2D {
            var image = Image(width: 8, height: 1, color: .black)
            for x in 4..<8 { image.setPixel(in: Point(Float(x), 0), color: .white) }
            return Texture2D(image: image)
        }

        private static let dark: (PBRMaterial) -> Void = { $0.baseColorFactor = [0.03, 0.03, 0.03, 1]; $0.roughnessFactor = 0.9 }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func aClearcoatTextureMasksTheCoat() async throws {
            let (scene, material) = try await Self.makeScene(Self.dark)
            let baseline = try await scene.render(.none)
            material.clearcoatFactor = 1
            material.clearcoatRoughnessFactor = 0.05
            let full = Self.largestGain(try await scene.render(.none), over: baseline)
            var gains: [Float] = []
            for mask: Float in [0, 0.4, 0.8] {
                material.layerTextures[.clearcoat] = PBRTextureBinding(texture: Self.solid(mask))
                let image = try await scene.render(.none)
                gains.append(Self.largestGain(image, over: baseline))
                if mask == 0 { #expect(Self.matches(baseline, image), "A black coat mask must leave the paint uncoated.") }
            }
            #expect(zip(gains, gains.dropFirst()).allSatisfy { $0 < $1 } && gains[2] < full, "The coat must follow its mask: \(gains) against \(full) unmasked.")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func aClearcoatRoughnessTextureSetsTheCoatRoughness() async throws {
            let (scene, material) = try await Self.makeScene(Self.dark)
            let baseline = try await scene.render(.none)
            material.clearcoatFactor = 1
            material.clearcoatRoughnessFactor = 0.05
            let glossy = Self.largestGain(try await scene.render(.none), over: baseline)
            material.clearcoatRoughnessFactor = 1
            let blurred = Self.largestGain(try await scene.render(.none), over: baseline)
            material.layerTextures[.clearcoatRoughness] = PBRTextureBinding(texture: Self.solid(0, 0.05))
            let textured = Self.largestGain(try await scene.render(.none), over: baseline)
            #expect(textured > blurred * 1.5 && abs(textured - glossy) < glossy * 0.3, "A green texel of 0.05 must act like a roughness of 0.05 (\(textured) vs \(glossy), rough \(blurred)).")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func aClearcoatNormalTextureBendsTheCoatOnly() async throws {
            let (scene, material) = try await Self.makeScene { $0.baseColorFactor = [0.2, 0.2, 0.2, 1]; $0.roughnessFactor = 0.6; $0.clearcoatFactor = 1; $0.clearcoatRoughnessFactor = 0.08 }
            let smooth = try await scene.render(.none)
            material.layerTextures[.clearcoatNormal] = PBRTextureBinding(texture: Self.solid(0.5, 0.5, 1))
            #expect(Self.matches(smooth, try await scene.render(.none)), "A flat normal map must not change the coat.")
            material.layerTextures[.clearcoatNormal] = PBRTextureBinding(texture: Self.solid(0.95, 0.5, 0.7))
            #expect(!Self.matches(smooth, try await scene.render(.none)), "A tilted normal map must move the coat's highlight.")
            material.layerTextures[.clearcoatNormal] = PBRTextureBinding(texture: Self.solid(0.95, 0.5, 0.7), scale: 0)
            #expect(Self.matches(smooth, try await scene.render(.none)), "A normal scale of zero must flatten the map.")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func sheenTexturesScaleTheirFactors() async throws {
            let (scene, material) = try await Self.makeScene(Self.dark)
            let baseline = try await scene.render(.none)
            material.sheenColorFactor = Vector3(1, 1, 1)
            material.sheenRoughnessFactor = 0.4
            let plain = Self.largestGain(try await scene.render(.none), over: baseline)
            material.layerTextures[.sheenColor] = PBRTextureBinding(texture: Self.solid(0, 0, 0))
            #expect(Self.matches(baseline, try await scene.render(.none)), "A black sheen color texture must remove the sheen.")
            material.layerTextures[.sheenColor] = PBRTextureBinding(texture: Self.solid(1, 0, 0))
            let red = try await scene.render(.none)
            #expect(Self.largestGain(red, over: baseline) > 0.05 && Self.largestGain(red, over: baseline) < plain, "A red sheen color adds less light than white (\(Self.largestGain(red, over: baseline)) vs \(plain)).")
            material.layerTextures[.sheenColor] = nil
            material.layerTextures[.sheenRoughness] = PBRTextureBinding(texture: Self.solid(0, 0, 0, 0.1))
            let tightened = try await scene.render(.none)
            material.layerTextures[.sheenRoughness] = nil
            #expect(!Self.matches(tightened, try await scene.render(.none)), "A sheen roughness texture must change the lobe.")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func anAnisotropyTextureSuppliesStrengthAndDirection() async throws {
            let (scene, material) = try await Self.makeScene { $0.baseColorFactor = [0.03, 0.03, 0.03, 1]; $0.roughnessFactor = 0.35 }
            let round = try await scene.render(.none)
            material.anisotropyStrength = 1
            let alongTangent = try await scene.render(.none)
            material.anisotropyRotation = .pi / 2
            let alongBitangent = try await scene.render(.none)
            material.anisotropyRotation = 0
            // Direction (1, 0) is the tangent itself and (0, 1) the bitangent; blue is the strength.
            material.layerTextures[.anisotropy] = PBRTextureBinding(texture: Self.solid(1, 0.5, 1))
            #expect(Self.matches(alongTangent, try await scene.render(.none)), "A texture direction of (1, 0) must equal the tangent direction.")
            material.layerTextures[.anisotropy] = PBRTextureBinding(texture: Self.solid(0.5, 1, 1))
            #expect(Self.matches(alongBitangent, try await scene.render(.none)), "A texture direction of (0, 1) must equal a quarter turn.")
            material.layerTextures[.anisotropy] = PBRTextureBinding(texture: Self.solid(1, 0.5, 0))
            #expect(Self.matches(round, try await scene.render(.none)), "A blue strength of zero must remove the anisotropy.")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func specularTexturesScaleTheDielectricReflection() async throws {
            let (scene, material) = try await Self.makeScene { $0.baseColorFactor = [0.03, 0.03, 0.03, 1]; $0.roughnessFactor = 0.2 }
            let standard = try await scene.render(.none)
            material.specularFactor = 0
            let none = try await scene.render(.none)
            material.specularFactor = 1
            material.layerTextures[.specular] = PBRTextureBinding(texture: Self.solid(1, 1, 1, 0))
            #expect(Self.matches(none, try await scene.render(.none)), "A specular texture alpha of zero must equal a specular factor of zero.")
            material.layerTextures[.specular] = PBRTextureBinding(texture: Self.solid(1, 1, 1, 1))
            #expect(Self.matches(standard, try await scene.render(.none)), "A specular texture alpha of one must change nothing.")
            material.layerTextures[.specular] = nil
            material.ior = 2.5
            let neutral = try await scene.render(.none)
            material.layerTextures[.specularColor] = PBRTextureBinding(texture: Self.solid(1, 0, 0))
            #expect(Self.largestRedShift(try await scene.render(.none), over: neutral) > 0.1, "A red specular color texture must shift the highlight toward red.")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func aLayerTextureReadsThroughItsOwnTransform() async throws {
            let (scene, material) = try await Self.makeScene(Self.dark)
            let baseline = try await scene.render(.none)
            material.clearcoatFactor = 1
            material.clearcoatRoughnessFactor = 0.05
            // Stretching the sampled range to a sliver sends every pixel to one half of the mask.
            let squeeze = Vector2(0.0001, 1)
            material.layerTextures[.clearcoat] = PBRTextureBinding(texture: Self.halves(), transform: PBRTextureTransform(offset: Vector2(0.9, 0), scale: squeeze))
            let white = Self.largestGain(try await scene.render(.none), over: baseline)
            material.layerTextures[.clearcoat] = PBRTextureBinding(texture: Self.halves(), transform: PBRTextureTransform(offset: Vector2(0.1, 0), scale: squeeze))
            let black = try await scene.render(.none)
            #expect(white > 0.3, "Sampling the white half must coat the sphere (\(white)).")
            #expect(Self.matches(baseline, black), "Sampling the black half must leave it uncoated.")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func importedLayerTexturesReachTheMaterial() async throws {
            _ = try await Render3DDebugViewGPUTests.makeScene()
            // A 1x1 PNG.
            let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
            let source = GLTFImportResult.Material(
                name: nil,
                baseColorFactor: .one,
                baseColorTextureIndex: nil,
                metallicFactor: 0,
                roughnessFactor: 0.5,
                metallicRoughnessTextureIndex: nil,
                normalTextureIndex: nil,
                clearcoatFactor: 1,
                layerTextures: GLTFImportResult.LayerTextures(
                    clearcoat: .init(index: 0),
                    clearcoatNormal: .init(index: 0, texCoord: 1, transform: .init(scale: Vector2(2, 2)), scale: 0.5),
                    specularColor: .init(index: 0)
                )
            )
            let result = GLTFImportResult(
                nodes: [], meshes: [], materials: [source],
                textures: [.init(source: 0, sampler: nil)],
                images: [.init(uri: nil, data: png, mimeType: "image/png")],
                scenes: [], defaultScene: nil
            )
            let material = try #require(ModelAsset3D.makeMaterials(result).first as? PBRMaterial)
            #expect(Set(material.layerTextures.keys) == [.clearcoat, .clearcoatNormal, .specularColor])
            let normal = try #require(material.layerTextures[.clearcoatNormal])
            #expect(normal.texCoord == 1 && normal.scale == 0.5 && normal.transform.scale == Vector2(2, 2))
            #expect(material.shaderFeatures == [.clearcoat, PBRLayerTexture.clearcoat.feature, PBRLayerTexture.clearcoatNormal.feature, PBRLayerTexture.specularColor.feature])
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func clearcoatMatchesItsGoldenFrame() async throws {
            let (scene, _) = try await Self.makeScene {
                $0.baseColorFactor = [0.55, 0.04, 0.04, 1]
                $0.metallicFactor = 0
                $0.roughnessFactor = 0.5
                $0.clearcoatFactor = 1
                $0.clearcoatRoughnessFactor = 0.04
            }
            switch try GoldenFrame.check(try await scene.render(.none), name: "pbr-sphere-clearcoat") {
            case .recorded, .matched:
                break
            case .missingReference(let actual):
                Issue.record("No golden frame for pbr-sphere-clearcoat; record with ADAENGINE_GOLDEN_RECORD=1. Actual: \(actual.path)")
            case let .mismatched(comparison, actual, difference):
                Issue.record("pbr-sphere-clearcoat differs in \(comparison.differingPixels) pixels. Actual: \(actual.path), difference: \(difference.path)")
            }
        }

        private static func expectGolden(_ image: Image, named name: String) throws {
            switch try GoldenFrame.check(image, name: name) {
            case .recorded, .matched:
                break
            case .missingReference(let actual):
                Issue.record("No golden frame for \(name); record with ADAENGINE_GOLDEN_RECORD=1. Actual: \(actual.path)")
            case let .mismatched(comparison, actual, difference):
                Issue.record("\(name) differs in \(comparison.differingPixels) pixels. Actual: \(actual.path), difference: \(difference.path)")
            }
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func sheenAndAnisotropyMatchTheirGoldenFrames() async throws {
            let (velvet, _) = try await Self.makeScene {
                $0.baseColorFactor = [0.25, 0.02, 0.05, 1]
                $0.metallicFactor = 0
                $0.roughnessFactor = 0.85
                $0.sheenColorFactor = Vector3(0.9, 0.55, 0.65)
                $0.sheenRoughnessFactor = 0.45
            }
            try Self.expectGolden(try await velvet.render(.none), named: "pbr-sphere-sheen")
            // The sphere's UV poles degenerate, which shows in a derivative-based tangent frame, so keep them at the sides.
            let (brushed, _) = try await Self.makeScene(polesSideways: true) {
                $0.baseColorFactor = [0.8, 0.8, 0.82, 1]
                $0.metallicFactor = 1
                $0.roughnessFactor = 0.35
                $0.anisotropyStrength = 0.85
            }
            try Self.expectGolden(try await brushed.render(.none), named: "pbr-sphere-anisotropy")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func defaultExtensionValuesChangeNothing() async throws {
            let (scene, material) = try await Self.makeScene { _ in }
            let baseline = try await scene.render(.none)
            material.ior = 1.5
            material.specularFactor = 1
            material.specularColorFactor = .one
            material.textureTransforms = Array(repeating: .identity, count: 5)
            #expect(Self.matches(baseline, try await scene.render(.none)))
        }
    }
}
#endif
