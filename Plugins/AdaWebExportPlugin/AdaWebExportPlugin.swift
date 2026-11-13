//
//  AdaWebExportPlugin.swift
//  AdaEngine
//

import Foundation
import PackagePlugin

@main
struct AdaWebExportPlugin: CommandPlugin {
    // Runtime files belong to the plugin package, including when used by a dependent game.
    private static var assetsDirectory: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent() }
    private static let renderBundle = "AdaEngine_AdaRender.resources"
    private static let flat3DBundle = "AdaEngine_AdaCorePipelines.resources"
    private static let flat3DVariants = [["ADA_TERRAIN"], ["ADA_WIREFRAME"], ["ADA_TERRAIN", "ADA_WIREFRAME"]]

    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let options: ExportOptions
        do {
            options = try ExportOptions(arguments: arguments, packageDirectory: context.package.directoryURL)
        } catch ExportError.help {
            FileHandle.standardOutput.write(Data(ExportError.help.description.utf8))
            FileHandle.standardOutput.write(Data("\n".utf8))
            return
        }
        let wasiRuntime = Self.assetsDirectory.appendingPathComponent("BrowserWASIShim/dist/index.js")
        guard FileManager.default.fileExists(atPath: wasiRuntime.path) else {
            throw ExportError.browserWASIRuntimeNotFound
        }
        let sdk = try options.swiftSDK ?? detectWasmSDK()
        // Bundle.module embeds this absolute path. Use the same canonical spelling
        // as the resource manifest (notably /tmp versus /private/tmp on macOS).
        let buildDirectory = (options.scratchDirectory ?? context.package.directoryURL.appending(
            component: ".build-web-\(options.product)",
            directoryHint: .isDirectory
        )).resolvingSymlinksInPath().standardizedFileURL
        let sharedBuild = context.package.directoryURL.appending(component: ".build").resolvingSymlinksInPath().standardizedFileURL
        guard buildDirectory.resolvingSymlinksInPath().standardizedFileURL != sharedBuild else {
            throw ExportError.unsafeScratchDirectory
        }
        try FileManager.default.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
        try detachLegacyDependencyLinks(in: buildDirectory)
        try restorePortableDependencyPatches(in: buildDirectory)
        // Resolve first so platform-compatibility patches run on actual private
        // checkouts, including a cold scratch directory with no Yams checkout.
        try run(
            executable: "/usr/bin/env",
            arguments: ["swift", "package", "resolve", "--scratch-path", buildDirectory.path(percentEncoded: false), "--disable-sandbox", "--disable-keychain"],
            workingDirectory: context.package.directoryURL
        )
        try prepareDependenciesForWASI(in: buildDirectory)

        Diagnostics.remark("Building \(options.product) for WebAssembly with Swift SDK \(sdk)")
        try run(
            executable: "/usr/bin/env",
            arguments: [
                "swift",
                "build",
                "--scratch-path",
                buildDirectory.path(percentEncoded: false),
                "--disable-sandbox",
                "--skip-update",
                "--disable-build-manifest-caching",
                "--disable-keychain",
                "--disable-experimental-prebuilts",
                "--disable-index-store",
                "-j", "4",
                "--product",
                options.product,
                "--swift-sdk",
                sdk,
                "-c",
                options.configuration.rawValue,
                "-Xcc",
                "-DHAVE_UNISTD_H=1",
                "-Xcc",
                "-include",
                "-Xcc",
                Self.assetsDirectory.appending(
                    components: "Compatibility", "AdaScriptWASI.h"
                ).path(percentEncoded: false)
            ],
            workingDirectory: context.package.directoryURL
        )

        let wasm = try findBuiltWasm(
            product: options.product,
            configuration: options.configuration,
            buildDirectory: buildDirectory
        )

        try exportBundle(
            wasm: wasm,
            options: options,
            package: context.package,
            packageDirectory: context.package.directoryURL,
            checkouts: buildDirectory.appending(component: "checkouts"),
            shaderTranspiler: try context.tool(named: "AdaShaderTranspilerTool").url
        )

        Diagnostics.remark("Exported AdaEngine web app to \(options.outputDirectory.path(percentEncoded: false))")

        if options.serve {
            try serve(directory: options.outputDirectory)
        }
    }

    /// Copies the JavaScript host from the package that provides the Swift host.
    private func copySAGAWebHost(package: Package, to output: URL) throws {
        guard let saga = sagaWebHostPackage(in: package) else {
            throw ExportError.sagaWebHostNotResolved
        }
        let host = saga.directoryURL.appending(components: "web", "webgpu.mjs")
        guard FileManager.default.fileExists(atPath: host.path(percentEncoded: false)) else {
            throw ExportError.sagaWebHostAssetMissing(host.path(percentEncoded: false))
        }
        try replaceItem(at: output.appending(component: "saga-webgpu.mjs"), with: host)
        let golden = saga.directoryURL.appending(components: "web", "golden.mjs")
        if FileManager.default.fileExists(atPath: golden.path(percentEncoded: false)) {
            try replaceItem(at: output.appending(component: "saga-golden.mjs"), with: golden)
        }
    }

    private func sagaWebHostPackage(in root: Package) -> Package? {
        // A game depends on AdaEngine directly and SAGA transitively.
        var pending = [root]
        var visited: Set<URL> = []
        while let package = pending.popLast() {
            guard visited.insert(package.directoryURL).inserted else { continue }
            if package.products.contains(where: { $0.name == "SAGAWebHost" }) {
                return package
            }
            pending.append(contentsOf: package.dependencies.reversed().map(\.package))
        }
        return nil
    }

    private func detectWasmSDK() throws -> String {
        let output = try capture(
            executable: "/usr/bin/env",
            arguments: ["swift", "sdk", "list"],
            workingDirectory: nil
        )

        if let sdk = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .flatMap({ line -> [String] in
                line.split(whereSeparator: \.isWhitespace).map(String.init)
            })
            .first(where: { $0.contains("_wasm") && !$0.contains("embedded") })
        {
            return sdk
        }

        throw ExportError.missingWasmSDK("""
        No Swift WebAssembly SDK was found.

        Install a Swift toolchain and matching WASM SDK, then retry. Swift.org documents the current flow here:
        https://www.swift.org/documentation/articles/wasm-getting-started.html

        You can also pass an explicit SDK id:
        swift package plugin --allow-writing-to-package-directory --allow-network-connections all export-web --product <ProductName> --swift-sdk <sdk-id>
        """)
    }

    private func findBuiltWasm(
        product: String,
        configuration: ExportOptions.Configuration,
        buildDirectory: URL
    ) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(
            at: buildDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ExportError.wasmNotFound(product, buildDirectory.path(percentEncoded: false))
        }

        let candidates = enumerator.compactMap { item -> URL? in
            guard let url = item as? URL else {
                return nil
            }
            guard url.lastPathComponent == "\(product).wasm" else {
                return nil
            }
            guard url.pathComponents.contains(configuration.rawValue) else {
                return nil
            }
            return url
        }

        guard let wasm = candidates.sorted(by: { $0.path.count < $1.path.count }).last else {
            throw ExportError.wasmNotFound(product, buildDirectory.path(percentEncoded: false))
        }

        return wasm
    }

    private func detachLegacyDependencyLinks(in buildDirectory: URL) throws {
        let manager = FileManager.default
        let scratchPrefix = buildDirectory.path.hasSuffix("/") ? buildDirectory.path : buildDirectory.path + "/"
        for name in ["checkouts", "repositories"] {
            let link = buildDirectory.appendingPathComponent(name)
            guard let destination = try? manager.destinationOfSymbolicLink(atPath: link.path) else { continue }
            let target = destination.hasPrefix("/") ? URL(fileURLWithPath: destination) : buildDirectory.appendingPathComponent(destination)
            guard !target.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(scratchPrefix) else { continue }
            try manager.removeItem(at: link)
        }
    }

    private func prepareDependenciesForWASI(in buildDirectory: URL) throws {
        let fileManager = FileManager.default
        let checkouts = buildDirectory.appending(component: "checkouts", directoryHint: .isDirectory)
        let source = checkouts.appending(components: "Yams", "Sources", "Yams", "Representer.swift")
        guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else { return }
        let original = try String(contentsOf: source, encoding: .utf8)
        let expression = "String(format: \"%.*g\", DBL_DECIMAL_DIG, value)"

        // The pinned Yams formatter uses a C macro that Foundation does not export on WASI.
        // Double.significandBitCount is 52; IEEE binary64 round-trips with 17 decimal digits.
        // Older export scratch directories may still point to shared checkouts.
        let resolvedCheckouts = checkouts.resolvingSymlinksInPath().standardizedFileURL
        let scratchRoot = buildDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        if !resolvedCheckouts.path.hasPrefix(scratchRoot.hasSuffix("/") ? scratchRoot : scratchRoot + "/") {
            let temporary = buildDirectory.appending(component: "web-checkouts-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fileManager.copyItem(at: resolvedCheckouts, to: temporary)
            // Remove the symlink itself, not its shared destination.
            try fileManager.removeItem(at: checkouts)
            try fileManager.moveItem(at: temporary, to: checkouts)
        }
        let replacement = """
        String(format: "%.*g", Int32(ceil(1 + Double(Double.significandBitCount + 1) * log10(2))), value)
        """
        if original.contains(expression) {
            try original.replacingOccurrences(of: expression, with: replacement).write(to: source, atomically: true, encoding: .utf8)
            Diagnostics.remark("Applied portable floating-point precision to the isolated Yams web-build checkout")
        }
        let vmSource = checkouts.appending(components: "gravity-lang", "binding", "GravitySwift", "GravityVirtualMachine.swift")
        guard fileManager.fileExists(atPath: vmSource.path(percentEncoded: false)) else { return }
        let vmOriginal = try String(contentsOf: vmSource, encoding: .utf8)
        // Corelibs Foundation takes unsigned byte buffers, unlike Darwin's C-imported initializer.
        let vmUpdated = vmOriginal
            .replacingOccurrences(
                of: "OutputStream(toBuffer: buffer, capacity: data.count)",
                with: "OutputStream(toBuffer: UnsafeMutableRawPointer(buffer).assumingMemoryBound(to: UInt8.self), capacity: data.count)"
            )
            .replacingOccurrences(of: "let charPointer = pointer.bindMemory(to: CChar.self)", with: "let charPointer = pointer.bindMemory(to: UInt8.self)")
        if vmUpdated != vmOriginal {
            try vmUpdated.write(to: vmSource, atomically: true, encoding: .utf8)
            Diagnostics.remark("Applied Foundation byte-buffer compatibility to the isolated AdaScript VM checkout")
        }
    }

    /// SwiftPM refuses to resolve a checkout changed by the previous export's compatibility pass.
    /// Restore only this plugin's exact replacements, and only inside a private scratch directory.
    private func restorePortableDependencyPatches(in buildDirectory: URL) throws {
        let checkouts = buildDirectory.appending(component: "checkouts", directoryHint: .isDirectory)
        let base = buildDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard checkouts.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base) else { return }
        let replacements = [
            ("Yams/Sources/Yams/Representer.swift",
             "String(format: \"%.*g\", Int32(ceil(1 + Double(Double.significandBitCount + 1) * log10(2))), value)",
             "String(format: \"%.*g\", DBL_DECIMAL_DIG, value)"),
            ("gravity-lang/binding/GravitySwift/GravityVirtualMachine.swift",
             "OutputStream(toBuffer: UnsafeMutableRawPointer(buffer).assumingMemoryBound(to: UInt8.self), capacity: data.count)",
             "OutputStream(toBuffer: buffer, capacity: data.count)"),
            ("gravity-lang/binding/GravitySwift/GravityVirtualMachine.swift",
             "let charPointer = pointer.bindMemory(to: UInt8.self)", "let charPointer = pointer.bindMemory(to: CChar.self)")
        ]
        for (relative, patched, original) in replacements {
            let file = checkouts.appendingPathComponent(relative)
            guard file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base),
                  FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { continue }
            let content = try String(contentsOf: file, encoding: .utf8)
            guard content.contains(patched), let checkout = relative.split(separator: "/").first else { continue }
            let sourcePath = relative.split(separator: "/").dropFirst().joined(separator: "/")
            let checkoutPath = checkouts.appendingPathComponent(String(checkout)).path(percentEncoded: false)
            let committed = try capture(
                executable: "/usr/bin/env",
                arguments: ["git", "-C", checkoutPath, "show", "HEAD:" + sourcePath],
                workingDirectory: nil
            )
            if committed.contains(original) { try content.replacingOccurrences(of: patched, with: original).write(to: file, atomically: true, encoding: .utf8) }
        }
    }

    private func exportBundle(
        wasm: URL,
        options: ExportOptions,
        package: Package,
        packageDirectory: URL,
        checkouts: URL,
        shaderTranspiler: URL
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)

        let wasmOutput = options.outputDirectory.appending(component: "\(options.product).wasm", directoryHint: .notDirectory)
        try replaceItem(at: wasmOutput, with: wasm)

        try replaceItem(
            at: options.outputDirectory.appending(component: "engine-audio.js"),
            with: Self.assetsDirectory.appending(components: "Runtime", "engine-audio.js")
        )
        if options.product == "AdaWebPlayer" {
            try "{\"runtimeAPI\":4,\"profile\":\"universal\"}".write(
                to: options.outputDirectory.appending(component: "ada-web-player.json"),
                atomically: true,
                encoding: .utf8
            )
            try replaceItem(
                at: options.outputDirectory.appending(component: "player-audio.js"),
                with: Self.assetsDirectory.appending(components: "Runtime", "player-audio.js")
            )
            try replaceItem(
                at: options.outputDirectory.appending(component: "player-lobby.js"),
                with: Self.assetsDirectory.appending(components: "Runtime", "player-lobby.js")
            )
        }

        let resourceBundles = try copyResourceBundles(
            near: wasm,
            to: options.outputDirectory,
            packageName: package.displayName,
            requiredTargetNames: requiredTargetNames(forProductNamed: options.product, in: package)
        )
        var resourceManifest = try resourceBundles
            .flatMap { bundle in
                try manifestEntries(forResourceBundle: bundle)
            }
        let generatedShaders = try generateWGSLShaders(
            resourceBundles: resourceBundles,
            outputDirectory: options.outputDirectory,
            packageDirectory: packageDirectory,
            shaderTranspiler: shaderTranspiler,
            requiresAllShaders: ["AdaWebPlayer", "AdaNativeGame"].contains(options.product)
        )
        var graphBaker: URL?
        for bundle in resourceBundles {
            let roots = try regularFiles(in: bundle.destination)
                .filter { try WebExportSupport.needsShaderGraphBaker($0) }
                .compactMap { file -> URL? in
                    guard let range = file.path.range(of: "/GameAssets/") else { return nil }
                    return URL(fileURLWithPath: String(file.path[..<range.upperBound]))
                }
            for root in Set(roots) {
                let baker = try graphBaker ?? buildGraphBaker(packageDirectory: packageDirectory, scratch: options.scratchDirectory)
                graphBaker = baker
                _ = try WebExportSupport.captureStandardOutput(executable: baker.path, arguments: [root.path], workingDirectory: packageDirectory)
                let archive = root.appendingPathComponent("shaders.shadergraphlib")
                if fileManager.fileExists(atPath: archive.path) {
                    let relative = archive.relativePath(from: bundle.destination)
                    let path = bundle.source.appendingPathComponent(relative).path
                    resourceManifest.removeAll { $0.path == path }
                    resourceManifest.append(ResourceManifestEntry(
                        path: path,
                        url: browserRelativeURL(forRelativePath: archive.relativePath(from: options.outputDirectory))
                    ))
                }
            }
        }
        resourceManifest.append(contentsOf: generatedShaders)
        resourceManifest.sort { $0.path < $1.path }
        try writeResourceManifest(
            resourceManifest,
            to: options.outputDirectory.appending(component: "ada-resource-manifest.json", directoryHint: .notDirectory)
        )

        let assetsSource = packageDirectory.appending(component: "Assets", directoryHint: .isDirectory)
        let assetsDestination = options.outputDirectory.appending(component: "Assets", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: assetsSource.path(percentEncoded: false)) {
            if fileManager.fileExists(atPath: assetsDestination.path(percentEncoded: false)) {
                try fileManager.removeItem(at: assetsDestination)
            }
            try fileManager.copyItem(at: assetsSource, to: assetsDestination)
        }
        let runtime = try javascriptKitRuntime(checkouts: checkouts)
        try replaceItem(
            at: options.outputDirectory.appending(component: "runtime.mjs", directoryHint: .notDirectory),
            with: runtime
        )
        try replaceItem(
            at: options.outputDirectory.appending(component: "bridge-js.js", directoryHint: .notDirectory),
            with: Self.assetsDirectory.appending(components: "Runtime", "BridgeJSCache", "bridge-js.js")
        )
        try copyBrowserWASIShim(packageDirectory: packageDirectory, to: options.outputDirectory)
        try copySAGAWebHost(package: package, to: options.outputDirectory)
        try copyLoaderAssets(to: options.outputDirectory)

        try indexHTML(product: options.product).write(
            to: options.outputDirectory.appending(component: "index.html", directoryHint: .notDirectory),
            atomically: true,
            encoding: .utf8
        )
        try mainJS(product: options.product).write(
            to: options.outputDirectory.appending(component: "main.js", directoryHint: .notDirectory),
            atomically: true,
            encoding: .utf8
        )
        try packageJSON(product: options.product).write(
            to: options.outputDirectory.appending(component: "package.json", directoryHint: .notDirectory),
            atomically: true,
            encoding: .utf8
        )
        try manifestJSON(product: options.product).write(
            to: options.outputDirectory.appending(component: "ada-web-manifest.json", directoryHint: .notDirectory),
            atomically: true,
            encoding: .utf8
        )
    }

    private func copyLoaderAssets(to outputDirectory: URL) throws {
        let fileManager = FileManager.default
        let loaderAssetsDirectory = outputDirectory.appending(component: "loader-assets", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: loaderAssetsDirectory, withIntermediateDirectories: true)

        let logoSourceDirectory = Self.assetsDirectory.appendingPathComponent("LoaderAssets", isDirectory: true)
        for logoName in ["ae_logo.svg", "ae_logo~dark.svg"] {
            let source = logoSourceDirectory.appending(component: logoName, directoryHint: .notDirectory)
            try replaceItem(
                at: loaderAssetsDirectory.appending(component: logoName, directoryHint: .notDirectory),
                with: source
            )
        }
    }

    private func copyBrowserWASIShim(packageDirectory: URL, to outputDirectory: URL) throws {
        let fileManager = FileManager.default
        let shimSourceDirectory = Self.assetsDirectory.appending(
            components: "BrowserWASIShim",
            directoryHint: .isDirectory
        )
        let shimDestinationDirectory = outputDirectory.appending(component: "browser-wasi-shim", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: shimDestinationDirectory.path(percentEncoded: false)) {
            try fileManager.removeItem(at: shimDestinationDirectory)
        }
        try fileManager.copyItem(at: shimSourceDirectory, to: shimDestinationDirectory)
    }

    private func replaceItem(at destination: URL, with source: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private func copyResourceBundles(
        near wasm: URL,
        to outputDirectory: URL,
        packageName: String,
        requiredTargetNames: Set<String>
    ) throws -> [ResourceBundleExport] {
        let fileManager = FileManager.default
        let buildProductsDirectory = wasm.deletingLastPathComponent()
        let resourceBundles = try fileManager.contentsOfDirectory(
            at: buildProductsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            guard url.pathExtension == "resources" else {
                return false
            }
            let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey])
            return resourceValues?.isDirectory == true
                && requiredTargetNames.contains(resourceBundleTargetName(for: url, packageName: packageName))
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        let resourcesDirectory = outputDirectory.appending(component: "resources", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: resourcesDirectory.path(percentEncoded: false)) {
            try fileManager.removeItem(at: resourcesDirectory)
        }
        try fileManager.createDirectory(at: resourcesDirectory, withIntermediateDirectories: true)

        var exportedBundles: [ResourceBundleExport] = []
        for source in resourceBundles {
            let destination = resourcesDirectory.appending(component: source.lastPathComponent, directoryHint: .isDirectory)
            if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
            exportedBundles.append(ResourceBundleExport(source: source, destination: destination))
        }

        return exportedBundles
    }

    /// Build the CPU baker for the host outside the WASM build environment.
    private func buildGraphBaker(packageDirectory: URL, scratch: URL?) throws -> URL {
        let engine = Self.assetsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let cache = (scratch ?? packageDirectory.appendingPathComponent(".build-web-export"))
            .appendingPathComponent("shader-graph-host")
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "BUILD_WASM")
        environment["ADAENGINE_DISABLE_SWAN"] = "1"
        environment["ADAENGINE_WEB_EXPORT"] = "1"
        let arguments = ["swift", "build", "--package-path", engine.path, "--scratch-path", cache.path, "--disable-sandbox"]
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        build.arguments = arguments + ["--product", "AdaShaderGraphBaker", "--jobs", "4"]
        build.environment = environment
        build.standardOutput = FileHandle.standardError
        build.standardError = FileHandle.standardError
        try build.run()
        build.waitUntilExit()
        guard build.terminationStatus == 0 else { throw ExportError.commandFailed("Shader Graph host baker build failed", build.terminationStatus) }
        let query = Process()
        query.executableURL = build.executableURL
        query.arguments = arguments + ["--show-bin-path"]
        query.environment = environment
        let output = Pipe()
        query.standardOutput = output
        try query.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        query.waitUntilExit()
        guard query.terminationStatus == 0 else { throw ExportError.commandFailed("Shader Graph host baker path unavailable", query.terminationStatus) }
        let directory = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: directory).appendingPathComponent("AdaShaderGraphBaker")
    }

    private func generateWGSLShaders(
        resourceBundles: [ResourceBundleExport],
        outputDirectory: URL,
        packageDirectory: URL,
        shaderTranspiler: URL,
        requiresAllShaders: Bool
    ) throws -> [ResourceManifestEntry] {
        let files: [URL] = try resourceBundles.flatMap { try regularFiles(in: $0.source) }
        let shaders = files.filter { file in
            switch file.pathExtension {
            case "wesl": true
            case "glsl": containsShaderStagePragma(file)
            default: false
            }
        }
        let shaderURLs = shaders.sorted { $0.path(percentEncoded: false) < $1.path(percentEncoded: false) }
        guard !shaderURLs.isEmpty else {
            Diagnostics.remark("No shader resources need WGSL generation")
            return []
        }

        let moduleIncludeArguments = shaderModuleIncludeArguments(
            resourceBundles: resourceBundles,
            packageDirectory: packageDirectory
        )

        let weslDependencies = shaderLibrary("WESL", resourceBundles: resourceBundles, packageDirectory: packageDirectory)
            .map { ["--wesl-dependency", "ada_engine=\($0.path(percentEncoded: false))"] } ?? []

        var entries: [ResourceManifestEntry] = []
        for shaderURL in shaderURLs {
            guard let resourceBundle = resourceBundles.first(where: { shaderURL.isDescendant(of: $0.source) }) else {
                continue
            }
            let shaderOutputDirectory = outputURL(forResourceURL: shaderURL, in: resourceBundle).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: shaderOutputDirectory, withIntermediateDirectories: true)

            var arguments = [
                "--input",
                shaderURL.path(percentEncoded: false),
                "--output-directory",
                shaderOutputDirectory.path(percentEncoded: false)
            ]
            if shaderURL.pathExtension == "wesl" {
                arguments.append("--web-stages")
                arguments.append(contentsOf: weslDependencies)
            } else {
                arguments.append(contentsOf: moduleIncludeArguments)
            }

            let variants: [[String]]
            if resourceBundle.source.lastPathComponent == Self.flat3DBundle {
                variants = switch shaderURL.relativePath(from: resourceBundle.source) {
                case "Shaders/flat3d.glsl": Self.flat3DVariants
                case "Shaders/directional_shadow_3d.wesl", "Shaders/motion_3d.wesl": [["ADA_MORPH"]]
                case "Shaders/meshlet_map_3d.wesl": [["MAP_RESPONSE"], ["MAP_SURFACE"], ["MAP_RESPONSE", "MAP_SURFACE"]]
                default: []
                }
            } else {
                variants = []
            }
            let variantFlag = shaderURL.pathExtension == "wesl" ? "--feature" : "--define"
            for defines in [[]] + variants {
                do {
                    let generatedOutput = try WebExportSupport.captureStandardOutput(
                        executable: shaderTranspiler.path(percentEncoded: false),
                        arguments: arguments + defines.flatMap { [variantFlag, $0] },
                        workingDirectory: packageDirectory
                    )
                    let generatedEntries = generatedOutput
                        .split(whereSeparator: \.isNewline)
                        .map(String.init)
                        .compactMap { outputPath -> ResourceManifestEntry? in
                            let outputURL = URL(fileURLWithPath: outputPath)
                            guard FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)) else {
                                return nil
                            }
                            let absoluteBuildURL = shaderURL
                                .deletingLastPathComponent()
                                .appending(component: outputURL.lastPathComponent, directoryHint: .notDirectory)
                            return ResourceManifestEntry(
                                path: absoluteBuildURL.path(percentEncoded: false),
                                // The WGSL exists in the export, not in the SwiftPM resource bundle.
                                url: browserRelativeURL(forRelativePath: outputURL.relativePath(from: outputDirectory))
                            )
                        }
                    entries.append(contentsOf: generatedEntries)
                } catch {
                    if requiresAllShaders || !defines.isEmpty { throw error }
                    Diagnostics.warning("Skipping WGSL generation for \(shaderURL.lastPathComponent): \(error)")
                }
            }
        }

        Diagnostics.remark("Generated \(entries.count) WGSL shader resources with SAGACompiler")
        return entries
    }

    private func containsShaderStagePragma(_ url: URL) -> Bool {
        guard let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)),
              let source = String(data: data, encoding: .utf8) else {
            return false
        }

        return source.contains("#pragma stage")
    }

    private func regularFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey])
            if resourceValues.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }

    private func shaderModuleIncludeArguments(resourceBundles: [ResourceBundleExport], packageDirectory: URL) -> [String] {
        shaderLibrary("Public", resourceBundles: resourceBundles, packageDirectory: packageDirectory)
            .map { ["--module-include", "AdaEngine=\($0.path(percentEncoded: false))"] } ?? []
    }

    private func shaderLibrary(_ folder: String, resourceBundles: [ResourceBundleExport], packageDirectory: URL) -> URL? {
        let bundled = resourceBundles.first { $0.source.lastPathComponent == Self.renderBundle }?
            .source.appending(components: "Shaders", folder, directoryHint: .isDirectory)
        let candidates = [
            bundled,
            packageDirectory.appending(
                components: "Sources", "AdaRender", "Assets", "Shaders", folder,
                directoryHint: .isDirectory
            )
        ]
        return candidates.compactMap { $0 }.first(where: { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) })
    }

    private func manifestEntries(forResourceBundle bundle: ResourceBundleExport) throws -> [ResourceManifestEntry] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: bundle.source,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var entries: [ResourceManifestEntry] = []
        for item in enumerator {
            guard let url = item as? URL else {
                continue
            }
            let resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues.isRegularFile == true else {
                continue
            }
            entries.append(
                ResourceManifestEntry(
                    path: url.path(percentEncoded: false),
                    url: browserRelativeURL(forResourceURL: url, in: bundle)
                )
            )
        }
        return entries
    }

    private func writeResourceManifest(_ manifest: [ResourceManifestEntry], to output: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: output, options: [.atomic])
    }

    private func outputURL(forResourceURL url: URL, in bundle: ResourceBundleExport) -> URL {
        let relativePath = url.relativePath(from: bundle.source)
        return relativePath
            .components(separatedBy: "/")
            .filter { !$0.isEmpty }
            .reduce(bundle.destination) { partialResult, component in
                partialResult.appending(component: component, directoryHint: .notDirectory)
            }
    }

    private func browserRelativeURL(forResourceURL url: URL, in bundle: ResourceBundleExport) -> String {
        browserRelativeURL(forRelativePath: "resources/\(bundle.destination.lastPathComponent)/\(url.relativePath(from: bundle.source))")
    }

    private func browserRelativeURL(forRelativePath relativePath: String) -> String {
        let allowedCharacters = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))
        return "./" + relativePath
            .components(separatedBy: "/")
            .map { component in
                component.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? component
            }
            .joined(separator: "/")
    }

    private func requiredTargetNames(forProductNamed productName: String, in package: Package) -> Set<String> {
        guard let product = package.products.first(where: { $0.name == productName }) else {
            return [productName]
        }

        var names: Set<String> = []
        var stack = product.targets
        while let target = stack.popLast() {
            guard names.insert(target.name).inserted else {
                continue
            }

            for dependency in target.dependencies {
                switch dependency {
                case .target(let target):
                    stack.append(target)
                case .product(let product):
                    stack.append(contentsOf: product.targets)
                @unknown default:
                    continue
                }
            }
        }

        return names
    }

    private func resourceBundleTargetName(for bundle: URL, packageName: String) -> String {
        let bundleName = bundle.deletingPathExtension().lastPathComponent
        let packagePrefix = "\(packageName)_"
        if bundleName.hasPrefix(packagePrefix) {
            return String(bundleName.dropFirst(packagePrefix.count))
        }

        return bundleName.split(separator: "_").last.map(String.init) ?? bundleName
    }

    private func javascriptKitRuntime(checkouts: URL) throws -> URL {
        let candidates = [
            checkouts.appending(
                components: "JavaScriptKit", "Plugins", "PackageToJS", "Templates", "runtime.mjs",
                directoryHint: .notDirectory
            ),
            checkouts.appending(
                components: "javascriptkit", "Plugins", "PackageToJS", "Templates", "runtime.mjs",
                directoryHint: .notDirectory
            )
        ]
        if let runtime = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }) {
            return runtime
        }
        throw ExportError.javascriptKitRuntimeNotFound
    }

    private func serve(directory: URL) throws {
        Diagnostics.remark("Serving \(directory.path(percentEncoded: false)) at http://127.0.0.1:8080")
        try run(
            executable: "/usr/bin/env",
            arguments: ["python3", "-m", "http.server", "8080", "--directory", directory.path(percentEncoded: false)],
            workingDirectory: directory
        )
    }

    private func run(executable: String, arguments: [String], workingDirectory: URL?) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = ProcessInfo.processInfo.environment.merging([
            "ADAENGINE_WEB_EXPORT": "1",
            "BUILD_WASM": "1"
        ]) { _, new in new }
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ExportError.commandFailed(arguments.joined(separator: " "), process.terminationStatus)
        }
    }

    private func capture(executable: String, arguments: [String], workingDirectory: URL?) throws -> String {
        let process = Process()
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("ada-web-command-" + UUID().uuidString)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        try process.run()
        process.waitUntilExit()
        let data = try Data(contentsOf: outputURL)
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ExportError.commandFailed(arguments.joined(separator: " "), process.terminationStatus)
        }
        return output
    }

}

private struct ExportOptions {
    enum Configuration: String {
        case debug
        case release
    }

    let product: String
    let outputDirectory: URL
    let scratchDirectory: URL?
    let swiftSDK: String?
    let configuration: Configuration
    let serve: Bool

    init(arguments: [String], packageDirectory: URL) throws {
        var product: String?
        var outputDirectory = packageDirectory.appending(components: "dist", "web", directoryHint: .isDirectory)
        var scratchDirectory: URL?
        var swiftSDK: String?
        var configuration = Configuration.release
        var serve = false

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--target", "--product":
                index += 1
                guard index < arguments.count else {
                    throw ExportError.missingValue(argument)
                }
                product = arguments[index]
            case "--output":
                index += 1
                guard index < arguments.count else {
                    throw ExportError.missingValue(argument)
                }
                outputDirectory = URL(fileURLWithPath: arguments[index], relativeTo: packageDirectory)
                    .standardizedFileURL
            case "--scratch-path":
                index += 1
                guard index < arguments.count else {
                    throw ExportError.missingValue(argument)
                }
                scratchDirectory = URL(fileURLWithPath: arguments[index], relativeTo: packageDirectory)
                    .standardizedFileURL
            case "--swift-sdk":
                index += 1
                guard index < arguments.count else {
                    throw ExportError.missingValue(argument)
                }
                swiftSDK = arguments[index]
            case "--debug":
                configuration = .debug
            case "--release":
                configuration = .release
            case "--serve":
                serve = true
            case "--help", "-h":
                throw ExportError.help
            default:
                throw ExportError.unknownArgument(argument)
            }

            index += 1
        }

        guard let product else {
            throw ExportError.missingTarget
        }

        self.product = product
        self.outputDirectory = outputDirectory
        self.scratchDirectory = scratchDirectory
        self.swiftSDK = swiftSDK
        self.configuration = configuration
        self.serve = serve
    }
}

private struct ResourceManifestEntry: Encodable {
    let path: String
    let url: String
}

private struct ResourceBundleExport {
    let source: URL
    let destination: URL
}

private extension URL {
    func isDescendant(of directory: URL) -> Bool {
        let directoryPath = directory.normalizedPath
        let path = normalizedPath
        return path == directoryPath || path.hasPrefix(directoryPath + "/")
    }

    func relativePath(from directory: URL) -> String {
        let directoryPath = directory.normalizedPath
        let path = normalizedPath
        guard path.hasPrefix(directoryPath + "/") else {
            return lastPathComponent
        }

        return String(path.dropFirst(directoryPath.count + 1))
    }

    var normalizedPath: String {
        var path = resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}

private enum ExportError: LocalizedError, CustomStringConvertible {
    case help
    case missingTarget
    case missingValue(String)
    case missingWasmSDK(String)
    case unknownArgument(String)
    case commandFailed(String, Int32)
    case wasmNotFound(String, String)
    case javascriptKitRuntimeNotFound
    case unsafeScratchDirectory
    case browserWASIRuntimeNotFound
    case sagaWebHostNotResolved
    case sagaWebHostAssetMissing(String)

    var errorDescription: String? {
        description
    }

    var description: String {
        switch self {
        case .help:
            return """
            Usage:
              swift package plugin --allow-writing-to-package-directory --allow-network-connections all export-web --product <ProductName> [--output dist/web] [--scratch-path .build-web-ProductName] [--swift-sdk <sdk-id>] [--debug|--release] [--serve]
            """
        case .unsafeScratchDirectory:
            return "Web export requires an isolated --scratch-path; the shared .build directory cannot be used."
        case .browserWASIRuntimeNotFound:
            return "Web export is missing BrowserWASIShim/dist/index.js. Restore the bundled WASI runtime modules from the engine repository."
        case .sagaWebHostNotResolved:
            return "Web export requires a SAGA dependency that provides the SAGAWebHost product."
        case .sagaWebHostAssetMissing(let path):
            return "The resolved SAGAWebHost package is missing a browser asset at \(path). Use a SAGA revision that ships the matching browser host."
        case .missingTarget:
            return "Missing required --product <ProductName> argument."
        case .missingValue(let argument):
            return "Missing value for \(argument)."
        case .missingWasmSDK(let message):
            return message
        case .unknownArgument(let argument):
            return "Unknown argument: \(argument)"
        case .commandFailed(let command, let status):
            return "Command failed with exit code \(status): \(command)"
        case .wasmNotFound(let product, let buildDirectory):
            return "Could not find built \(product).wasm under \(buildDirectory)."
        case .javascriptKitRuntimeNotFound:
            return "Could not find JavaScriptKit runtime.mjs under .build/checkouts/JavaScriptKit."
        }
    }
}

private func indexHTML(product: String) -> String {
    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>\(product)</title>
      <style>
        :root {
          color-scheme: light dark;
          --ada-loader-background: radial-gradient(circle at 50% 35%, #f8fafc 0, #e7ecf5 42%, #cdd6e6 100%);
          --ada-loader-card: rgba(255, 255, 255, 0.74);
          --ada-loader-text: #111827;
          --ada-loader-muted: #5b6473;
          --ada-loader-track: rgba(17, 24, 39, 0.13);
          --ada-loader-progress: linear-gradient(90deg, #1d4ed8, #7c3aed, #06b6d4);
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --ada-loader-background: radial-gradient(circle at 50% 35%, #242635 0, #12131b 48%, #07080d 100%);
            --ada-loader-card: rgba(14, 16, 24, 0.72);
            --ada-loader-text: #f8fafc;
            --ada-loader-muted: #a9b0bf;
            --ada-loader-track: rgba(255, 255, 255, 0.14);
            --ada-loader-progress: linear-gradient(90deg, #60a5fa, #a78bfa, #22d3ee);
          }
        }
        html, body, #ada-canvas-root {
          width: 100%;
          height: 100%;
          margin: 0;
          overflow: hidden;
          background: #101014;
        }
        body {
          font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        }
        canvas {
          width: 100%;
          height: 100%;
          outline: none;
        }
        #ada-canvas-root {
          position: fixed;
          inset: 0;
        }
        #ada-loader {
          position: fixed;
          inset: 0;
          z-index: 2147483647;
          display: grid;
          place-items: center;
          background: var(--ada-loader-background);
          color: var(--ada-loader-text);
          transition: opacity 260ms ease, visibility 260ms ease;
        }
        #ada-loader[data-state="hidden"] {
          opacity: 0;
          visibility: hidden;
          pointer-events: none;
        }
        .ada-loader-card {
          width: min(360px, calc(100vw - 48px));
          padding: 32px 30px 28px;
          border: 1px solid rgba(128, 140, 160, 0.2);
          border-radius: 28px;
          background: var(--ada-loader-card);
          box-shadow: 0 22px 70px rgba(0, 0, 0, 0.22);
          text-align: center;
          -webkit-backdrop-filter: blur(24px);
          backdrop-filter: blur(24px);
        }
        .ada-loader-logo {
          width: 116px;
          height: auto;
          margin-bottom: 22px;
          filter: drop-shadow(0 12px 24px rgba(0, 0, 0, 0.18));
        }
        .ada-loader-title {
          margin: 0;
          font-size: 18px;
          font-weight: 700;
          letter-spacing: 0.02em;
        }
        .ada-loader-status {
          min-height: 20px;
          margin: 8px 0 22px;
          color: var(--ada-loader-muted);
          font-size: 13px;
          line-height: 20px;
        }
        .ada-loader-progress-track {
          position: relative;
          height: 8px;
          overflow: hidden;
          border-radius: 999px;
          background: var(--ada-loader-track);
        }
        .ada-loader-progress-bar {
          width: 8%;
          height: 100%;
          border-radius: inherit;
          background: var(--ada-loader-progress);
          box-shadow: 0 0 22px rgba(96, 165, 250, 0.45);
          transition: width 180ms ease;
        }
        .ada-loader-progress-bar[data-indeterminate="true"] {
          position: absolute;
          width: 42%;
          animation: ada-loader-slide 1.15s ease-in-out infinite;
        }
        .ada-loader-percent {
          margin-top: 12px;
          color: var(--ada-loader-muted);
          font-size: 12px;
          font-variant-numeric: tabular-nums;
        }
        #ada-loader[data-state="error"] .ada-loader-progress-bar {
          width: 100%;
          background: linear-gradient(90deg, #ef4444, #f97316);
          animation: none;
        }
        @keyframes ada-loader-slide {
          0% { transform: translateX(-110%); }
          50% { transform: translateX(45%); }
          100% { transform: translateX(240%); }
        }
        @media (prefers-reduced-motion: reduce) {
          #ada-loader, .ada-loader-progress-bar {
            transition: none;
            animation: none;
          }
        }
      </style>
    </head>
    <body>
      <div id="ada-canvas-root"></div>
      <div id="ada-loader" role="status" aria-live="polite" aria-label="Loading \(product)">
        <div class="ada-loader-card">
          <picture>
            <source srcset="./loader-assets/ae_logo~dark.svg" media="(prefers-color-scheme: dark)">
            <img class="ada-loader-logo" src="./loader-assets/ae_logo.svg" alt="AdaEngine">
          </picture>
          <h1 class="ada-loader-title">\(product)</h1>
          <div id="ada-loader-status" class="ada-loader-status">Preparing WebAssembly…</div>
          <div class="ada-loader-progress-track" aria-hidden="true">
            <div id="ada-loader-progress" class="ada-loader-progress-bar" data-indeterminate="true"></div>
          </div>
          <div id="ada-loader-percent" class="ada-loader-percent">0%</div>
        </div>
      </div>
      <script type="module" src="\(product == "AdaWebPlayer" ? "./player-lobby.js" : "./main.js")"></script>
    </body>
    </html>
    """
}

private func mainJS(product: String) -> String {
    """
    import './engine-audio.js';
    \(product == "AdaWebPlayer" ? "import './player-audio.js';" : "")
    import { WASI, File, OpenFile, ConsoleStdout, PreopenDirectory, Directory } from "./browser-wasi-shim/dist/index.js";
    import { createInstantiator } from "./bridge-js.js";
    import { SwiftRuntime } from "./runtime.mjs";

    const loader = document.getElementById("ada-loader");
    const loaderStatus = document.getElementById("ada-loader-status");
    const loaderProgress = document.getElementById("ada-loader-progress");
    const loaderPercent = document.getElementById("ada-loader-percent");
    let lastProgress = 0;

    function updateLoader(progress, status, options = {}) {
      const nextProgress = Math.max(lastProgress, Math.min(100, Math.round(progress)));
      lastProgress = nextProgress;
      if (loaderStatus && status) loaderStatus.textContent = status;
      if (loaderProgress) {
        loaderProgress.dataset.indeterminate = options.indeterminate ? "true" : "false";
        loaderProgress.style.width = `${Math.max(4, nextProgress)}%`;
      }
      if (loaderPercent) loaderPercent.textContent = `${nextProgress}%`;
    }

    function hideLoader() {
      updateLoader(100, "Launching…");
      requestAnimationFrame(() => {
        loader?.setAttribute("data-state", "hidden");
        setTimeout(() => loader?.remove(), 320);
      });
    }

    function failLoader(error) {
      console.error(error);
      loader?.setAttribute("data-state", "error");
      updateLoader(100, `Unable to start: ${error instanceof Error ? error.message : String(error)}`);
    }

    async function fetchArrayBufferWithProgress(url, start, end, status) {
      const response = await fetch(url);
      if (!response.ok) {
        throw new Error(`Failed to fetch ${url}: ${response.status} ${response.statusText}`);
      }

      const contentLength = Number(response.headers.get("content-length"));
      if (!response.body || !Number.isFinite(contentLength) || contentLength <= 0) {
        updateLoader(start, status, { indeterminate: true });
        const buffer = await response.arrayBuffer();
        updateLoader(end, status);
        return buffer;
      }

      const reader = response.body.getReader();
      const chunks = [];
      let received = 0;
      updateLoader(start, status);
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        chunks.push(value);
        received += value.byteLength;
        updateLoader(start + ((end - start) * received / contentLength), status);
      }

      const bytes = new Uint8Array(received);
      let offset = 0;
      for (const chunk of chunks) {
        bytes.set(chunk, offset);
        offset += chunk.byteLength;
      }
      updateLoader(end, status);
      return bytes.buffer;
    }

    async function run() {
      updateLoader(2, "Loading WebAssembly…", { indeterminate: true });
      const wasmURL = new URL("./\(product).wasm", import.meta.url);
      const wasmBytes = await fetchArrayBufferWithProgress(wasmURL, 5, 48, "Loading WebAssembly…");
      updateLoader(52, "Preparing Swift runtime…");
      const swift = new SwiftRuntime();

      if (!navigator.gpu) {
        throw new Error("WebGPU is not supported in this browser.");
      }
      updateLoader(58, "Requesting WebGPU adapter…");
      const adapter = await navigator.gpu.requestAdapter({ powerPreference: "high-performance" });
      if (!adapter) {
        throw new Error("Failed to acquire WebGPU adapter.");
      }
      const optionalFeatures = ["float32-filterable"];
      const requiredFeatures = optionalFeatures.filter((feature) => adapter.features.has(feature));
      // Layered PBR plus graph textures can exceed the WebGPU baseline of 16.
      // Request supported capacity without rejecting baseline-only adapters.
      const requiredLimits = {
        maxSampledTexturesPerShaderStage: Math.min(32, adapter.limits.maxSampledTexturesPerShaderStage),
        maxSamplersPerShaderStage: Math.min(32, adapter.limits.maxSamplersPerShaderStage),
        maxColorAttachmentBytesPerSample: Math.min(48, adapter.limits.maxColorAttachmentBytesPerSample),
      };
      updateLoader(64, "Creating WebGPU device…");
      const device = await adapter.requestDevice({ requiredFeatures, requiredLimits });
      if (new URLSearchParams(location.search).has("stats")) {
        const panel = document.createElement("output");
        panel.id = "ada-performance";
        panel.style.cssText = "position:fixed;right:12px;top:12px;padding:8px;background:#111c;color:#fff;font:14px monospace;z-index:10000;pointer-events:none";
        document.body.append(panel);
        let frames = 0, start = performance.now();
        const samples = [];
        const original = GPUCanvasContext.prototype.getCurrentTexture;
        GPUCanvasContext.prototype.getCurrentTexture = function() { frames++; return original.call(this); };
        setInterval(() => {
          const now = performance.now(), seconds = (now - start) / 1000;
          if (frames > 0) {
            const fps = frames / seconds;
            samples.push(fps);
            panel.textContent = fps.toFixed(1) + " FPS · " + (1000 / fps).toFixed(1) + " ms/frame";
            panel.dataset.samples = JSON.stringify(samples.slice(-12));
          }
          frames = 0; start = now;
        }, 2000);
      }

      const reportedGPUErrors = new Set();
      device.addEventListener("uncapturederror", (event) => {
        const message = event.error.message;
        if (!reportedGPUErrors.has(message)) {
          reportedGPUErrors.add(message);
          console.error("[AdaWebGPU] " + message);
        }
      });
      globalThis.__adaWebGPUAdapter = adapter;
      globalThis.__adaWebGPUDevice = device;
      // The browser renders through SAGA. Presentation attaches to the engine canvas when its window is created.
      updateLoader(66, "Opening SAGA WebGPU host…");
      const { openWebGPU } = await import("./saga-webgpu.mjs");
      globalThis.__adaSAGAHost = await openWebGPU(null, { deferCanvas: true });
      globalThis.__adaSAGADebug = new URLSearchParams(location.search).has("sagadebug");

      async function makeResourcePreopenDirectories() {
        updateLoader(68, "Loading resources…");
        const response = await fetch(new URL("./ada-resource-manifest.json", import.meta.url));
        const manifest = response.ok ? await response.json() : [];
        installResourceFetchResolver(manifest);
        const root = new Map();

        let loadedResources = 0;
        for (const entry of manifest) {
          const parts = entry.path.split("/").filter(Boolean);
          let directory = root;
          for (const part of parts.slice(0, -1)) {
            let child = directory.get(part);
            if (!(child instanceof Map)) {
              child = new Map();
              directory.set(part, child);
            }
            directory = child;
          }

          const resourceResponse = await fetch(new URL(entry.url, import.meta.url));
          if (!resourceResponse.ok) throw new Error(`Missing resource ${entry.url}: HTTP ${resourceResponse.status}`);
          const bytes = new Uint8Array(await resourceResponse.arrayBuffer());
          if (entry.path.startsWith("game/") && entry.path.endsWith(".wgsl")) {
            const shader = device.createShaderModule({label: entry.path, code: new TextDecoder().decode(bytes)});
            const info = await shader.getCompilationInfo();
            const errors = info.messages.filter(message => message.type === "error");
            if (errors.length) throw new Error(errors.map(message => `${entry.path}:${message.lineNum}:${message.linePos}: ${message.message}`).join("\\n"));
          }
          directory.set(parts[parts.length - 1], new File(bytes, { readonly: true }));
          loadedResources += 1;
          updateLoader(68 + (manifest.length > 0 ? (10 * loadedResources / manifest.length) : 10), "Loading resources…");
        }

        // SwiftPM incremental resource accessors can retain macOS's /tmp or /var
        // spelling while enumeration resolves /private/tmp or /private/var.
        // Mount both spellings onto the same files, without fetching bytes twice.
        const privateRoot = root.get("private");
        if (privateRoot instanceof Map) {
          for (const name of ["tmp", "var"]) {
            if (!root.has(name) && privateRoot.has(name)) root.set(name, privateRoot.get(name));
          }
        }

        const materialize = (map) => new Directory(
          [...map.entries()].map(([name, value]) => [name, value instanceof Map ? materialize(value) : value])
        );
        const rootEntries = () => [...root.entries()].map(([name, value]) => [name, value instanceof Map ? materialize(value) : value]);
        const preopens = [
          new PreopenDirectory("/", rootEntries()),
          new PreopenDirectory(".", rootEntries()),
        ];
        // Studio reloads source snapshots into the same WASI/renderer instance.
        // Only /game is replaced; engine bundles and the host filesystem stay untouched.
        if (globalThis.__adaStudioPreview === true) {
          globalThis.__adaInstallStudioFiles = (files) => {
            const game = new Directory([]);
            for (const file of files) {
              const parts = file.path.split("/");
              if (!parts.length || parts.some(part => !part || part === "." || part === "..")) throw new Error("Unsafe Studio file path");
              let directory = game;
              for (const part of parts.slice(0, -1)) {
                if (!directory.contents.has(part)) directory.contents.set(part, new Directory([]));
                directory = directory.contents.get(part);
                if (!(directory instanceof Directory)) throw new Error("Conflicting Studio file path");
              }
              directory.contents.set(parts.at(-1), new File(file.bytes, {readonly: true}));
            }
            for (const preopen of preopens) preopen.dir.contents.set("game", game);
          };
        }
        return preopens;
      }

      function installResourceFetchResolver(manifest) {
        const originalFetch = globalThis.fetch?.bind(globalThis);
        if (!originalFetch || globalThis.__adaResourceFetchResolverInstalled) return;

        const resourceURLsByPath = new Map();
        for (const entry of manifest) {
          if (!entry || typeof entry.path !== "string" || typeof entry.url !== "string") continue;
          const resourceURL = new URL(entry.url, import.meta.url).href;
          const relativePath = entry.path.replace(/^\\/+/, "");
          resourceURLsByPath.set(entry.path, resourceURL);
          resourceURLsByPath.set(relativePath, resourceURL);
          resourceURLsByPath.set(`/${relativePath}`, resourceURL);
          resourceURLsByPath.set(`./${relativePath}`, resourceURL);
          const macOSAlias = relativePath.replace(/^private\\/(tmp|var)\\//, "$1/");
          if (macOSAlias !== relativePath) {
            for (const prefix of ["", "/", "./"]) resourceURLsByPath.set(prefix + macOSAlias, resourceURL);
          }
        }

        const resolveResourceURL = (input) => {
          const rawURL = typeof input === "string" || input instanceof URL ? String(input) : input?.url;
          if (!rawURL) return null;
          if (resourceURLsByPath.has(rawURL)) return resourceURLsByPath.get(rawURL);
          const pathname = new URL(rawURL, import.meta.url).pathname.replace(/^\\/+/, "");
          if (resourceURLsByPath.has(pathname)) return resourceURLsByPath.get(pathname);
          for (const [resourcePath, resourceURL] of resourceURLsByPath) {
            if (pathname.endsWith(resourcePath.replace(/^\\/+/, ""))) return resourceURL;
          }
          return null;
        };

        globalThis.fetch = (input, init) => {
          const resourceURL = resolveResourceURL(input);
          if (resourceURL) {
            return originalFetch(resourceURL, init);
          }
          return originalFetch(input, init);
        };
        globalThis.__adaResourceFetchResolverInstalled = true;
      }

      const resourcePreopens = await makeResourcePreopenDirectories();
      updateLoader(82, "Configuring WASI…");
      const wasi = new WASI(["\(product).wasm"], [], [
        new OpenFile(new File([])),
        ConsoleStdout.lineBuffered((line) => console.log(line)),
        ConsoleStdout.lineBuffered((line) => console.warn(line)),
        ...resourcePreopens,
      ], { debug: false });
      const importObject = {
        wasi_snapshot_preview1: wasi.wasiImport,
        javascript_kit: swift.wasmImports,
      };
      updateLoader(86, "Preparing JavaScript bridge…");
      const bridgeJS = await createInstantiator({}, swift);
      bridgeJS.addImports(importObject, {});
      let wasmInstance;
      const i64Stack = [];
      const typedArrayStack = [];
      const typedArrayConstructors = [Int8Array, Uint8Array, Int16Array, Uint16Array, Int32Array, Uint32Array, Float32Array, Float64Array];
      importObject.bjs ??= {};
      importObject.bjs.swift_js_push_i64 ??= (value) => {
        i64Stack.push(value);
      };
      importObject.bjs.swift_js_pop_i64 ??= () => i64Stack.pop();
      importObject.bjs.swift_js_push_typed_array ??= (kind, pointer, count) => {
        const constructor = typedArrayConstructors[kind];
        const byteLength = count * constructor.BYTES_PER_ELEMENT;
        const copy = wasmInstance.exports.memory.buffer.slice(pointer, pointer + byteLength);
        typedArrayStack.push(Array.from(new constructor(copy)));
      };

      updateLoader(90, "Instantiating WebAssembly…", { indeterminate: true });
      const { instance } = await WebAssembly.instantiate(wasmBytes, importObject);
      wasmInstance = instance;

      updateLoader(96, "Starting AdaEngine…");
      swift.setInstance(instance);
      bridgeJS.setInstance(instance);
      bridgeJS.createExports(instance);
      wasi.initialize(instance);
      swift.main();
      hideLoader();
    }

    run().catch(failLoader);
    """
}

private func packageJSON(product: String) -> String {
    """
    {
      "name": "\(product.lowercased())-ada-web",
      "private": true,
      "type": "module",
      "scripts": {
        "serve": "vite --host 127.0.0.1"
      },
      "dependencies": {
        "@bjorn3/browser_wasi_shim": "^0.4.1",
        "vite": "^5.0.0"
      },
      "devDependencies": {}
    }
    """
}

private func manifestJSON(product: String) -> String {
    """
    {
      "product": "\(product)",
      "wasm": "\(product).wasm",
      "canvasRoot": "ada-canvas-root",
      "assets": "Assets"
    }
    """
}
