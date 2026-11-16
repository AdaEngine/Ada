#include "ada_ngx.h"

#include <vulkan/vulkan.h>

#include "nvsdk_ngx_vk.h"
#include "nvsdk_ngx_helpers_vk.h"
#include "nvsdk_ngx_helpers_dlssd_vk.h"

#include <cstdio>
#include <cstdlib>

namespace {
NVSDK_NGX_Parameter *g_parameters = nullptr;

// ADAENGINE_NGX_LOG names a file that receives the NGX log lines.
void NVSDK_CONV logCallback(const char *message, NVSDK_NGX_Logging_Level, NVSDK_NGX_Feature) {
    const char *path = std::getenv("ADAENGINE_NGX_LOG");
    if (!path) return;
    if (FILE *file = std::fopen(path, "a")) {
        std::fputs(message, file);
        std::fclose(file);
    }
}

NVSDK_NGX_Resource_VK resource(const AdaNGXImage &image, bool readWrite) {
    VkImageSubresourceRange range{image.aspect, 0, 1, 0, 1};
    return NVSDK_NGX_Create_ImageView_Resource_VK(
        reinterpret_cast<VkImageView>(image.view), reinterpret_cast<VkImage>(image.image), range,
        static_cast<VkFormat>(image.format), image.width, image.height, readWrite);
}
}  // namespace

ADA_NGX_API uint32_t ada_ngx_abi_version(void) { return ADA_NGX_ABI_VERSION; }

ADA_NGX_API int32_t ada_ngx_required_extensions(uint32_t *instanceCount, const char ***instanceNames, uint32_t *deviceCount, const char ***deviceNames) {
    return NVSDK_NGX_VULKAN_RequiredExtensions(instanceCount, instanceNames, deviceCount, deviceNames);
}

ADA_NGX_API int32_t ada_ngx_init(uint64_t instance, uint64_t physicalDevice, uint64_t device, void *getInstanceProcAddr, void *getDeviceProcAddr, const wchar_t *dataPath, const wchar_t *featurePath) {
    // The NGX library (nvngx_dlss.dll) is searched in the application folder and then in featurePath.
    const wchar_t *paths[1] = {featurePath};
    NVSDK_NGX_FeatureCommonInfo info{};
    if (std::getenv("ADAENGINE_NGX_LOG")) {
        info.LoggingInfo.LoggingCallback = logCallback;
        info.LoggingInfo.MinimumLoggingLevel = NVSDK_NGX_LOGGING_LEVEL_ON;
    }
    if (featurePath) {
        info.PathListInfo.Path = paths;
        info.PathListInfo.Length = 1;
    }
    NVSDK_NGX_Result result = NVSDK_NGX_VULKAN_Init_with_ProjectID(
        "7c1e5a92-3f84-4d6b-a2c7-91e0b5d83f46", NVSDK_NGX_ENGINE_TYPE_CUSTOM, "1.0", dataPath,
        reinterpret_cast<VkInstance>(instance), reinterpret_cast<VkPhysicalDevice>(physicalDevice), reinterpret_cast<VkDevice>(device),
        reinterpret_cast<PFN_vkGetInstanceProcAddr>(getInstanceProcAddr), reinterpret_cast<PFN_vkGetDeviceProcAddr>(getDeviceProcAddr), &info);
    if (NVSDK_NGX_FAILED(result)) return result;
    return NVSDK_NGX_VULKAN_GetCapabilityParameters(&g_parameters);
}

ADA_NGX_API int32_t ada_ngx_dlss_supported(void) {
    if (!g_parameters) return 0;
    int available = 0;
    NVSDK_NGX_Result result = g_parameters->Get(NVSDK_NGX_Parameter_SuperSampling_Available, &available);
    return NVSDK_NGX_SUCCEED(result) && available ? 1 : 0;
}

ADA_NGX_API void ada_ngx_shutdown(uint64_t device) {
    if (g_parameters) {
        NVSDK_NGX_VULKAN_DestroyParameters(g_parameters);
        g_parameters = nullptr;
    }
    NVSDK_NGX_VULKAN_Shutdown1(reinterpret_cast<VkDevice>(device));
}

ADA_NGX_API int32_t ada_ngx_dlss_create(uint64_t device, uint64_t commandBuffer, const AdaNGXDLSSDescription *description, void **handle) {
    NVSDK_NGX_Parameter *parameters = nullptr;
    NVSDK_NGX_Result result = NVSDK_NGX_VULKAN_AllocateParameters(&parameters);
    if (NVSDK_NGX_FAILED(result)) return result;
    NVSDK_NGX_DLSS_Create_Params create{};
    create.Feature.InWidth = description->inputWidth;
    create.Feature.InHeight = description->inputHeight;
    create.Feature.InTargetWidth = description->outputWidth;
    create.Feature.InTargetHeight = description->outputHeight;
    create.Feature.InPerfQualityValue = static_cast<NVSDK_NGX_PerfQuality_Value>(description->quality);
    int flags = 0;
    if (description->flags & 1) flags |= NVSDK_NGX_DLSS_Feature_Flags_IsHDR;
    if (description->flags & 2) flags |= NVSDK_NGX_DLSS_Feature_Flags_MVLowRes;
    if (description->flags & 4) flags |= NVSDK_NGX_DLSS_Feature_Flags_DepthInverted;
    create.InFeatureCreateFlags = flags;
    NVSDK_NGX_Handle *feature = nullptr;
    result = NGX_VULKAN_CREATE_DLSS_EXT1(reinterpret_cast<VkDevice>(device), reinterpret_cast<VkCommandBuffer>(commandBuffer), 1, 1, &feature, parameters, &create);
    NVSDK_NGX_VULKAN_DestroyParameters(parameters);
    if (NVSDK_NGX_SUCCEED(result)) *handle = feature;
    return result;
}

ADA_NGX_API int32_t ada_ngx_dlss_evaluate(uint64_t commandBuffer, void *handle, const AdaNGXDLSSFrame *frame) {
    NVSDK_NGX_Parameter *parameters = nullptr;
    NVSDK_NGX_Result result = NVSDK_NGX_VULKAN_AllocateParameters(&parameters);
    if (NVSDK_NGX_FAILED(result)) return result;
    NVSDK_NGX_Resource_VK color = resource(frame->color, false);
    NVSDK_NGX_Resource_VK depth = resource(frame->depth, false);
    NVSDK_NGX_Resource_VK motion = resource(frame->motion, false);
    NVSDK_NGX_Resource_VK output = resource(frame->output, true);
    NVSDK_NGX_VK_DLSS_Eval_Params eval{};
    eval.Feature.pInColor = &color;
    eval.Feature.pInOutput = &output;
    eval.pInDepth = &depth;
    eval.pInMotionVectors = &motion;
    eval.InJitterOffsetX = frame->jitterX;
    eval.InJitterOffsetY = frame->jitterY;
    eval.InRenderSubrectDimensions = {frame->inputWidth, frame->inputHeight};
    eval.InReset = frame->reset;
    eval.InMVScaleX = frame->motionScaleX;
    eval.InMVScaleY = frame->motionScaleY;
    eval.Feature.InSharpness = 0.0f;
    result = NGX_VULKAN_EVALUATE_DLSS_EXT(reinterpret_cast<VkCommandBuffer>(commandBuffer), static_cast<NVSDK_NGX_Handle *>(handle), parameters, &eval);
    NVSDK_NGX_VULKAN_DestroyParameters(parameters);
    return result;
}

ADA_NGX_API void ada_ngx_dlss_release(void *handle) {
    if (handle) NVSDK_NGX_VULKAN_ReleaseFeature(static_cast<NVSDK_NGX_Handle *>(handle));
}

ADA_NGX_API int32_t ada_ngx_dlssd_supported(void) {
    if (!g_parameters) return 0;
    int available = 0;
    NVSDK_NGX_Result result = g_parameters->Get(NVSDK_NGX_Parameter_SuperSamplingDenoising_Available, &available);
    return NVSDK_NGX_SUCCEED(result) && available ? 1 : 0;
}

ADA_NGX_API int32_t ada_ngx_dlssd_create(uint64_t device, uint64_t commandBuffer, const AdaNGXDLSSDescription *description, void **handle) {
    NVSDK_NGX_Parameter *parameters = nullptr;
    NVSDK_NGX_Result result = NVSDK_NGX_VULKAN_AllocateParameters(&parameters);
    if (NVSDK_NGX_FAILED(result)) return result;
    NVSDK_NGX_DLSSD_Create_Params create{};
    create.InDenoiseMode = NVSDK_NGX_DLSS_Denoise_Mode_DLUnified;
    create.InRoughnessMode = NVSDK_NGX_DLSS_Roughness_Mode_Packed;
    create.InUseHWDepth = NVSDK_NGX_DLSS_Depth_Type_HW;
    create.InWidth = description->inputWidth;
    create.InHeight = description->inputHeight;
    create.InTargetWidth = description->outputWidth;
    create.InTargetHeight = description->outputHeight;
    create.InPerfQualityValue = static_cast<NVSDK_NGX_PerfQuality_Value>(description->quality);
    int flags = 0;
    if (description->flags & 1) flags |= NVSDK_NGX_DLSS_Feature_Flags_IsHDR;
    if (description->flags & 2) flags |= NVSDK_NGX_DLSS_Feature_Flags_MVLowRes;
    if (description->flags & 4) flags |= NVSDK_NGX_DLSS_Feature_Flags_DepthInverted;
    create.InFeatureCreateFlags = flags;
    NVSDK_NGX_Handle *feature = nullptr;
    result = NGX_VULKAN_CREATE_DLSSD_EXT1(reinterpret_cast<VkDevice>(device), reinterpret_cast<VkCommandBuffer>(commandBuffer), 1, 1, &feature, parameters, &create);
    NVSDK_NGX_VULKAN_DestroyParameters(parameters);
    if (NVSDK_NGX_SUCCEED(result)) *handle = feature;
    return result;
}

ADA_NGX_API int32_t ada_ngx_dlssd_evaluate(uint64_t commandBuffer, void *handle, const AdaNGXDLSSDFrame *frame) {
    NVSDK_NGX_Parameter *parameters = nullptr;
    NVSDK_NGX_Result result = NVSDK_NGX_VULKAN_AllocateParameters(&parameters);
    if (NVSDK_NGX_FAILED(result)) return result;
    NVSDK_NGX_Resource_VK color = resource(frame->color, false);
    NVSDK_NGX_Resource_VK depth = resource(frame->depth, false);
    NVSDK_NGX_Resource_VK motion = resource(frame->motion, false);
    NVSDK_NGX_Resource_VK output = resource(frame->output, true);
    NVSDK_NGX_Resource_VK diffuse = resource(frame->diffuseAlbedo, false);
    NVSDK_NGX_Resource_VK specular = resource(frame->specularAlbedo, false);
    NVSDK_NGX_Resource_VK normals = resource(frame->normalRoughness, false);
    float worldToView[16], viewToClip[16];
    for (int i = 0; i < 16; ++i) {
        worldToView[i] = frame->worldToView[i];
        viewToClip[i] = frame->viewToClip[i];
    }
    NVSDK_NGX_VK_DLSSD_Eval_Params eval{};
    eval.pInColor = &color;
    eval.pInOutput = &output;
    eval.pInDepth = &depth;
    eval.pInMotionVectors = &motion;
    eval.pInDiffuseAlbedo = &diffuse;
    eval.pInSpecularAlbedo = &specular;
    eval.pInNormals = &normals;
    eval.pInWorldToViewMatrix = worldToView;
    eval.pInViewToClipMatrix = viewToClip;
    eval.InJitterOffsetX = frame->jitterX;
    eval.InJitterOffsetY = frame->jitterY;
    eval.InRenderSubrectDimensions = {frame->inputWidth, frame->inputHeight};
    eval.InReset = frame->reset;
    eval.InMVScaleX = frame->motionScaleX;
    eval.InMVScaleY = frame->motionScaleY;
    result = NGX_VULKAN_EVALUATE_DLSSD_EXT(reinterpret_cast<VkCommandBuffer>(commandBuffer), static_cast<NVSDK_NGX_Handle *>(handle), parameters, &eval);
    NVSDK_NGX_VULKAN_DestroyParameters(parameters);
    return result;
}
