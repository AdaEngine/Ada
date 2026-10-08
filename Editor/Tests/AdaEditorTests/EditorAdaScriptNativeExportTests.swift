#if os(macOS) && canImport(GravityAOT)
@testable import AdaEditor
import AdaEngine
import AdaScriptCompilerCore
import Foundation
import Testing

@Suite("Editor native AdaScript export", .serialized)
struct EditorAdaScriptNativeExportTests {
    @Test("Exports multiple sources and scenes through the real compiler, preserving old output on failure")
    @MainActor
    func archiveAndScenes() async throws {
        let engine = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let override = ProcessInfo.processInfo.environment["ADAENGINE_GRAVITY_PACKAGE_PATH"].map { URL(fileURLWithPath: $0) }
        let gravityCandidates = override.map { [$0] } ?? [
            engine.appendingPathComponent("Editor/.build/checkouts/gravity-lang"),
            engine.appendingPathComponent(".build/checkouts/gravity-lang"),
        ]
        let gravity = try #require(gravityCandidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("tools/aot_build.py").path) })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AdaNativeExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        defer { if ProcessInfo.processInfo.environment["ADA_AOT_EXPORT_PROOF_DIR"] == nil { try? FileManager.default.removeItem(at: root) } }
        var project = try ProjectSystem.createDefaultProject(at: root, buildSystem: .adaScript)
        project.runtime.entry.view = nil
        project.runtime.entry.scene = "Scene.ascn"
        try "class Helper { func value() { return 42; } }".write(to: root.appendingPathComponent("Sources/Helper.ada"), atomically: true, encoding: .utf8)
        try """
        func main() { return Helper().value(); }
        @system class ExportSystem {
            var started = false;
            var result = 0;
            func update(context) { if (!started) { started = true; Tasks.start(self.finish()); } }
            async func finish() { await Tasks.nextFrame(); result = 42; }
        }
        """.write(
            to: root.appendingPathComponent("Sources/Main.ada"),
            atomically: true,
            encoding: .utf8
        )
        var model = EditorSceneModel.default(projectName: "Native export")
        let target = try #require(model.entities.first)
        model.animations = [EditorAnimationClip(name: "Camera move", targetEntityID: target.id, duration: 1, repeatMode: .pingPong,
            tracks: [EditorAnimationTrack(property: .positionX, keyframes: [
                EditorAnimationKeyframe(time: 0, value: 0, curveToNext: .cubicInOut), EditorAnimationKeyframe(time: 1, value: 10)
            ])])]
        try model.encodedYAML().write(to: root.appendingPathComponent("Assets/Scene.ascn"), atomically: true, encoding: .utf8)
        var options = EditorAdaScriptNativeExportOptions(
            destination: ProcessInfo.processInfo.environment["ADA_AOT_EXPORT_WEB"] == "1" ? .web : .macOS,
            gravityRoot: gravity,
            engineRoot: engine,
            swiftExecutable: ProcessInfo.processInfo.environment["ADA_WEB_SWIFT_EXECUTABLE"] ?? "/usr/bin/swift"
        )
        options.buildsPlayer = ProcessInfo.processInfo.environment["ADA_AOT_EXPORT_BUILD_PLAYER"] == "1"
        options.configuration = .debug
        options.hostScratchDirectory = ProcessInfo.processInfo.environment["ADA_AOT_EXPORT_HOST_SCRATCH"].map { URL(fileURLWithPath: $0) }
        options.scratchDirectory = ProcessInfo.processInfo.environment["ADA_AOT_EXPORT_SCRATCH"].map { URL(fileURLWithPath: $0) }
        let output = ProcessInfo.processInfo.environment["ADA_AOT_EXPORT_PROOF_DIR"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("Export")
        let exporter = EditorAdaScriptNativeExporter()
        let result = try await exporter.export(project: project, at: root, to: output, options: options)
        let library = result.appendingPathComponent("Sources/GameplayNative/libada_game.a")
        let before = try Data(contentsOf: library)
        #expect(before.count > 100)
        let scene = try JSONDecoder().decode(AdaScriptNativeSceneDocument.self, from: Data(contentsOf: result.appendingPathComponent("Sources/AdaNativeGame/GameAssets/Scene.ascn")))
        #expect(scene.entities.count == 1)
        let animation = try #require(scene.entities.first?.animationClips?.first)
        let clip = try KeyframeClip<SceneTransformAnimationValues>(jsonData: animation, schema: SceneTransformAnimationValues.clipSchema)
        #expect(clip.repeatMode == .pingPong)
        #expect(abs(clip.evaluate(at: 0.25).transform.position.x - 1.5625) < 0.001)
        let exportedScene = try scene.makeScene(components: [])
        #expect(exportedScene.world.getEntityByName(target.name)?.components[KeyframeAnimator.self] != nil)
        let host = root.appendingPathComponent("host.c")
        try """
        #include "ada_game.h"
        #include "gravity_aot_objects.h"
        #include <stdio.h>
        #include <string.h>
        int main(void) {
            unsigned char memory[32768];
            gravity_aot_arena arena = {memory, sizeof(memory), 0};
            gravity_aot_context context = gravity_aot_context_init(10000);
            context.allocate = gravity_aot_arena_allocate; context.allocation_data = &arena;
            const gravity_aot_module *module = ada_game_get_module();
            for (unsigned i = 0; i < module->count; ++i) if (!strcmp(module->exports[i].name, "main")) {
                gravity_aot_value result = module->exports[i].call(&context, NULL, 0);
                if (context.error) return 1;
                printf("%lld\\n", (long long)result.integer); return result.integer == 42 ? 0 : 2;
            }
            return 3;
        }
        """.write(to: host, atomically: true, encoding: .utf8)
        let runner = EditorProcessRunner()
        let binary = root.appendingPathComponent("host")
        let compile = await runner.run(
            EditorProcessCommand(
                executablePath: "/usr/bin/clang",
                arguments: ["-std=c11", "-I", library.deletingLastPathComponent().path, host.path, library.path, "-o", binary.path],
                workingDirectory: root
            )
        )
        #expect(compile.succeeded, Comment(rawValue: compile.combinedOutput))
        let execution = await runner.run(EditorProcessCommand(executablePath: binary.path, arguments: [], workingDirectory: root))
        #expect(execution.succeeded)
        #expect(execution.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "42")
        let parse = await runner.run(
            EditorProcessCommand(
                executablePath: options.swiftExecutable + "c",
                arguments: ["-frontend", "-parse", result.appendingPathComponent("Sources/AdaNativeGame/Game.swift").path],
                workingDirectory: root
            )
        )
        #expect(parse.succeeded, Comment(rawValue: parse.combinedOutput))
        project.runtime.entry.view = "DisabledView"
        do {
            _ = try await exporter.export(project: project, at: root, to: output, options: options)
            Issue.record("Disabled @view entry was accepted")
        } catch { #expect(try Data(contentsOf: library) == before) }
        project.runtime.entry.view = nil
        try "func main() { return { return 1; }; }".write(to: root.appendingPathComponent("Sources/Main.ada"), atomically: true, encoding: .utf8)
        do {
            _ = try await exporter.export(project: project, at: root, to: output, options: options)
            Issue.record("Unsupported AOT source was accepted")
        } catch {
            #expect(try Data(contentsOf: library) == before)
        }
    }
}
#endif
