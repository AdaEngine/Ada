//
//  SpirvCompiler.swift
//  AdaEngine
//
//  Created by v.prusakov on 3/13/23.
//

import Foundation
import Logging
import SPIRV_Cross

/// Create High Level Shading Language from SPIR-V for specific shader language.
@safe
final class SpirvCompiler {
    let deviceLang: ShaderLanguage
    private let stage: ShaderStage

    var context: spvc_context
    var spvcCompiler: spvc_compiler
    var ir: spvc_parsed_ir

    let loggerShader = Logger(label: "SpirvCompiler")

    struct Error: LocalizedError {
        let message: String
        let file: StaticString
        let function: StaticString

        init(_ message: String, file: StaticString = #file, function: StaticString = #function) {
            self.message = message
            self.file = file
            self.function = function
        }

        var errorDescription: String? {
            return "[SpirvCompiler] \(file):\(function)" + message
        }
    }

    init(spriv: Data, stage: ShaderStage, deviceLang: ShaderLanguage) throws {
        self.stage = stage

        var context: spvc_context!
        unsafe spvc_context_create(&context)

        var ir: spvc_parsed_ir!

        let result = unsafe spriv.withUnsafeBytes { spvPtr in
            let spv = unsafe spvPtr.bindMemory(to: SpvId.self)
            return unsafe spvc_context_parse_spirv(context, spv.baseAddress, spv.count, &ir)
        }

        if result != SPVC_SUCCESS {
            throw unsafe Error(String(cString: spvc_context_get_last_error_string(context)))
        }

        unsafe self.ir = ir
        unsafe self.context = context

        self.deviceLang = deviceLang
        var spvcCompiler: spvc_compiler?
        unsafe spvc_context_create_compiler(
            context,
            deviceLang.spvcBackend,
            ir,
            SPVC_CAPTURE_MODE_TAKE_OWNERSHIP,
            &spvcCompiler
        )

        guard let spvcCompiler = unsafe spvcCompiler else {
            throw unsafe Error(String(cString: spvc_context_get_last_error_string(context)))
        }

        unsafe self.spvcCompiler = spvcCompiler
    }

    deinit {
        unsafe spvc_context_destroy(context)
    }

    /// Compile shader to device specific language
    func compile() throws -> DeviceCompiledShader {
        var spvcCompilerOptions: spvc_compiler_options?
        if unsafe spvc_compiler_create_compiler_options(spvcCompiler, &spvcCompilerOptions) != SPVC_SUCCESS {
            let errorMessage = unsafe String(cString: spvc_context_get_last_error_string(context))
            loggerShader.critical("⚠️ SPIRV-Cross compiler options creation failed: \(errorMessage)")
            throw Error(errorMessage)
        }

        unsafe Self.makeCompileOptions(spvcCompilerOptions, deviceLang: deviceLang)

        unsafe spvc_compiler_install_compiler_options(spvcCompiler, spvcCompilerOptions)

        var compilerOutputSourcePtr: UnsafePointer<CChar>?
        let result = unsafe spvc_compiler_compile(spvcCompiler, &compilerOutputSourcePtr)
        if result != SPVC_SUCCESS {
            let errorMessage = unsafe String(cString: spvc_context_get_last_error_string(context))
            loggerShader.critical("⚠️ SPIRV-Cross compilation failed: \(errorMessage)")

            // Print detailed diagnostic info
            loggerShader.critical("🔍 Target language: \(deviceLang)")
            loggerShader.critical("🔍 Shader stage: \(stage)")

            // If we have entry points, print them
            var numberOfEntryPoints: Int = 0
            var spvcEntryPoints: UnsafePointer<spvc_entry_point>?
            unsafe spvc_compiler_get_entry_points(spvcCompiler, &spvcEntryPoints, &numberOfEntryPoints)

            if numberOfEntryPoints > 0 {
                loggerShader.critical("🔍 Entry points:")
                guard let spvcEntryPoints else {
                    throw Error("SPIRV-Cross reported entry points without returning their data.")
                }
                for index in 0..<numberOfEntryPoints {
                    let entryPoint = unsafe spvcEntryPoints[index]
                    unsafe loggerShader.critical("  - \(String(cString: entryPoint.name)) (execution model: \(entryPoint.execution_model))")
                }
            } else {
                loggerShader.critical("⚠️ No entry points found in shader")
            }

            throw Error(errorMessage)
        }

        guard let compilerOutputSourcePtr else {
            throw Error("SPIRV-Cross returned no compiled shader source.")
        }
        let source = unsafe String(cString: compilerOutputSourcePtr)

        var numberOfEntryPoints: Int = 0
        var spvcEntryPoints: UnsafePointer<spvc_entry_point>?
        unsafe spvc_compiler_get_entry_points(spvcCompiler, &spvcEntryPoints, &numberOfEntryPoints)

        var entryPoints: [DeviceCompiledShader.EntryPoint] = []
        guard numberOfEntryPoints == 0 || spvcEntryPoints != nil else {
            throw Error("SPIRV-Cross reported entry points without returning their data.")
        }

        for index in 0..<numberOfEntryPoints {
            guard let spvcEntryPoints else {
                break
            }
            let entryPoint = unsafe spvcEntryPoints[index]

            guard let name = unsafe spvc_compiler_get_cleansed_entry_point_name(
                spvcCompiler, /* compiler */
                entryPoint.name, /* entry point name */
                entryPoint.execution_model /* execution model */
            ) else {
                continue
            }

            unsafe entryPoints.append(
                DeviceCompiledShader.EntryPoint(
                    name: String(cString: name),
                    stage: ShaderStage(from: entryPoint.execution_model)
                )
            )
        }

        let reflection = self.reflection()
        return DeviceCompiledShader(
            language: self.deviceLang,
            entryPoints: entryPoints,
            reflection: reflection,
            source: source
        )
    }

    // Rename default entry point.
    func renameEntryPoint(_ entryPointName: String) {
        var numberOfEntryPoints: Int = 0
        var spvcEntryPoints: UnsafePointer<spvc_entry_point>?
        unsafe spvc_compiler_get_entry_points(spvcCompiler, &spvcEntryPoints, &numberOfEntryPoints)

        for index in 0..<numberOfEntryPoints {
            guard let spvcEntryPoints else {
                return
            }
            let entryPoint = unsafe spvcEntryPoints[index]

            let result = unsafe entryPointName.withCString { entryPtr in
                unsafe spvc_compiler_rename_entry_point(
                    spvcCompiler, /* compiler */
                    entryPoint.name, /* old_name */
                    entryPtr, /* new_name */
                    entryPoint.execution_model /* excution_model */
                )
            }

            if result != SPVC_SUCCESS {
                unsafe assertionFailure("Can't set entry point \(entryPointName) for \(ShaderStage(from: entryPoint.execution_model))")
            }
        }
    }

    func reflection() -> ShaderReflectionData {
        var shaderResources: spvc_resources!
        unsafe spvc_compiler_create_shader_resources(self.spvcCompiler, &shaderResources)

        var reflectionData = ShaderReflectionData()

        for resourceType in ShaderResource.ResourceType.allCases {
            var reflectedResources: UnsafePointer<spvc_reflected_resource>!
            var reflectedResourceCount = 0

            unsafe spvc_resources_get_resource_list_for_type(shaderResources, resourceType.spvcResourceType, &reflectedResources, &reflectedResourceCount)

            for index in 0..<reflectedResourceCount {
                let resource = unsafe reflectedResources[index]
                let resourceName = unsafe String(cString: resource.name)

                let type = unsafe spvc_compiler_get_type_handle(self.spvcCompiler, resource.base_type_id)
                var size: Int = 0
                unsafe spvc_compiler_get_declared_struct_size(self.spvcCompiler, type, &size)

                let binding = unsafe spvc_compiler_get_decoration(self.spvcCompiler, resource.id, SpvDecorationBinding)
                let descriptorSetIndex = unsafe spvc_compiler_get_decoration(self.spvcCompiler, resource.id, SpvDecorationDescriptorSet)
                let isInternalResource = resourceName.hasPrefix("AE_")

                if descriptorSetIndex >= reflectionData.descriptorSets.count {
                    reflectionData.descriptorSets.append(
                        contentsOf: Array(
                            repeating: ShaderResource.DescriptorSet(),
                            count: Int(descriptorSetIndex) - reflectionData.descriptorSets.count + 1
                        )
                    )
                }

                var descriptorSet = reflectionData.descriptorSets[Int(descriptorSetIndex)]

                switch resourceType {
                case .uniformBuffer,
                    .pushConstantBuffer:
                    var members = [String: ShaderResource.ShaderBufferMember]()

                    let memberTypesCount = unsafe spvc_type_get_num_member_types(type)

                    for index in 0..<memberTypesCount {
                        let memberType = unsafe spvc_type_get_member_type(type, index)
                        let memberName = unsafe String(cString: spvc_compiler_get_member_name(self.spvcCompiler, resource.base_type_id, index))
                        var memberSize: Int = 0
                        unsafe spvc_compiler_get_declared_struct_member_size(self.spvcCompiler, type, index, &memberSize)

                        var memberOffset: UInt32 = 0
                        unsafe spvc_compiler_type_struct_member_offset(self.spvcCompiler, type, index, &memberOffset)

                        members[memberName] = unsafe ShaderResource.ShaderBufferMember(
                            name: memberName,
                            size: memberSize,
                            binding: Int(binding),
                            type: ShaderValueType(typeId: memberType, compiler: self.spvcCompiler) ?? .none,
                            offset: Int(memberOffset)
                        )
                    }

                    let buffer = ShaderResource.ShaderBuffer(
                        name: resourceName,
                        size: size,
                        shaderStage: ShaderStageFlags(shaderStage: self.stage),
                        binding: Int(binding),
                        resourceAccess: .readWrite,
                        members: members
                    )

                    descriptorSet.uniformsBuffers[Int(binding)] = buffer
                    if !isInternalResource {
                        reflectionData.shaderBuffers[resourceName] = buffer
                    }
                case .sampler:
                    let sampler = ShaderResource.Sampler(
                        name: resourceName,
                        binding: Int(binding),
                        shaderStage: ShaderStageFlags(shaderStage: self.stage)
                    )

                    if !isInternalResource {
                        reflectionData.samplers[resourceName] = sampler
                    }
                    descriptorSet.samplers[Int(binding)] = sampler
                case .image,
                    .inputAttachment,
                    .storageImage,
                    .sampledImage:
                    let access = unsafe spvc_type_get_image_access_qualifier(type)
                    let isArray = unsafe spvc_type_get_image_arrayed(type) == 1
                    let isMultisampled = unsafe spvc_type_get_image_multisampled(type) == 1
                    let dimension = unsafe spvc_type_get_image_dimension(type)
                    let arraySize = unsafe spvc_type_get_array_dimension(type, 0)

                    let resourceAccess: ShaderResource.ResourceAccess

                    if resourceType == .storageImage || access == SpvAccessQualifierReadOnly {
                        resourceAccess = .read
                    } else if access == SpvAccessQualifierWriteOnly {
                        resourceAccess = .write
                    } else {
                        resourceAccess = .readWrite
                    }

                    var textureType: Texture.TextureType = .texture2D

                    switch dimension {
                    case SpvDim1D:
                        textureType = isArray ? .texture1DArray : .texture1D
                    case SpvDim2D:
                        if isMultisampled {
                            textureType = isArray ? .texture2DMultisampleArray : .texture2DMultisample
                        } else {
                            textureType = isArray ? .texture2DArray : .texture2D
                        }
                    case SpvDim3D:
                        textureType = .texture3D
                    case SpvDimCube:
                        textureType = .textureCube
                    case SpvDimBuffer:
                        textureType = .textureBuffer
                    default:
                        break
                    }

                    let image = ShaderResource.ImageSampler(
                        name: resourceName,
                        binding: Int(binding),
                        textureType: textureType,
                        descriptorSet: Int(descriptorSetIndex),
                        arraySize: Int(arraySize),
                        shaderStage: ShaderStageFlags(shaderStage: self.stage),
                        resourceAccess: resourceAccess
                    )

                    if !isInternalResource {
                        reflectionData.resources[resourceName] = image
                    }
                    descriptorSet.sampledImages[Int(binding)] = image
                default:
                    continue
                }

                reflectionData.descriptorSets[Int(descriptorSetIndex)] = descriptorSet
            }
        }

        return reflectionData
    }
}

extension SpirvCompiler {
    static func makeCompileOptions(_ options: spvc_compiler_options?, deviceLang: ShaderLanguage) {
        let version = { (major: UInt32, minor: UInt32, patch: UInt32) in
            return (major * 10000) + (minor * 100) + patch
        }

        if deviceLang == .msl {
            unsafe spvc_compiler_options_set_uint(options, SPVC_COMPILER_OPTION_MSL_VERSION, version(2, 1, 0))
            unsafe spvc_compiler_options_set_bool(options, SPVC_COMPILER_OPTION_MSL_ENABLE_POINT_SIZE_BUILTIN, 1)

            #if os(macOS)
                let platform = SPVC_MSL_PLATFORM_MACOS
            #else
                let platform = SPVC_MSL_PLATFORM_IOS
            #endif

            unsafe spvc_compiler_options_set_uint(options, SPVC_COMPILER_OPTION_MSL_PLATFORM, UInt32(platform.rawValue))
            unsafe spvc_compiler_options_set_bool(options, SPVC_COMPILER_OPTION_MSL_ENABLE_DECORATION_BINDING, 1)
        }

        if deviceLang == .glsl {
            // Set GLSL version to 4.10, matching our OpenGL context
            unsafe spvc_compiler_options_set_uint(options, SPVC_COMPILER_OPTION_GLSL_VERSION, 410)

            // Enable GLSL specific options for better compatibility
            unsafe spvc_compiler_options_set_bool(options, SPVC_COMPILER_OPTION_GLSL_SEPARATE_SHADER_OBJECTS, 1)
            unsafe spvc_compiler_options_set_bool(options, SPVC_COMPILER_OPTION_GLSL_ENABLE_420PACK_EXTENSION, 1)
            unsafe spvc_compiler_options_set_bool(options, SPVC_COMPILER_OPTION_GLSL_ES, 0)  // Use desktop GLSL, not GLSL ES
        }
    }
}

extension ShaderLanguage {
    var spvcBackend: spvc_backend {
        switch self {
        case .msl:
            return SPVC_BACKEND_MSL
        case .hlsl:
            return SPVC_BACKEND_HLSL
        case .glsl:
            return SPVC_BACKEND_GLSL
        default:
            return SPVC_BACKEND_NONE
        }
    }
}
