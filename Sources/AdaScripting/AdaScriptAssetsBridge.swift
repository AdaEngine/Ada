import AdaAssets
import Gravity

/// Synchronous VM facade. AdaAssets keeps the actual typed handle and cache identity.
@GSExportable("AdaAssets")
final class AdaScriptAssetsBridge: @unchecked Sendable {
    @GSExportableIgnore
    private var reportDiagnostic: @Sendable (String) -> Void = { _ in }

    @GSExportableIgnore
    private var handles: [String: any AnyAssetHandleInfo] = [:]

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
            guard let path = strings.first else { return "" }
            return resolve(path, handleChanges: true)
        case "loadTyped":
            guard strings.count == 2 else { return "" }
            return resolve(typeName: strings[0], path: strings[1], handleChanges: true)
        case "save":
            guard strings.count == 2 else { return "" }
            return store(reference: strings[0], path: strings[1]) ? strings[0] : ""
        default:
            reportDiagnostic("Unknown AdaScript Assets operation '\(operation.toString)'")
            return ""
        }
    }

    @GSExportableIgnore
    private func store(reference: String, path: String) -> Bool {
        guard let handle = handles.values.first(where: { $0.assetPath == reference }), let asset = handle.untypedAsset else {
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
        if handles[cacheKey] != nil {
            return path
        }
        #if WASM
            reportDiagnostic("Runtime Assets.load requires preloaded web assets on WebAssembly: '\(path)'")
            return ""
        #else
            do {
                let handle = try AssetsManager.loadErasedSync(type, at: path, handleChanges: handleChanges)
                handles[cacheKey] = handle
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
        reportDiagnostic: @escaping @Sendable (String) -> Void
    ) throws {
        try virtualMachine.bindClass(with: AdaScriptAssetsBridge.self)
        virtualMachine.setValue(
            AdaScriptAssetsBridge.make(reportDiagnostic: reportDiagnostic),
            forKey: "__adaAssets"
        )
    }
}
