#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AdaDLSSDevice AdaDLSSDevice;
typedef struct AdaDLSSView AdaDLSSView;

// The handles belong to the SAME Dawn build/device as the rest of the renderer.
AdaDLSSDevice* ada_dlss_device_create(void* device);
void ada_dlss_device_destroy(AdaDLSSDevice* device);
const char* ada_dlss_last_error(void);
AdaDLSSView* ada_dlss_view_create(AdaDLSSDevice* device, uint32_t input_width,
    uint32_t input_height, uint32_t output_width, uint32_t output_height);
void ada_dlss_view_destroy(AdaDLSSView* view);

// Submit the caller's render/motion commands BEFORE calling this function.
// All transfers, fence waits and reconstruction stay on the GPU.
bool ada_dlss_evaluate(AdaDLSSView* view, void* color, void* depth,
    void* motion, void* reactive, void* output,
    float jitter_x, float jitter_y, bool reset);
uint64_t ada_dlss_evaluated_frames(AdaDLSSView* view);

// DLSS Ray Reconstruction (NGX "DLSS-D"): denoises and upscales a path-traced frame.
bool ada_dlss_device_supports_ray_reconstruction(AdaDLSSDevice* device);
AdaDLSSView* ada_dlss_rr_view_create(AdaDLSSDevice* device, uint32_t input_width,
    uint32_t input_height, uint32_t output_width, uint32_t output_height);
// Guides are RGBA16Float at input size: diffuse albedo, specular albedo, and world normal with roughness in w.
// Matrices are 16 floats, row-major (row vectors applied from the left), as NGX expects.
bool ada_dlss_rr_evaluate(AdaDLSSView* view, void* color, void* depth, void* motion, void* reactive,
    void* diffuse_albedo, void* specular_albedo, void* normal_roughness, void* output,
    float jitter_x, float jitter_y, const float* world_to_view, const float* view_to_clip, bool reset);

#ifdef __cplusplus
}
#endif
