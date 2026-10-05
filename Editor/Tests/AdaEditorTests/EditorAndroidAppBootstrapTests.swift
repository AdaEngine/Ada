#if os(macOS)
  @testable import AdaEditor
  import Foundation
  import SwiftParser
  import Testing

  @Suite("Studio Android app bootstrap")
  struct EditorAndroidAppBootstrapTests {
    @Test func generatesOnlyInTheAppFileAndPreservesOtherSources() throws {
      let helper = "// @main and @_cdecl(\"ada_android_start\") in comments are not entries.\nstruct Helper {}"
      let app = "import AdaEngine\n@MainActor @main private struct Game: AdaEngine.App {}"
      let result = try EditorAndroidAppBootstrap.prepare([helper, app])
      #expect(result[0] == helper)
      #expect(result[1].contains("@MainActor"))
      #expect(!result[1].contains("@main"))
      #expect(result[1].contains("private struct Game"))
      #expect(result[1].contains("AdaEngine.AndroidRuntime.start { Game() }"))
      #expect(!Parser.parse(source: result[1]).hasError)
      #expect(try EditorAndroidAppBootstrap.prepare(result) == result)
    }

    @Test(arguments: ["\"ada_android_start\"", "#\"ada_android_start\"#"])
    func preservesAnExplicitAndroidEntry(symbol: String) throws {
      let source = """
        import AdaEngine
        #if os(Android)
        @_cdecl(\(symbol))
        public func androidStart() { AndroidRuntime.start { Game() } }
        #else
        @main private enum GardenMain {
            static func main() async throws { try await Game.main() }
        }
        #endif
        struct Game: App {}
        """
      #expect(try EditorAndroidAppBootstrap.prepare([source]) == [source])
    }

    @Test(arguments: [
      "struct Game: App {}",
      "@main enum Main { static func main() {} }",
      "@main struct Game<T>: App {}",
      "struct Container { @main struct Game: App {} }",
      "@main struct First: App {}\n@main struct Second: App {}",
      "@_cdecl(\"ada_android_start\") func first() {}\n@_cdecl(\"ada_android_start\") func second() {}",
      "@main struct Game: App {",
    ])
    func rejectsUnsupportedOrAmbiguousStartup(source: String) {
      #expect(throws: EditorPreviewBuildFailure.self) {
        try EditorAndroidAppBootstrap.prepare([source])
      }
    }

    /// Compile and invoke the generated C export against a small host runtime.
    /// This proves bridge/type accessibility; Android's executor and renderer
    /// are exercised separately by the Android export integration suite.
    @Test(arguments: ["struct", "final class", "enum"])
    func generatedPrivateAppCompilesAndStarts(kind: String) async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "Studio Android Bootstrap \(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let runtime = """
        @MainActor public protocol App: Sendable { init() }
        public enum AndroidRuntime {
            public nonisolated static func start<A: App>(_ factory: @escaping @MainActor @Sendable () -> A) {
                Task { @MainActor in _ = factory() }
            }
        }
        """
      let source = """
        import AdaEngine
        @main private \(kind) Game: AdaEngine.App {
            \(kind == "enum" ? "case running" : "")
            init() {
                \(kind == "enum" ? "self = .running" : "")
                print("Generated Android app started")
            }
        }
        """
      let generated = try #require(EditorAndroidAppBootstrap.prepare([source]).first)
      let host = """
        import Foundation
        @_silgen_name("ada_android_start") func nativeStart()
        @main enum Host {
            static func main() async throws {
                nativeStart()
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        """
      for (name, text) in [("Runtime.swift", runtime), ("Game.swift", generated), ("Host.swift", host)] {
        try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
      }
      let runner = EditorProcessRunner()
      let cache = root.appendingPathComponent("ModuleCache").path
      let libraryArguments = ["-I", root.path, "-L", root.path, "-Xlinker", "-rpath", "-Xlinker", root.path]
      for arguments in [
        ["-emit-module", "-emit-library", "-module-name", "AdaEngine", "Runtime.swift", "-o", "libAdaEngine.dylib",
          "-Xlinker", "-install_name", "-Xlinker", "@rpath/libAdaEngine.dylib"],
        ["-parse-as-library", "-emit-library", "Game.swift", "-lAdaEngine", "-o", "libGame.dylib",
          "-Xlinker", "-install_name", "-Xlinker", "@rpath/libGame.dylib"] + libraryArguments,
        ["-parse-as-library", "Host.swift", "-lGame", "-lAdaEngine", "-o", "Host"] + libraryArguments,
      ] {
        let result = await runner.run(EditorProcessCommand(
          executablePath: "/usr/bin/xcrun",
          arguments: ["swiftc", "-swift-version", "6", "-module-cache-path", cache] + arguments,
          workingDirectory: root))
        try #require(result.succeeded, "\(result.combinedOutput)")
      }
      let result = await runner.run(EditorProcessCommand(
        executablePath: root.appendingPathComponent("Host").path, arguments: [], workingDirectory: root))
      #expect(result.succeeded, "\(result.combinedOutput)")
      #expect(result.standardOutput.contains("Generated Android app started"))
    }
  }
#endif
