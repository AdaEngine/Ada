#if os(Android)
    import CAndroid
    @_spi(ExperimentalCustomExecutors) import _Concurrency

    // Swift 6.3 exposes the executor factory through this SPI. It must be installed
    // before any task is enqueued. Keep the dependency isolated to Android and pin
    // the matching compiler/SDK in the packaging tool until the API is stable.
    private enum AndroidExecutorFactory: ExecutorFactory {
        static var mainExecutor: any MainExecutor { AndroidMainExecutor.shared }
        static var defaultExecutor: any TaskExecutor { PlatformExecutorFactory.defaultExecutor }
    }

    private final class AndroidMainExecutor: MainExecutor, Sendable {
        static let shared = AndroidMainExecutor()
        var isMainExecutor: Bool { true }

        func enqueue(_ job: consuming ExecutorJob) {
            let box = AndroidExecutorJob(job: unsafe UnownedJob(job))
            // The native queue owns the retained box until it invokes execute_job.
            unsafe ada_android_enqueue_job(Unmanaged.passRetained(box).toOpaque())
        }

        func isIsolatingCurrentContext() -> Bool? { unsafe ada_android_is_main_thread() }

        func run() throws(AndroidExecutorError) { throw .externallyDrivenRunLoop }
        func runUntil(_ condition: () -> Bool) throws(AndroidExecutorError) {
            if !condition() { throw .externallyDrivenRunLoop }
        }
        func stop() {}  // Android owns and stops its main looper.
    }

    private enum AndroidExecutorError: Error { case externallyDrivenRunLoop }

    private final class AndroidExecutorJob: Sendable {
        let job: UnownedJob
        init(job: UnownedJob) { unsafe self.job = job }
        func execute() {
            unsafe job.runSynchronously(on: AndroidMainExecutor.shared.asUnownedSerialExecutor())
        }
    }

    @_cdecl("ada_android_install_executors")
    func installAndroidExecutors() {
        _createExecutors(factory: AndroidExecutorFactory.self)
    }

    @_cdecl("ada_android_execute_job")
    func executeAndroidJob(_ pointer: UnsafeMutableRawPointer?) {
        guard let pointer else { return }
        let box = unsafe Unmanaged<AndroidExecutorJob>.fromOpaque(pointer).takeRetainedValue()
        box.execute()
    }
#endif
