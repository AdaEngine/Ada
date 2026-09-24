@_spi(Internal) import AdaApp
import AdaAssets
import Foundation
import Gravity

/// Synchronous VM facade. AdaAssets keeps the actual typed handle and cache identity.
@GSExportable("AdaAssets")
final class AdaScriptAssetsBridge: @unchecked Sendable {
    @GSExportableIgnore
    private var reportDiagnostic: @Sendable (String) -> Void = { _ in }

    @GSExportableIgnore
    private var handles: [String: any AnyAssetHandleInfo] = [:]

    @GSExportableIgnore
    private let handlesLock = NSLock()

    @GSExportableIgnore
    var onWake: (@Sendable () -> Void)?

    @GSExportableIgnore
    static func make(
        reportDiagnostic: @escaping @Sendable (String) -> Void
    ) -> AdaScriptAssetsBridge {
        let bridge = AdaScriptAssetsBridge()
        bridge.reportDiagnostic = reportDiagnostic
        return bridge
    }

    func perform(_ arguments: GSValue) -> String {
        guard arguments.isList else {
            reportDiagnostic("AdaScript Assets operation requires a list")
            return ""
        }
        let values = arguments.toList
        guard let operation = values.first, operation.isString else {
            reportDiagnostic("AdaScript Assets operation is missing its name")
            return ""
        }
        let strings = values.dropFirst().compactMap { $0.isString ? $0.toString : nil }
        switch operation.toString {
        case "load":
            guard let path = strings.first else {
                return ""
            }
            return resolve(path, handleChanges: true)
        case "loadTyped":
            guard strings.count == 2 else {
                return ""
            }
            return resolve(typeName: strings[0], path: strings[1], handleChanges: true)
        case "save":
            guard strings.count == 2 else {
                return ""
            }
            return store(reference: strings[0], path: strings[1]) ? strings[0] : ""
        default:
            reportDiagnostic("Unknown AdaScript Assets operation '\(operation.toString)'")
            return ""
        }
    }

    func begin(_ arguments: GSValue) -> AdaScriptAsyncOperation {
        let operation = AdaScriptAsyncOperation()
        operation.onCompletion = onWake
        guard arguments.isList else {
            operation.complete(.failure("invalidArguments", message: "Async Assets operation requires a list"))
            return operation
        }
        let values = arguments.toList
        guard let name = values.first, name.isString else {
            operation.complete(.failure("invalidArguments", message: "Async Assets operation is missing its name"))
            return operation
        }
        let strings = values.dropFirst().compactMap { $0.isString ? $0.toString : nil }
        switch name.toString {
        case "loadAsync":
            guard let path = strings.first, let type = AssetsManager.inferAssetType(at: path) else {
                operation.complete(.failure("unknownAssetType", message: "Cannot infer an asset type"))
                return operation
            }
            beginLoad(type: type, path: path, operation: operation)
        case "loadTypedAsync":
            guard strings.count == 2, let type = AssetsManager.getAssetType(named: strings[0]) else {
                operation.complete(.failure("unknownAssetType", message: "Unknown asset type"))
                return operation
            }
            beginLoad(type: type, path: strings[1], operation: operation)
        case "saveAsync":
            guard strings.count == 2,
                  let asset = handlesLock.withLock({ handles.values.first(where: { $0.assetPath == strings[0] })?.untypedAsset }) else {
                operation.complete(.failure("unknownAsset", message: "Cannot save an unloaded asset"))
                return operation
            }
            let path = strings[1]
            let scopeID = AppWorldsExecutionContext.currentID
            operation.cancellationIsAdvisory = true
            let task = Task {
                do {
                    try Task.checkCancellation()
                    try await AppWorldsExecutionContext.$currentID.withValue(scopeID) {
                        func saveOpened<A: Asset>(_ opened: A) async throws {
                            try await AssetsManager.save(opened, at: path)
                        }
                        try await saveOpened(asset)
                    }
                    operation.complete(.success(path, committed: true))
                } catch {
                    operation.complete(.failure("saveFailed", message: error.localizedDescription))
                }
            }
            operation.installCancellationAction { task.cancel() }
        default:
            operation.complete(.failure("unknownOperation", message: "Unknown async Assets operation"))
        }
        return operation
    }

    @GSExportableIgnore
    private func beginLoad(type: any Asset.Type, path: String, operation: AdaScriptAsyncOperation) {
        let cacheKey = String(reflecting: type) + "\u{0}" + path
        if handlesLock.withLock({ handles[cacheKey] != nil }) {
            operation.complete(.success(path))
            return
        }
        let scopeID = AppWorldsExecutionContext.currentID
        let task = Task {
            do {
                try Task.checkCancellation()
                let handle = try await AppWorldsExecutionContext.$currentID.withValue(scopeID) {
                    try await AssetsManager.loadErased(type, at: path, handleChanges: true)
                }
                try Task.checkCancellation()
                handlesLock.withLock { handles[cacheKey] = handle }
                operation.complete(.success(path))
            } catch {
                operation.complete(.failure("loadFailed", message: error.localizedDescription))
            }
        }
        operation.installCancellationAction { task.cancel() }
    }

    @GSExportableIgnore
    private func store(reference: String, path: String) -> Bool {
        guard let asset = handlesLock.withLock({ handles.values.first(where: { $0.assetPath == reference })?.untypedAsset }) else {
            reportDiagnostic("Cannot save unloaded AdaScript asset '\(reference)'")
            return false
        }
        #if WASM
            reportDiagnostic("Assets.save is not available in the current WebAssembly filesystem")
            return false
        #else
            do {
                try AssetsManager.saveErasedSync(asset, at: path)
                return true
            } catch {
                reportDiagnostic("Cannot save AdaScript asset to '\(path)': \(error)")
                return false
            }
        #endif
    }

    @GSExportableIgnore
    private func resolve(_ path: String, handleChanges: Bool) -> String {
        guard let type = AssetsManager.inferAssetType(at: path) else {
            let message = "Cannot infer a unique asset type for '\(path)'"
            reportDiagnostic(message)
            return ""
        }
        return resolve(type: type, path: path, handleChanges: handleChanges)
    }

    @GSExportableIgnore
    private func resolve(typeName: String, path: String, handleChanges: Bool) -> String {
        guard let type = AssetsManager.getAssetType(named: typeName) else {
            reportDiagnostic("Unknown AdaScript asset type '\(typeName)'")
            return ""
        }
        return resolve(type: type, path: path, handleChanges: handleChanges)
    }

    @GSExportableIgnore
    private func resolve(
        type: any Asset.Type,
        path: String,
        handleChanges: Bool
    ) -> String {
        let typeName = String(reflecting: type)
        let cacheKey = typeName + "\u{0}" + path
        if handlesLock.withLock({ handles[cacheKey] != nil }) {
            return path
        }
        #if WASM
            reportDiagnostic("Runtime Assets.load requires preloaded web assets on WebAssembly: '\(path)'")
            return ""
        #else
            do {
                let handle = try AssetsManager.loadErasedSync(type, at: path, handleChanges: handleChanges)
                handlesLock.withLock { handles[cacheKey] = handle }
                return path
            } catch {
                reportDiagnostic("Cannot load AdaScript asset '\(path)': \(error)")
                return ""
            }
        #endif
    }
}

enum AdaScriptAssetRuntime {
    static func bind(
        to virtualMachine: GravityVirtualMachine,
        reportDiagnostic: @escaping @Sendable (String) -> Void,
        wake: (@Sendable () -> Void)? = nil
    ) throws {
        try virtualMachine.bindClass(with: AdaScriptAssetsBridge.self)
        let bridge = AdaScriptAssetsBridge.make(reportDiagnostic: reportDiagnostic)
        bridge.onWake = wake
        virtualMachine.setValue(bridge, forKey: "__adaAssets")
    }
}
