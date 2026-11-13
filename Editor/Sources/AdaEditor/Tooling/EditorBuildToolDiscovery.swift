import Foundation
#if os(Windows)
import WinSDK
#endif

/// Bounded, read-only discovery. Never runs tools found on disk or searches whole drives.
actor EditorBuildToolDiscovery {
    func scan(overrides: [String: String]) -> [String: String] {
        Self.discover(environment: EditorHostTools.mergedEnvironment(overrides, inheriting: Self.currentEnvironment()))
    }

    static func discover(
        environment: [String: String],
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        fileManager: FileManager = .default
    ) -> [String: String] {
        func value(_ key: String) -> String? { EditorHostTools.environmentValue(key, in: environment) }
        func url(_ path: String) -> URL { URL(fileURLWithPath: path) }
        func children(_ root: URL) -> [URL] {
            ((try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
                .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        }
        func first(_ key: String, _ candidates: [String]) -> String? {
            candidates.first { isAvailable($0, key: key, fileManager: fileManager) }
        }
        #if os(Windows)
        let suffix = ".exe"
        let separator: Character = ";"
        let local = url(value("LOCALAPPDATA") ?? home.appendingPathComponent("AppData/Local").path)
        let programFiles = url(value("ProgramFiles") ?? "C:/Program Files")
        let programFilesX86 = url(value("ProgramFiles(x86)") ?? "C:/Program Files (x86)")
        let swiftRoots = [local.appendingPathComponent("Programs/Swift"), programFiles.appendingPathComponent("Swift"),
                          url((value("SystemDrive") ?? "C:") + "/Library/Developer")]
        let toolchains = swiftRoots.flatMap { children($0.appendingPathComponent("Toolchains")) }
        let swiftPaths = toolchains.map { $0.appendingPathComponent("usr/bin/swift.exe").path }
        let javaPaths = [programFiles.appendingPathComponent("Android/Android Studio/jbr").path,
                         local.appendingPathComponent("Programs/Android Studio/jbr").path,
                         local.appendingPathComponent("Android/Android Studio/jbr").path]
        let androidPaths = [local.appendingPathComponent("Android/Sdk").path]
        let visualStudios = [programFiles, programFilesX86].flatMap { root in
            children(root.appendingPathComponent("Microsoft Visual Studio")).flatMap { children($0) }
        }
        let cmakePaths = [programFiles.appendingPathComponent("CMake/bin/cmake.exe").path] + visualStudios.map {
            $0.appendingPathComponent("Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe").path
        }
        let ninjaPaths = visualStudios.map {
            $0.appendingPathComponent("Common7/IDE/CommonExtensions/Microsoft/CMake/Ninja/ninja.exe").path
        }
        #else
        let suffix = ""
        let separator: Character = ":"
        let toolchains = children(home.appendingPathComponent("Library/Developer/Toolchains"))
            + children(URL(fileURLWithPath: "/Library/Developer/Toolchains"))
            + children(home.appendingPathComponent(".local/share/swiftly/toolchains"))
        let swiftPaths = toolchains.map { $0.appendingPathComponent("usr/bin/swift").path }
            + ["/usr/bin/swift", "/usr/local/bin/swift"]
        let javaPaths = ["/Applications/Android Studio.app/Contents/jbr/Contents/Home"]
            + children(URL(fileURLWithPath: "/Library/Java/JavaVirtualMachines")).map { $0.appendingPathComponent("Contents/Home").path }
        let androidPaths = [home.appendingPathComponent("Library/Android/sdk").path, home.appendingPathComponent("Android/Sdk").path]
        let cmakePaths = ["/opt/homebrew/bin/cmake", "/usr/local/bin/cmake", "/usr/bin/cmake"]
        let ninjaPaths = ["/opt/homebrew/bin/ninja", "/usr/local/bin/ninja", "/usr/bin/ninja"]
        #endif
        let path = (value("PATH") ?? "").split(separator: separator).map {
            String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }.filter { !$0.isEmpty }
        func executables(_ name: String) -> [String] { path.map { url($0).appendingPathComponent(name + suffix).path } }
        var found: [String: String] = [:]
        found["SWIFT_EXECUTABLE"] = first("SWIFT_EXECUTABLE", [value("SWIFT_EXECUTABLE")].compactMap { $0 } + executables("swift") + swiftPaths)
        found["CMAKE_EXECUTABLE"] = first("CMAKE_EXECUTABLE", [value("CMAKE_EXECUTABLE")].compactMap { $0 } + executables("cmake") + cmakePaths)
        found["NINJA_EXECUTABLE"] = first("NINJA_EXECUTABLE", [value("NINJA_EXECUTABLE")].compactMap { $0 } + executables("ninja") + ninjaPaths)
        found["ADAENGINE_SAGA_PACKAGE_PATH"] = first("ADAENGINE_SAGA_PACKAGE_PATH", [value("ADAENGINE_SAGA_PACKAGE_PATH")].compactMap { $0 })
        found["ANDROID_HOME"] = first("ANDROID_HOME", [value("ANDROID_HOME"), value("ANDROID_SDK_ROOT")].compactMap { $0 } + androidPaths)
        found["JAVA_HOME"] = first("JAVA_HOME", [value("JAVA_HOME")].compactMap { $0 } + javaPaths + executables("java").map {
            url($0).deletingLastPathComponent().deletingLastPathComponent().path
        })
        // A caller's selected SDK is supplied in environment, so NDK/build-tools come from that SDK.
        if let sdk = found["ANDROID_HOME"] {
            found["ANDROID_NDK_HOME"] = first("ANDROID_NDK_HOME", [value("ANDROID_NDK_HOME"), value("ANDROID_NDK_ROOT")].compactMap { $0 }
                + children(url(sdk).appendingPathComponent("ndk")).map(\.path))
            found["ANDROID_BUILD_TOOLS_VERSION"] = children(url(sdk).appendingPathComponent("build-tools")).first {
                fileManager.isExecutableFile(atPath: $0.appendingPathComponent("aapt2" + suffix).path)
            }?.lastPathComponent
        }
        found["ANDROID_AVD_HOME"] = first("ANDROID_AVD_HOME", [value("ANDROID_AVD_HOME"), home.appendingPathComponent(".android/avd").path].compactMap { $0 })
        #if os(Windows)
        found["WindowsSdkDir"] = first("WindowsSdkDir", [value("WindowsSdkDir"), programFilesX86.appendingPathComponent("Windows Kits/10").path].compactMap { $0 })
        found["VCToolsInstallDir"] = first("VCToolsInstallDir", [value("VCToolsInstallDir")].compactMap { $0 }
            + visualStudios.flatMap { children($0.appendingPathComponent("VC/Tools/MSVC")).map(\.path) })
        // The Windows exporter owns a Linux toolchain inside WSL. Never fill its
        // compiler fields with native Windows Swift or SDK paths.
        #else
        found["CC"] = first("CC", [value("CC")].compactMap { $0 } + executables("clang"))
        found["ADA_WEB_SWIFT_EXECUTABLE"] = first("ADA_WEB_SWIFT_EXECUTABLE", [value("ADA_WEB_SWIFT_EXECUTABLE")].compactMap { $0 } + swiftPaths.filter { $0.contains("6.3.2") })
        found["SWIFT_ANDROID_SWIFT"] = first("SWIFT_ANDROID_SWIFT", [value("SWIFT_ANDROID_SWIFT")].compactMap { $0 } + swiftPaths.filter { $0.contains("6.4") })
        found["SWIFT_ANDROID_SDKS_PATH"] = first("SWIFT_ANDROID_SDKS_PATH", [value("SWIFT_ANDROID_SDKS_PATH"),
            home.appendingPathComponent("Library/org.swift.swiftpm/swift-sdks").path, home.appendingPathComponent(".swiftpm/swift-sdks").path].compactMap { $0 })
        found["DEVELOPER_DIR"] = first("DEVELOPER_DIR", [value("DEVELOPER_DIR"), "/Applications/Xcode.app/Contents/Developer"].compactMap { $0 })
        #endif
        return found
    }

    static func isAvailable(_ path: String, key: String, fileManager: FileManager = .default) -> Bool {
        guard !path.isEmpty else { return false }
        var directory: ObjCBool = false
        guard unsafe fileManager.fileExists(atPath: path, isDirectory: &directory) else { return false }
        #if os(Windows)
        let suffix = ".exe"
        #else
        let suffix = ""
        #endif
        let root = URL(fileURLWithPath: path)
        switch key {
        case "ANDROID_HOME": return fileManager.isExecutableFile(atPath: root.appendingPathComponent("platform-tools/adb" + suffix).path)
        case "JAVA_HOME": return fileManager.isExecutableFile(atPath: root.appendingPathComponent("bin/javac" + suffix).path)
        case "ANDROID_NDK_HOME": return directory.boolValue && fileManager.fileExists(atPath: root.appendingPathComponent("source.properties").path)
        case "WindowsSdkDir": return directory.boolValue && fileManager.fileExists(atPath: root.appendingPathComponent("Include").path)
        case "VCToolsInstallDir": return directory.boolValue && fileManager.fileExists(atPath: root.appendingPathComponent("include").path)
        case "ADAENGINE_SAGA_PACKAGE_PATH": return directory.boolValue && fileManager.fileExists(atPath: root.appendingPathComponent("Package.swift").path)
        case "SWIFT_EXECUTABLE", "CMAKE_EXECUTABLE", "NINJA_EXECUTABLE", "CC", "SWIFT_ANDROID_SWIFT", "ADA_WEB_SWIFT_EXECUTABLE", "GRADLE_EXECUTABLE":
            return !directory.boolValue && fileManager.isExecutableFile(atPath: path)
        default: return directory.boolValue
        }
    }

    /// Read persisted environment again: Studio's inherited PATH predates new installations.
    static func currentEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        #if os(Windows)
        let keys = ["PATH", "SWIFT_EXECUTABLE", "JAVA_HOME", "ANDROID_HOME", "ANDROID_SDK_ROOT", "ANDROID_NDK_HOME"]
        for key in keys {
            let machine = registryValue(HKEY_LOCAL_MACHINE, subkey: "SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment", name: key)
            let user = registryValue(HKEY_CURRENT_USER, subkey: "Environment", name: key)
            let inherited = EditorHostTools.environmentValue(key, in: environment)
            let value = key == "PATH" ? [user, machine, inherited].compactMap { $0 }.joined(separator: ";") : (user ?? machine ?? inherited)
            if let value { environment = EditorHostTools.mergedEnvironment([key: value], inheriting: environment) }
        }
        #endif
        return environment
    }

    #if os(Windows)
    private static func registryValue(_ root: HKEY?, subkey: String, name: String) -> String? {
        var bytes: DWORD = 0
        let flags = DWORD(RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ)
        return subkey.withCString(encodedAs: UTF16.self) { key in
            name.withCString(encodedAs: UTF16.self) { value in
                guard RegGetValueW(root, key, value, flags, nil, nil, &bytes) == ERROR_SUCCESS, bytes > 0, bytes < 1_048_576 else { return nil }
                var buffer = [WCHAR](repeating: 0, count: Int(bytes) / 2 + 1)
                let status = buffer.withUnsafeMutableBytes { RegGetValueW(root, key, value, flags, nil, $0.baseAddress, &bytes) }
                guard status == ERROR_SUCCESS else { return nil }
                return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF16.self)
            }
        }
    }
    #endif
}
