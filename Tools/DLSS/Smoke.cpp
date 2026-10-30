#include <AdaWebGPUDLSS.h>
#include <dawn/native/DawnNative.h>
#include <dawn/dawn_proc_table.h>
#include <array>
#include <dawn/webgpu_cpp.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <thread>
#include <vector>
#include <windows.h>
#include <dbghelp.h>

static float halfFloat(uint16_t value) {
    const float magnitude = (value & 0x7c00) == 0 ? std::ldexp(float(value & 1023), -24)
        : std::ldexp(float(1024 + (value & 1023)), int((value >> 10) & 31) - 25);
    return value & 0x8000 ? -magnitude : magnitude;
}
static std::atomic<int> errors{0};
static LONG crash(EXCEPTION_POINTERS* exception) {
    auto context = *exception->ContextRecord;
    fprintf(stderr, "EXCEPTION %lx RIP=%llx base=%p\n", exception->ExceptionRecord->ExceptionCode,
        context.Rip, GetModuleHandleW(nullptr));
    SymInitialize(GetCurrentProcess(), nullptr, TRUE);
    STACKFRAME64 frame{};
    frame.AddrPC = {context.Rip, AddrModeFlat};
    frame.AddrStack = {context.Rsp, AddrModeFlat};
    frame.AddrFrame = {context.Rbp, AddrModeFlat};
    for (int i = 0; i < 24; ++i) {
        fprintf(stderr, "FRAME %llx\n", frame.AddrPC.Offset);
        if (!StackWalk64(IMAGE_FILE_MACHINE_AMD64, GetCurrentProcess(), GetCurrentThread(), &frame,
            &context, nullptr, SymFunctionTableAccess64, SymGetModuleBase64, nullptr)) break;
    }
    fflush(stderr);
    ExitProcess(90);
}

int main() {
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    SetUnhandledExceptionFilter(crash);
    dawn::native::Instance instance;
    wgpu::RequestAdapterOptions options{};
    options.backendType = wgpu::BackendType::D3D12;
    auto adapters = instance.EnumerateAdapters(&options);
    if (adapters.empty()) return 2;
    wgpu::DeviceDescriptor descriptor{};
    const char* toggleNames[] = {"allow_unsafe_apis"};
    wgpu::DawnTogglesDescriptor toggles{};
    toggles.enabledToggleCount = 1;
    toggles.enabledToggles = toggleNames;
    descriptor.nextInChain = &toggles;
    const wgpu::FeatureName features[] = {wgpu::FeatureName::SharedTextureMemoryD3D12Resource,
        wgpu::FeatureName::SharedFenceDXGISharedHandle};
    descriptor.requiredFeatureCount = 2;
    descriptor.requiredFeatures = features;
    descriptor.SetUncapturedErrorCallback([](const wgpu::Device&, wgpu::ErrorType, wgpu::StringView message) {
        fprintf(stderr, "WEBGPU ERROR: %.*s\n", int(message.length), message.data);
        ++errors;
    });
    auto device = wgpu::Device::Acquire(adapters[0].CreateDevice(&descriptor));
    auto bridge = ada_dlss_device_create(device.Get());
    if (!bridge) { fprintf(stderr, "%s\n", ada_dlss_last_error()); return 3; }
    constexpr uint32_t width = 1280, height = 720, ow = 1920, oh = 1080;
    auto makeTexture = [&](uint32_t w, uint32_t h, wgpu::TextureFormat format) {
        wgpu::TextureDescriptor texture{};
        texture.size = {w, h, 1};
        texture.format = format;
        texture.usage = wgpu::TextureUsage::RenderAttachment | wgpu::TextureUsage::TextureBinding
            | wgpu::TextureUsage::CopySrc | wgpu::TextureUsage::CopyDst;
        return device.CreateTexture(&texture);
    };
    auto color = makeTexture(width, height, wgpu::TextureFormat::RGBA16Float);
    auto depth = makeTexture(width, height, wgpu::TextureFormat::Depth32Float);
    auto motion = makeTexture(width, height, wgpu::TextureFormat::RGBA16Float);
    auto reactive = makeTexture(width, height, wgpu::TextureFormat::BGRA8Unorm);
    auto output = makeTexture(ow, oh, wgpu::TextureFormat::RGBA16Float);
    auto view = ada_dlss_view_create(bridge, width, height, ow, oh);
    if (!view) return 4;
    for (uint32_t frame = 0; frame < 12; ++frame) {
        auto encoder = device.CreateCommandEncoder();
        std::array<wgpu::RenderPassColorAttachment, 3> colors{};
        colors[0].view = color.CreateView();
        colors[0].clearValue = {0.125, 0.5, 1.0, 1.0};
        colors[1].view = motion.CreateView();
        colors[2].view = reactive.CreateView();
        for (auto& attachment : colors) { attachment.loadOp = wgpu::LoadOp::Clear; attachment.storeOp = wgpu::StoreOp::Store; }
        wgpu::RenderPassDepthStencilAttachment depthAttachment{};
        depthAttachment.view = depth.CreateView();
        depthAttachment.depthLoadOp = wgpu::LoadOp::Clear;
        depthAttachment.depthStoreOp = wgpu::StoreOp::Store;
        depthAttachment.depthClearValue = 0.5;
        wgpu::RenderPassDescriptor pass{};
        pass.colorAttachmentCount = colors.size();
        pass.colorAttachments = colors.data();
        pass.depthStencilAttachment = &depthAttachment;
        encoder.BeginRenderPass(&pass).End();
        auto commands = encoder.Finish();
        device.GetQueue().Submit(1, &commands);
        if (!ada_dlss_evaluate(view, color.Get(), depth.Get(), motion.Get(), reactive.Get(), output.Get(),
                0, 0, frame == 0 || frame == 6)) return 5;
    }
    const uint64_t frames = ada_dlss_evaluated_frames(view);
    const uint32_t rowBytes = ow * 8;
    wgpu::BufferDescriptor bufferDescriptor{};
    bufferDescriptor.size = uint64_t(rowBytes) * oh;
    bufferDescriptor.usage = wgpu::BufferUsage::CopyDst | wgpu::BufferUsage::MapRead;
    auto buffer = device.CreateBuffer(&bufferDescriptor);
    auto encoder = device.CreateCommandEncoder();
    wgpu::TexelCopyTextureInfo textureCopy{};
    textureCopy.texture = output;
    wgpu::TexelCopyBufferInfo bufferCopy{};
    bufferCopy.buffer = buffer;
    bufferCopy.layout.bytesPerRow = rowBytes;
    bufferCopy.layout.rowsPerImage = oh;
    wgpu::Extent3D extent{ow, oh, 1};
    encoder.CopyTextureToBuffer(&textureCopy, &bufferCopy, &extent);
    auto commands = encoder.Finish();
    device.GetQueue().Submit(1, &commands);
    std::atomic<int> mapped{0};
    buffer.MapAsync(wgpu::MapMode::Read, 0, bufferDescriptor.size, wgpu::CallbackMode::AllowProcessEvents,
        [&](wgpu::MapAsyncStatus status, wgpu::StringView) { mapped = status == wgpu::MapAsyncStatus::Success ? 1 : -1; });
    auto started = std::chrono::steady_clock::now();
    while (!mapped && std::chrono::steady_clock::now() - started < std::chrono::seconds(30)) {
        wgpuInstanceProcessEvents(instance.Get());
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    if (mapped != 1) return 6;
    auto pixels = static_cast<const uint16_t*>(buffer.GetConstMappedRange());
    double mean[3]{};
    for (uint32_t p = 0; p < ow * oh; ++p) for (int c = 0; c < 3; ++c) mean[c] += halfFloat(pixels[p * 4 + c]) / double(ow * oh);
    buffer.Unmap();
    const bool correct = std::abs(mean[0] - 0.125) < 0.015 && std::abs(mean[1] - 0.5) < 0.015
        && std::abs(mean[2] - 1.0) < 0.03 && frames == 12 && !errors;
    fprintf(stdout, "DLSS_SMOKE frames=%llu input=%ux%u output=%ux%u mean=%.6f,%.6f,%.6f errors=%d pass=%d\n",
        frames, width, height, ow, oh, mean[0], mean[1], mean[2], int(errors), correct);
    ada_dlss_view_destroy(view);
    ada_dlss_device_destroy(bridge);
    return correct ? 0 : 7;
}
