#include "DLSSInterop.h"
#include <filesystem>
#include <cstdio>

namespace {
thread_local std::string lastError;
// A custom-engine project identifier, NOT an NVIDIA-assigned application ID.
constexpr const char* projectID = "c7363c1b-1c73-47f6-b290-b9129dd701ab";
constexpr const char* packingShader = R"wgsl(
@group(0) @binding(0) var sceneDepth: texture_depth_2d;
@group(0) @binding(1) var sceneMotion: texture_2d<f32>;
@group(0) @binding(2) var sceneReactive: texture_2d<f32>;
@vertex fn vertex(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
    let x = f32((i << 1u) & 2u);
    let y = f32(i & 2u);
    return vec4f(x * 2.0 - 1.0, y * 2.0 - 1.0, 0.0, 1.0);
}
struct Packed {
    @location(0) depth: f32,
    @location(1) motion: vec2f,
    @location(2) bias: f32,
};
@fragment fn fragment(@builtin(position) p: vec4f) -> Packed {
    let uv = vec2i(p.xy);
    var result: Packed;
    result.depth = textureLoad(sceneDepth, uv, 0);
    result.motion = textureLoad(sceneMotion, uv, 0).xy;
    result.bias = textureLoad(sceneReactive, uv, 0).r;
    return result;
}
)wgsl";
}

void ada_dlss_error(const char* operation, uint32_t code) {
    char text[256];
    snprintf(text, sizeof(text), "%s failed (0x%08x)", operation, code);
    lastError = text;
    fprintf(stderr, "AdaEngine DLSS: %s\n", text);
}
bool ada_dlss_check(HRESULT result, const char* operation) {
    if (SUCCEEDED(result)) return true;
    ada_dlss_error(operation, result);
    return false;
}
bool ada_dlss_check_ngx(NVSDK_NGX_Result result, const char* operation) {
    if (NVSDK_NGX_SUCCEED(result)) return true;
    ada_dlss_error(operation, result);
    return false;
}
extern "C" const char* ada_dlss_last_error() { return lastError.c_str(); }

bool AdaDLSSDevice::wait(uint64_t value) {
    if (!value || fence->GetCompletedValue() >= value) return true;
    HANDLE event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!event) return false;
    const auto result = fence->SetEventOnCompletion(value, event);
    const auto status = SUCCEEDED(result) ? WaitForSingleObject(event, 30000) : WAIT_FAILED;
    CloseHandle(event);
    if (status != WAIT_OBJECT_0) { ada_dlss_error("GPU completion", status); return false; }
    return true;
}
bool AdaDLSSDevice::idle() {
    return queue && fence && ada_dlss_check(queue->Signal(fence.Get(), ++serial), "Signal") && wait(serial);
}
AdaDLSSDevice::~AdaDLSSDevice() {
    if (initialized) {
        idle();
        if (capabilities) NVSDK_NGX_D3D12_DestroyParameters(capabilities);
        NVSDK_NGX_D3D12_Shutdown1(native.Get());
    }
}
bool AdaDLSSDevice::initialize() {
    if (!webgpu.HasFeature(wgpu::FeatureName::SharedTextureMemoryD3D12Resource)
        || !webgpu.HasFeature(wgpu::FeatureName::SharedFenceDXGISharedHandle)) {
        lastError = "Dawn D3D12 shared texture/fence features are unavailable";
        return false;
    }
    native = dawn::native::d3d12::GetD3D12Device(webgpu.Get());
    queue = dawn::native::d3d12::GetD3D12CommandQueue(webgpu.Get());
    if (!native || !queue) return false;
    ComPtr<IDXGIFactory4> factory;
    ComPtr<IDXGIAdapter1> adapter;
    if (!ada_dlss_check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)), "DXGI factory")
        || !ada_dlss_check(factory->EnumAdapterByLuid(native->GetAdapterLuid(), IID_PPV_ARGS(&adapter)), "Selected adapter")) return false;
    DXGI_ADAPTER_DESC1 info{};
    if (FAILED(adapter->GetDesc1(&info)) || info.VendorId != 0x10de) {
        lastError = "The selected Dawn adapter is not an NVIDIA GPU";
        return false;
    }
    std::error_code error;
    auto logs = std::filesystem::temp_directory_path(error) / L"AdaEngine" / L"NGX";
    std::filesystem::create_directories(logs, error);
    if (error) { lastError = "NGX log directory is unavailable"; return false; }
    const auto result = NVSDK_NGX_D3D12_Init_with_ProjectID(projectID, NVSDK_NGX_ENGINE_TYPE_CUSTOM,
        "AdaEngine", logs.c_str(), native.Get());
    if (!ada_dlss_check_ngx(result, "NGX initialization")) return false;
    initialized = true;
    if (!ada_dlss_check_ngx(NVSDK_NGX_D3D12_GetCapabilityParameters(&capabilities), "DLSS capabilities")) return false;
    int supported = 0, driverUpdate = 0;
    capabilities->Get(NVSDK_NGX_Parameter_SuperSampling_Available, &supported);
    capabilities->Get(NVSDK_NGX_Parameter_SuperSampling_NeedsUpdatedDriver, &driverUpdate);
    if (!supported || driverUpdate) { lastError = "DLSS is unavailable on the selected adapter/driver"; return false; }
    if (!ada_dlss_check(native->CreateFence(0, D3D12_FENCE_FLAG_SHARED, IID_PPV_ARGS(&fence)), "Create shared fence")) return false;
    HANDLE handle = nullptr;
    if (!ada_dlss_check(native->CreateSharedHandle(fence.Get(), nullptr, GENERIC_ALL, nullptr, &handle), "Share fence")) return false;
    wgpu::SharedFenceDXGISharedHandleDescriptor shared{};
    shared.handle = handle;
    wgpu::SharedFenceDescriptor descriptor{};
    descriptor.nextInChain = &shared;
    sharedFence = webgpu.ImportSharedFence(&descriptor);
    CloseHandle(handle);
    wgpu::ShaderSourceWGSL source{};
    source.code = packingShader;
    wgpu::ShaderModuleDescriptor shaderDescriptor{};
    shaderDescriptor.nextInChain = &source;
    auto shader = webgpu.CreateShaderModule(&shaderDescriptor);
    std::array<wgpu::ColorTargetState, 3> targets{};
    targets[0].format = wgpu::TextureFormat::R32Float;
    targets[1].format = wgpu::TextureFormat::RG16Float;
    targets[2].format = wgpu::TextureFormat::R8Unorm;
    wgpu::FragmentState fragment{};
    fragment.module = shader;
    fragment.entryPoint = "fragment";
    fragment.targetCount = targets.size();
    fragment.targets = targets.data();
    wgpu::RenderPipelineDescriptor pipeline{};
    pipeline.label = "DLSS depth / motion / transparency packing";
    pipeline.vertex.module = shader;
    pipeline.vertex.entryPoint = "vertex";
    pipeline.fragment = &fragment;
    packPipeline = webgpu.CreateRenderPipeline(&pipeline);
    fprintf(stderr, "AdaEngine DLSS: NGX available on the selected Dawn D3D12 adapter\n");
    return sharedFence && packPipeline;
}

extern "C" AdaDLSSDevice* ada_dlss_device_create(void* device) {
    if (!device) return nullptr;
    auto result = std::make_unique<AdaDLSSDevice>();
    result->webgpu = wgpu::Device(static_cast<WGPUDevice>(device));
    return result->initialize() ? result.release() : nullptr;
}
extern "C" void ada_dlss_device_destroy(AdaDLSSDevice* device) { delete device; }

bool AdaDLSSSharedTexture::create(AdaDLSSDevice& device, uint32_t width, uint32_t height,
    DXGI_FORMAT nativeFormat, wgpu::TextureFormat format, wgpu::TextureUsage usage, D3D12_RESOURCE_FLAGS flags) {
    D3D12_HEAP_PROPERTIES heap{};
    heap.Type = D3D12_HEAP_TYPE_DEFAULT;
    D3D12_RESOURCE_DESC resource{};
    resource.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    resource.Width = width;
    resource.Height = height;
    resource.DepthOrArraySize = 1;
    resource.MipLevels = 1;
    resource.Format = nativeFormat;
    resource.SampleDesc.Count = 1;
    resource.Flags = flags | D3D12_RESOURCE_FLAG_ALLOW_SIMULTANEOUS_ACCESS;
    if (!ada_dlss_check(device.native->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &resource,
        D3D12_RESOURCE_STATE_COMMON, nullptr, IID_PPV_ARGS(&native)), "Create interop texture")) return false;
    dawn::native::d3d12::SharedTextureMemoryD3D12ResourceDescriptor imported;
    imported.resource = native;
    wgpu::SharedTextureMemoryDescriptor memoryDescriptor{};
    memoryDescriptor.nextInChain = &imported;
    memory = device.webgpu.ImportSharedTextureMemory(&memoryDescriptor);
    wgpu::TextureDescriptor textureDescriptor{};
    textureDescriptor.size = {width, height, 1};
    textureDescriptor.format = format;
    textureDescriptor.usage = usage;
    texture = memory.CreateTexture(&textureDescriptor);
    return memory && texture;
}
bool AdaDLSSSharedTexture::begin(AdaDLSSDevice& device, uint64_t value) {
    wgpu::SharedTextureMemoryBeginAccessDescriptor access{};
    access.initialized = initialized;
    if (value) {
        access.fenceCount = 1;
        access.fences = &device.sharedFence;
        access.signaledValues = &value;
    }
    acquired = memory.BeginAccess(texture, &access) == wgpu::Status::Success;
    if (!acquired) ada_dlss_error("Dawn BeginAccess", 0);
    return acquired;
}
bool AdaDLSSSharedTexture::end(AdaDLSSDevice& device, std::vector<ComPtr<ID3D12Fence>>& keepAlive) {
    if (!acquired) return true;
    wgpu::SharedTextureMemoryEndAccessState state{};
    if (memory.EndAccess(texture, &state) != wgpu::Status::Success) {
        ada_dlss_error("Dawn EndAccess", 0);
        return false;
    }
    acquired = false;
    initialized = state.initialized;
    for (size_t index = 0; index < state.fenceCount; ++index) {
        wgpu::SharedFenceDXGISharedHandleExportInfo dxgi{};
        wgpu::SharedFenceExportInfo exported{};
        exported.nextInChain = &dxgi;
        state.fences[index].ExportInfo(&exported);
        ComPtr<ID3D12Fence> fence;
        if (!ada_dlss_check(device.native->OpenSharedHandle(dxgi.handle, IID_PPV_ARGS(&fence)), "Open Dawn fence")
            || !ada_dlss_check(device.queue->Wait(fence.Get(), state.signaledValues[index]), "Wait for Dawn")) return false;
        keepAlive.push_back(fence);
    }
    return true;
}
