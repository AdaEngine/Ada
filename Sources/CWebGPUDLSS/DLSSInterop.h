#pragma once
#include "include/AdaWebGPUDLSS.h"
#include <dawn/native/D3D12Backend.h>
#include <dawn/webgpu_cpp.h>
#include <nvsdk_ngx_helpers.h>
#include <nvsdk_ngx_helpers_d3d.h>
#include <nvsdk_ngx_helpers_dlssd_d3d.h>
#include <cstdlib>
#include <array>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

using Microsoft::WRL::ComPtr;
void ada_dlss_error(const char* operation, uint32_t code);
bool ada_dlss_check(HRESULT result, const char* operation);
bool ada_dlss_check_ngx(NVSDK_NGX_Result result, const char* operation);

struct AdaDLSSDevice {
    wgpu::Device webgpu;
    ComPtr<ID3D12Device> native;
    ComPtr<ID3D12CommandQueue> queue;
    ComPtr<ID3D12Fence> fence;
    wgpu::SharedFence sharedFence;
    NVSDK_NGX_Parameter* capabilities = nullptr;
    wgpu::RenderPipeline packPipeline;
    std::mutex mutex;
    uint64_t serial = 0;
    bool initialized = false;
    /// Ray Reconstruction (NGX "DLSS-D") is available in addition to Super Resolution.
    bool supportsRayReconstruction = false;
    /// `nvngx_dlssd.dll` sits next to `nvngx_dlss.dll`.
    bool hasDenoiserRuntime = false;
    /// Extra folders NGX searches for its runtime DLLs; NGX may read them whenever it creates a feature.
    std::vector<std::wstring> runtimeFolders;
    std::vector<const wchar_t*> runtimeFolderPointers;
    ~AdaDLSSDevice();
    /// Finds `nvngx_dlss.dll` beside the executable or in the prepared SDK; false with `lastError` set otherwise.
    bool locateRuntime();
    bool initialize();
    bool wait(uint64_t value);
    bool idle();
};

struct AdaDLSSSharedTexture {
    ComPtr<ID3D12Resource> native;
    wgpu::SharedTextureMemory memory;
    wgpu::Texture texture;
    bool acquired = false;
    bool initialized = false;
    bool create(AdaDLSSDevice& device, uint32_t width, uint32_t height,
        DXGI_FORMAT nativeFormat, wgpu::TextureFormat format, wgpu::TextureUsage usage,
        D3D12_RESOURCE_FLAGS flags);
    bool begin(AdaDLSSDevice& device, uint64_t value);
    bool end(AdaDLSSDevice& device, std::vector<ComPtr<ID3D12Fence>>& keepAlive);
};

struct AdaDLSSFrame {
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList> commands;
    std::vector<ComPtr<ID3D12Fence>> waitFences;
    uint64_t completion = 0;
};

struct AdaDLSSView {
    AdaDLSSDevice& device;
    uint32_t width, height, outputWidth, outputHeight;
    AdaDLSSSharedTexture color, depth, motion, bias, output;
    /// Ray Reconstruction guides, allocated only when `rayReconstruction` is set.
    AdaDLSSSharedTexture diffuseAlbedo, specularAlbedo, normals;
    bool rayReconstruction = false;
    std::array<wgpu::TextureView, 3> packedViews;
    wgpu::Texture boundDepth, boundMotion, boundReactive;
    wgpu::BindGroup packGroup;
    std::array<AdaDLSSFrame, 3> frames;
    std::vector<ComPtr<ID3D12Fence>> outputWaitFences;
    NVSDK_NGX_Parameter* parameters = nullptr;
    NVSDK_NGX_Handle* feature = nullptr;
    uint64_t evaluated = 0, lastSignal = 0;
    bool valid = true;
    AdaDLSSView(AdaDLSSDevice& device, uint32_t w, uint32_t h, uint32_t ow, uint32_t oh)
        : device(device), width(w), height(h), outputWidth(ow), outputHeight(oh) {}
    ~AdaDLSSView();
    bool initialize();
    bool pack(WGPUTexture inputColor, WGPUTexture inputDepth, WGPUTexture inputMotion, WGPUTexture reactive,
        AdaDLSSFrame& frame);
    bool evaluate(WGPUTexture inputColor, WGPUTexture inputDepth, WGPUTexture inputMotion,
        WGPUTexture reactive, WGPUTexture destination, float jitterX, float jitterY, bool reset);
    /// Ray Reconstruction; the guides are copied into shared textures before NGX reads them.
    bool evaluateDenoised(WGPUTexture inputColor, WGPUTexture inputDepth, WGPUTexture inputMotion,
        WGPUTexture reactive, WGPUTexture diffuse, WGPUTexture specular, WGPUTexture normalRoughness,
        WGPUTexture destination, float jitterX, float jitterY, const float* worldToView, const float* viewToClip, bool reset);
    bool copyGuides(WGPUTexture diffuse, WGPUTexture specular, WGPUTexture normalRoughness, AdaDLSSFrame& frame);

};
