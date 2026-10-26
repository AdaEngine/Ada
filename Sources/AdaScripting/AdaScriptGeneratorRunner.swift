import AdaScriptCompilerCore
import Foundation
import Gravity

/// Runs an agent-authored `func build(model)` in an isolated VM.
///
/// The script gets no file, network, scene or engine access: it only sees the builder object that a generator
/// wraps around its host bridge, and the same source and execution-budget limits as downloaded community scripts apply.
@MainActor
enum AdaScriptGeneratorRunner {
    static let policy = AdaScriptCommunityPolicy(maximumCheckpoints: 2_000_000, maximumCallbackSeconds: 3)

    /// - Parameters:
    ///   - kind: Names the generator in error messages, such as "voxel" or "model".
    ///   - prelude: Gravity source defining the builder class and a `factory` function that wraps the host bridge.
    static func run<Bridge: GSExportable>(source: String, kind: String, bridge: Bridge, prelude builderPrelude: String, factory: String) throws {
        guard source.utf8.count <= 64 * 1024 else {
            throw AdaScriptError.invalidManifest("The \(kind) script exceeds 64 KiB.")
        }
        try AdaScriptCommunityLowerer.validate(source: source)
        guard source.contains("func build(") else {
            throw AdaScriptError.invalidManifest("Define `func build(model) { ... }`; the host calls it with the \(kind) builder.")
        }
        let module = try GravityScriptModuleResolver.resolve([AdaScriptSource(path: "\(kind).ada", source: source)])
        let guarded = try module.sourcesByPath.mapValues {
            ResolvedGravityScriptModule.Source(fileID: $0.fileID, source: try AdaScriptCommunityLowerer.instrument(source: $0.source))
        }
        // Gravity holds its delegate unowned, so it must outlive the VM below.
        let delegate = AnnotatedGravityRuntimeDelegate(module: module, sourcesByPath: guarded)
        try AdaScriptRuntimeCoordinator.lock.withLock {
            let vm = GravityVirtualMachine(settings: .init(), delegate: delegate)
            try AdaScriptIdentifiers.bind(to: vm)
            let budget = try AdaScriptCommunityBudget.install(in: vm, policy: policy)
            let prelude = try AdaScriptCommunityLowerer.instrument(source: AdaScriptStandardLibrary.communitySource + builderPrelude)
            try vm.bindClass(with: Bridge.self)
            let binary = vm.loadGravityFile(from: "extern var __adaUGCBudget;\n" + prelude + "\n" + module.entrySource)
            guard delegate.errors.isEmpty else { throw AdaScriptError.compilation(delegate.errors) }
            budget.reset()
            vm.load(binary)
            guard delegate.errors.isEmpty else { throw AdaScriptError.compilation(delegate.errors) }
            budget.reset()
            guard let builder = vm.getValue(forKey: factory).callConstructor(with: [bridge]), !builder.isNull else {
                throw AdaScriptError.invalidManifest("Unable to create the \(kind) builder.")
            }
            budget.reset()
            let errorCount = delegate.errors.count
            guard vm.getValue(forKey: "build").callConstructor(with: [builder]) != nil, delegate.errors.count == errorCount else {
                throw AdaScriptError.compilation(Array(delegate.errors.dropFirst(errorCount)) + ["The \(kind) script failed."])
            }
        }
    }
}

extension GSValue {
    /// A finite number below 1,000,000 in magnitude, from a script integer or double.
    var finiteNumber: Double? {
        if isInteger { return Double(toInteger) }
        if isDouble, toDouble.isFinite, abs(toDouble) < 1_000_000 { return toDouble }
        return nil
    }
}
