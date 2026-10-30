#include "DLSSInterop.h"
#include <cmath>
#include <cstdio>

AdaDLSSView::~AdaDLSSView() {
    // A failed preparation may have acquired only a subset of the textures.
    for (auto* texture : {&color, &depth, &motion, &bias, &output}) {
        texture->end(device, outputWaitFences);
    }
    device.idle();
    if (feature) NVSDK_NGX_D3D12_ReleaseFeature(feature);
    if (parameters) NVSDK_NGX_D3D12_DestroyParameters(parameters);
}
bool AdaDLSSView::initialize() {
    if (!width || !height || outputWidth < width || outputHeight < height) return false;
    const auto sampled = wgpu::TextureUsage::TextureBinding;
    const auto rendered = sampled | wgpu::TextureUsage::RenderAttachment;
    if (!color.create(device, width, height, DXGI_FORMAT_R16G16B16A16_FLOAT,
            wgpu::TextureFormat::RGBA16Float, sampled | wgpu::TextureUsage::CopyDst, D3D12_RESOURCE_FLAG_NONE)
        || !depth.create(device, width, height, DXGI_FORMAT_R32_FLOAT,
            wgpu::TextureFormat::R32Float, rendered, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET)
        || !motion.create(device, width, height, DXGI_FORMAT_R16G16_FLOAT,
            wgpu::TextureFormat::RG16Float, rendered, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET)
        || !bias.create(device, width, height, DXGI_FORMAT_R8_UNORM,
            wgpu::TextureFormat::R8Unorm, rendered, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET)
        || !output.create(device, outputWidth, outputHeight, DXGI_FORMAT_R16G16B16A16_FLOAT,
            wgpu::TextureFormat::RGBA16Float, sampled | wgpu::TextureUsage::CopySrc, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS)) return false;
    packedViews = {depth.texture.CreateView(), motion.texture.CreateView(), bias.texture.CreateView()};
    outputWaitFences.reserve(1);
    if (!ada_dlss_check_ngx(NVSDK_NGX_D3D12_AllocateParameters(&parameters), "DLSS parameter allocation")) return false;
    for (auto& frame : frames) {
        frame.waitFences.reserve(6);
        if (!ada_dlss_check(device.native->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,
                IID_PPV_ARGS(&frame.allocator)), "DLSS command allocator")
            || !ada_dlss_check(device.native->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT,
                frame.allocator.Get(), nullptr, IID_PPV_ARGS(&frame.commands)), "DLSS command list")
            || !ada_dlss_check(frame.commands->Close(), "Close initial command list")) return false;
    }
    return true;
}

bool AdaDLSSView::pack(WGPUTexture inputColor, WGPUTexture inputDepth, WGPUTexture inputMotion,
    WGPUTexture reactive, AdaDLSSFrame& frame) {
    if (!color.begin(device, lastSignal) || !depth.begin(device, lastSignal)
        || !motion.begin(device, lastSignal) || !bias.begin(device, lastSignal)) return false;
    auto encoder = device.webgpu.CreateCommandEncoder();
    wgpu::TexelCopyTextureInfo source, destination;
    source.texture = wgpu::Texture(inputColor);
    destination.texture = color.texture;
    wgpu::Extent3D extent{width, height, 1};
    encoder.CopyTextureToTexture(&source, &destination, &extent);
    if (!packGroup || boundDepth.Get() != inputDepth || boundMotion.Get() != inputMotion || boundReactive.Get() != reactive) {
        boundDepth = wgpu::Texture(inputDepth);
        boundMotion = wgpu::Texture(inputMotion);
        boundReactive = wgpu::Texture(reactive);
        std::array<wgpu::BindGroupEntry, 3> bindings{};
        bindings[0].textureView = boundDepth.CreateView();
        bindings[1].textureView = boundMotion.CreateView();
        bindings[2].textureView = boundReactive.CreateView();
        for (uint32_t i = 0; i < bindings.size(); ++i) bindings[i].binding = i;
        wgpu::BindGroupDescriptor bindDescriptor{};
        bindDescriptor.layout = device.packPipeline.GetBindGroupLayout(0);
        bindDescriptor.entryCount = bindings.size();
        bindDescriptor.entries = bindings.data();
        packGroup = device.webgpu.CreateBindGroup(&bindDescriptor);
    }
    std::array<wgpu::RenderPassColorAttachment, 3> attachments{};
    for (size_t i = 0; i < attachments.size(); ++i) attachments[i].view = packedViews[i];
    for (auto& attachment : attachments) {
        attachment.loadOp = wgpu::LoadOp::Clear;
        attachment.storeOp = wgpu::StoreOp::Store;
    }
    wgpu::RenderPassDescriptor passDescriptor{};
    passDescriptor.label = "DLSS input preparation";
    passDescriptor.colorAttachmentCount = attachments.size();
    passDescriptor.colorAttachments = attachments.data();
    auto pass = encoder.BeginRenderPass(&passDescriptor);
    pass.SetPipeline(device.packPipeline);
    pass.SetBindGroup(0, packGroup);
    pass.Draw(3);
    pass.End();
    auto commands = encoder.Finish();
    device.webgpu.GetQueue().Submit(1, &commands);
    return color.end(device, frame.waitFences) && depth.end(device, frame.waitFences)
        && motion.end(device, frame.waitFences) && bias.end(device, frame.waitFences);
}

bool AdaDLSSView::evaluate(WGPUTexture inputColor, WGPUTexture inputDepth, WGPUTexture inputMotion,
    WGPUTexture reactive, WGPUTexture destination, float jitterX, float jitterY, bool reset) {
    if (!valid || !inputColor || !inputDepth || !inputMotion || !reactive || !destination
        || !std::isfinite(jitterX) || !std::isfinite(jitterY)) return false;
    for (auto texture : {inputColor, inputDepth, inputMotion, reactive}) {
        if (wgpuTextureGetWidth(texture) != width || wgpuTextureGetHeight(texture) != height) return false;
    }
    if (wgpuTextureGetWidth(destination) != outputWidth || wgpuTextureGetHeight(destination) != outputHeight
        || wgpuTextureGetFormat(inputColor) != WGPUTextureFormat_RGBA16Float
        || wgpuTextureGetFormat(destination) != WGPUTextureFormat_RGBA16Float
        || wgpuTextureGetFormat(inputDepth) != WGPUTextureFormat_Depth32Float) return false;
    auto& frame = frames[evaluated % frames.size()];
    // Only throttle when all frames in flight are still busy; there is no pixel readback.
    if (!device.wait(frame.completion)) return false;
    frame.waitFences.clear();
    frame.waitFences.swap(outputWaitFences);
    if (!evaluated) fprintf(stderr, "AdaEngine DLSS: preparing shared inputs\n");
    if (!pack(inputColor, inputDepth, inputMotion, reactive, frame)) { valid = false; return false; }
    if (!evaluated) fprintf(stderr, "AdaEngine DLSS: inputs released to NGX\n");
    if (!ada_dlss_check(frame.allocator->Reset(), "Reset DLSS allocator")
        || !ada_dlss_check(frame.commands->Reset(frame.allocator.Get(), nullptr), "Reset DLSS commands")) return false;
    if (!feature) {
        NVSDK_NGX_DLSS_Create_Params create{};
        create.Feature.InWidth = width;
        create.Feature.InHeight = height;
        create.Feature.InTargetWidth = outputWidth;
        create.Feature.InTargetHeight = outputHeight;
        const float scale = float(width) / outputWidth;
        create.Feature.InPerfQualityValue = scale >= 0.99f ? NVSDK_NGX_PerfQuality_Value_DLAA
            : scale >= 0.6f ? NVSDK_NGX_PerfQuality_Value_MaxQuality
            : scale >= 0.55f ? NVSDK_NGX_PerfQuality_Value_Balanced : NVSDK_NGX_PerfQuality_Value_MaxPerf;
        create.InFeatureCreateFlags = NVSDK_NGX_DLSS_Feature_Flags_IsHDR
            | NVSDK_NGX_DLSS_Feature_Flags_MVLowRes | NVSDK_NGX_DLSS_Feature_Flags_AutoExposure;
        if (!evaluated) fprintf(stderr, "AdaEngine DLSS: creating NGX feature\n");
        if (!ada_dlss_check_ngx(NGX_D3D12_CREATE_DLSS_EXT(frame.commands.Get(), 1, 1, &feature, parameters, &create),
            "Create DLSS Super Resolution feature")) { valid = false; return false; }
    }
    std::array<D3D12_RESOURCE_BARRIER, 5> barriers{};
    std::array<ID3D12Resource*, 5> resources{color.native.Get(), depth.native.Get(), motion.native.Get(), bias.native.Get(), output.native.Get()};
    for (size_t i = 0; i < barriers.size(); ++i) {
        barriers[i].Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        barriers[i].Transition.pResource = resources[i];
        barriers[i].Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        barriers[i].Transition.StateBefore = D3D12_RESOURCE_STATE_COMMON;
        barriers[i].Transition.StateAfter = i == 4 ? D3D12_RESOURCE_STATE_UNORDERED_ACCESS : D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
    }
    frame.commands->ResourceBarrier(static_cast<UINT>(barriers.size()), barriers.data());
    NVSDK_NGX_D3D12_DLSS_Eval_Params evaluate{};
    evaluate.Feature.pInColor = color.native.Get();
    evaluate.Feature.pInOutput = output.native.Get();
    evaluate.pInDepth = depth.native.Get();
    evaluate.pInMotionVectors = motion.native.Get();
    evaluate.pInBiasCurrentColorMask = bias.native.Get();
    // Engine motion is unjittered previousUV-currentUV; NGX expects current-to-previous pixels.
    evaluate.InMVScaleX = float(width);
    evaluate.InMVScaleY = float(height);
    evaluate.InJitterOffsetX = jitterX;
    evaluate.InJitterOffsetY = jitterY;
    evaluate.InReset = reset || evaluated == 0;
    evaluate.InRenderSubrectDimensions = {width, height};
    evaluate.InPreExposure = 1.0f;
    evaluate.InExposureScale = 1.0f;
    if (!ada_dlss_check_ngx(NGX_D3D12_EVALUATE_DLSS_EXT(frame.commands.Get(), feature, parameters, &evaluate), "Evaluate DLSS")) {
        valid = false;
        return false;
    }
    for (auto& barrier : barriers) std::swap(barrier.Transition.StateBefore, barrier.Transition.StateAfter);
    frame.commands->ResourceBarrier(static_cast<UINT>(barriers.size()), barriers.data());
    if (!ada_dlss_check(frame.commands->Close(), "Close DLSS evaluation")) return false;
    ID3D12CommandList* lists[] = {frame.commands.Get()};
    device.queue->ExecuteCommandLists(1, lists);
    lastSignal = ++device.serial;
    if (!ada_dlss_check(device.queue->Signal(device.fence.Get(), lastSignal), "Signal DLSS completion")) return false;
    frame.completion = lastSignal;
    output.initialized = true;
    if (!output.begin(device, lastSignal)) { valid = false; return false; }
    auto copy = device.webgpu.CreateCommandEncoder();
    wgpu::TexelCopyTextureInfo source, target;
    source.texture = output.texture;
    target.texture = wgpu::Texture(destination);
    wgpu::Extent3D extent{outputWidth, outputHeight, 1};
    copy.CopyTextureToTexture(&source, &target, &extent);
    auto copied = copy.Finish();
    device.webgpu.GetQueue().Submit(1, &copied);
    if (!output.end(device, outputWaitFences)) { valid = false; return false; }
    ++evaluated;
    if (evaluated == 1) fprintf(stderr, "AdaEngine DLSS: evaluated %ux%u -> %ux%u via Dawn shared textures\n", width, height, outputWidth, outputHeight);
    return true;
}

extern "C" AdaDLSSView* ada_dlss_view_create(AdaDLSSDevice* device, uint32_t width, uint32_t height, uint32_t ow, uint32_t oh) {
    if (!device) return nullptr;
    std::lock_guard lock(device->mutex);
    auto view = std::make_unique<AdaDLSSView>(*device, width, height, ow, oh);
    return view->initialize() ? view.release() : nullptr;
}
extern "C" void ada_dlss_view_destroy(AdaDLSSView* view) {
    if (!view) return;
    std::lock_guard lock(view->device.mutex);
    delete view;
}
extern "C" bool ada_dlss_evaluate(AdaDLSSView* view, void* color, void* depth, void* motion,
    void* reactive, void* output, float jitterX, float jitterY, bool reset) {
    if (!view) return false;
    std::lock_guard lock(view->device.mutex);
    return view->evaluate(static_cast<WGPUTexture>(color), static_cast<WGPUTexture>(depth),
        static_cast<WGPUTexture>(motion), static_cast<WGPUTexture>(reactive), static_cast<WGPUTexture>(output), jitterX, jitterY, reset);
}
extern "C" uint64_t ada_dlss_evaluated_frames(AdaDLSSView* view) { return view ? view->evaluated : 0; }
