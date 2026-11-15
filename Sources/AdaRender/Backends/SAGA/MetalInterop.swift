#if METAL
    import Metal

    @_spi(Internal)
    public enum MetalInterop {
        /// Snapshot a drawable's map while reusing the previous eye's geometry targets and pipelines.
        public static func rasterizationRateMap(
            _ map: any MTLRasterizationRateMap,
            layer: Int,
            reusing previous: (any RasterizationRateMap)? = nil
        ) throws -> any RasterizationRateMap {
            try MetalRasterizationRateMap(map: map, layer: layer, previous: previous as? MetalRasterizationRateMap)
        }
    }
#endif
