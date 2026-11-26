// C ABI of the optional NVIDIA NGX bridge (adaengine_ngx.dll). Vulkan handles are passed as 64-bit integers.
// The bridge is built from the NGX SDK by `python ada_tool.py build ngx-bridge` and never linked into AdaEngine.
#ifndef ADA_NGX_H
#define ADA_NGX_H

#include <stdint.h>
#include <wchar.h>

#ifdef _WIN32
#define ADA_NGX_API extern "C" __declspec(dllexport)
#else
#define ADA_NGX_API extern "C"
#endif

// Increment when the ABI changes; the engine refuses a bridge with another version.
#define ADA_NGX_ABI_VERSION 3

typedef struct AdaNGXImage {
    uint64_t image;   // VkImage
    uint64_t view;    // VkImageView
    uint32_t format;  // VkFormat
    uint32_t width;
    uint32_t height;
    uint32_t aspect;  // VkImageAspectFlags
} AdaNGXImage;

typedef struct AdaNGXDLSSDescription {
    uint32_t inputWidth, inputHeight, outputWidth, outputHeight;
    int32_t quality;       // NVSDK_NGX_PerfQuality_Value
    uint32_t flags;        // bit0 HDR, bit1 motion vectors at input resolution, bit2 inverted depth
} AdaNGXDLSSDescription;

typedef struct AdaNGXDLSSFrame {
    AdaNGXImage color, depth, motion, output;
    float jitterX, jitterY;       // pixels, in input space
    float motionScaleX, motionScaleY;
    uint32_t inputWidth, inputHeight;
    int32_t reset;
} AdaNGXDLSSFrame;

// Ray Reconstruction frame. Guides are at input size; roughness is packed in the alpha of normalRoughness.
// The matrices are 16 floats each in the memory order of AdaEngine's Transform3D (columns), which is the row-major,
// left-multiplication layout NGX expects.
typedef struct AdaNGXDLSSDFrame {
    AdaNGXImage color, depth, motion, output, diffuseAlbedo, specularAlbedo, normalRoughness;
    float worldToView[16], viewToClip[16];
    float jitterX, jitterY;
    float motionScaleX, motionScaleY;
    uint32_t inputWidth, inputHeight;
    int32_t reset;
} AdaNGXDLSSDFrame;

ADA_NGX_API uint32_t ada_ngx_abi_version(void);
// Result values are NVSDK_NGX_Result; 1 is success.
ADA_NGX_API int32_t ada_ngx_required_extensions(uint32_t *instanceCount, const char ***instanceNames, uint32_t *deviceCount, const char ***deviceNames);
ADA_NGX_API int32_t ada_ngx_init(uint64_t instance, uint64_t physicalDevice, uint64_t device, void *getInstanceProcAddr, void *getDeviceProcAddr, const wchar_t *dataPath, const wchar_t *featurePath);
ADA_NGX_API int32_t ada_ngx_dlss_supported(void);
ADA_NGX_API void ada_ngx_shutdown(uint64_t device);
ADA_NGX_API int32_t ada_ngx_dlss_create(uint64_t device, uint64_t commandBuffer, const AdaNGXDLSSDescription *description, void **handle);
ADA_NGX_API int32_t ada_ngx_dlss_evaluate(uint64_t commandBuffer, void *handle, const AdaNGXDLSSFrame *frame);
ADA_NGX_API void ada_ngx_dlss_release(void *handle);
ADA_NGX_API int32_t ada_ngx_dlssd_supported(void);
ADA_NGX_API int32_t ada_ngx_dlssd_create(uint64_t device, uint64_t commandBuffer, const AdaNGXDLSSDescription *description, void **handle);
ADA_NGX_API int32_t ada_ngx_dlssd_evaluate(uint64_t commandBuffer, void *handle, const AdaNGXDLSSDFrame *frame);
// Optional extension to ABI v3. Existing v3 bridges continue to accept the original entry point.
ADA_NGX_API int32_t ada_ngx_dlssd_evaluate_with_hit_distance(uint64_t commandBuffer, void *handle, const AdaNGXDLSSDFrame *frame,
                                                          const AdaNGXImage *hitDistance);

#endif
