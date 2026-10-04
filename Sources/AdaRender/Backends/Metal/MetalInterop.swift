#if METAL
    import Metal

    /// Borrow native resources only between engine frames. The caller must use this queue
    /// for dependent commands so Metal preserves ordering with the engine render graph.
    @_spi(Internal)
    public enum MetalInterop {
        public static func commandQueue(for device: RenderDevice) -> (any MTLCommandQueue)? {
            (device as? MetalRenderDevice)?.commandQueue
        }

        public static func texture(_ texture: Texture) -> (any MTLTexture)? {
            (texture.gpuTexture as? MetalGPUTexture)?.texture
        }
    }
#endif
