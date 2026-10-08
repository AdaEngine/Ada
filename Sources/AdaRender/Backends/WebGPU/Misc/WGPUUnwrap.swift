#if WEBGPU_ENABLED && canImport(WebGPU)
    @unsafe @preconcurrency import WebGPU

    extension Optional {
        func unwrap(message: @autoclosure () -> String) -> Wrapped {
            guard let value = self else {
                fatalError(message())
            }
            return value
        }
    }

    extension WebGPU.GPUBuffer {
        func unwrap(message _: @autoclosure () -> String) -> Self {
            self
        }
    }

#endif
