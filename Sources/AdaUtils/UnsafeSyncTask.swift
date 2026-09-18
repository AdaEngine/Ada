#if WASM
    /// Use Swift Coroutines but block current execution context and wait until task is done.
    @available(*, unavailable, message: "UnsafeTask is unavailable on WebAssembly. Use async APIs instead.")
    public final class UnsafeTask<T>: @unchecked Sendable {
        @available(*, unavailable, message: "UnsafeTask is unavailable on WebAssembly. Use async APIs instead.")
        public init(priority _: TaskPriority = .userInitiated, block _: @escaping @Sendable () async throws -> T) {
            preconditionFailure("UnsafeTask is unavailable on WebAssembly.")
        }

        @available(*, unavailable, message: "UnsafeTask is unavailable on WebAssembly. Use async APIs instead.")
        public func get() throws -> T {
            preconditionFailure("UnsafeTask is unavailable on WebAssembly.")
        }
    }
#elseif canImport(Dispatch)
    import Dispatch

    /// Use Swift Coroutines but block current execution context and wait until task is done.
    public final class UnsafeTask<T>: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private var result: Result<T, Error>?

        public init(priority: TaskPriority = .userInitiated, block: @escaping @Sendable () async throws -> T) {
            Task.detached(priority: priority) { @Sendable [self, semaphore] in
                do {
                    self.result = .success(try await block())
                } catch {
                    self.result = .failure(error)
                }
                semaphore.signal()
            }
        }

        public func get() throws -> T {
            if let result {
                return try result.get()
            }

            semaphore.wait()
            guard let result else {
                preconditionFailure("UnsafeTask completed without producing a result.")
            }
            return try result.get()
        }
    }
#else
    /// Use Swift Coroutines but block current execution context and wait until task is done.
    @available(*, unavailable, message: "UnsafeTask requires Dispatch. Use async APIs instead.")
    public final class UnsafeTask<T>: @unchecked Sendable {
        @available(*, unavailable, message: "UnsafeTask requires Dispatch. Use async APIs instead.")
        public init(priority _: TaskPriority = .userInitiated, block _: @escaping @Sendable () async throws -> T) {
            preconditionFailure("UnsafeTask is unavailable on this platform.")
        }

        @available(*, unavailable, message: "UnsafeTask requires Dispatch. Use async APIs instead.")
        public func get() throws -> T {
            preconditionFailure("UnsafeTask is unavailable on this platform.")
        }
    }
#endif
