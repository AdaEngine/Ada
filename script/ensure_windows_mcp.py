#!/usr/bin/env python3
"""Stage pinned AdaMCP with Windows GPU readback and discovery compatibility."""
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
REVISION = "ed7bb9076f9f8c91e2584ca9b7201df0e03defb1"  # Tool metadata support; keep in sync with Editor/Package.swift.


PATCH_VERSION = "component-inspection-v2"
INSPECTION_PATCH = ROOT / "script" / "patches" / "adamcp-component-inspection.patch"
CAPTURE_FILES = (
    "Sources/AdaMCPCore/RenderCaptureService.swift",
    "Sources/AdaMCPCore/AdaMCPRuntime+RenderGraph.swift",
)
ORIGINAL = "        let image = texture.image"
REPLACEMENT = """        // WebGPU readback is asynchronous; Texture.image otherwise returns an empty 1x1 image.
        guard let image = try await RenderEngine.shared.renderDevice.readImage(from: texture) else {
            throw AdaMCPError.screenshotUnavailable("The render backend cannot read this texture.")
        }"""


DISCOVERY_FILE = "Sources/AdaMCPServer/AdaMCPDiscovery.swift"
DISCOVERY_ORIGINAL = r"""        let temporaryURL = state.manifestURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(state.manifestURL.lastPathComponent).tmp")
        try data.write(to: temporaryURL, options: .atomic)

        if fileManager.fileExists(atPath: state.manifestURL.path) {
            _ = try fileManager.replaceItemAt(state.manifestURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: state.manifestURL)
        }"""
DISCOVERY_REPLACEMENT = """        #if os(Windows)
        // replaceItemAt traps in Windows Foundation. Data.write atomically replaces the destination.
        try data.write(to: state.manifestURL, options: .atomic)
        #else
""" + DISCOVERY_ORIGINAL + "\n        #endif"
CAPTURE_GUARD = "        guard let renderWorld = appWorlds.getSubworldBuilder(by: .renderWorld) else {"
CAPTURE_EXCLUSIVE = """        return try await appWorlds.withExclusiveWorldAccess {
            try await self.captureCurrentFrame(appWorlds: appWorlds, cameraEntityID: cameraEntityID, cameraName: cameraName)
        }
    }

    private func captureCurrentFrame(
        appWorlds: AppWorlds,
        cameraEntityID: Int?,
        cameraName: String?
    ) async throws -> ScreenshotCaptureResult {
""" + CAPTURE_GUARD
GRAPH_START = """        if refreshFrame {
            try await appWorlds.update()
        }

        let cameraEntity = try self.resolveRenderCamera("""
GRAPH_EXCLUSIVE = """        if refreshFrame {
            try await appWorlds.update()
        }

        return try await appWorlds.withExclusiveWorldAccess {
            try await self.dumpCurrentAttachment(arguments: arguments, attachmentName: attachmentName)
        }
    }

    private func dumpCurrentAttachment(arguments: [String: Value], attachmentName: String) async throws -> Value {
        let cameraEntity = try self.resolveRenderCamera("""
MANIFEST_PNG_ORIGINAL = "let package = Package("
MANIFEST_PNG_REPLACEMENT = """// Newer engines provide portable PNG encoding. Keep AdaMCP's fallback only for older engines.
let hasEnginePNGWriter = FileManager.default.fileExists(
    atPath: adaEngineURL.appendingPathComponent("Sources/AdaRender/Image/Image+PortablePNG.swift").path
)

let package = Package("""
MANIFEST_CORE_ORIGINAL = """            ]
        ),
        .target(
            name: "AdaMCPServer","""
MANIFEST_CORE_REPLACEMENT = """            ],
            exclude: hasEnginePNGWriter ? ["ImagePNGFallback.swift"] : []
        ),
        .target(
            name: "AdaMCPServer","""
PATCHES = [(relative, ORIGINAL, REPLACEMENT) for relative in CAPTURE_FILES] + [
    (CAPTURE_FILES[0], CAPTURE_GUARD, CAPTURE_EXCLUSIVE),
    (CAPTURE_FILES[1], GRAPH_START, GRAPH_EXCLUSIVE),
    (DISCOVERY_FILE, DISCOVERY_ORIGINAL, DISCOVERY_REPLACEMENT),
    ("Package.swift", MANIFEST_PNG_ORIGINAL, MANIFEST_PNG_REPLACEMENT),
    ("Package.swift", MANIFEST_CORE_ORIGINAL, MANIFEST_CORE_REPLACEMENT),
]


def prepare_windows_package(source, destination):
    """Keep the pinned checkout pristine and patch only a separate local package."""
    if not destination.exists():
        # Packages contains the npm CLI and a developer-local AdaEngine symlink.
        # Neither belongs to the native Swift package.
        shutil.copytree(
            source, destination,
            ignore=shutil.ignore_patterns(".git", ".build", "Packages"),
            ignore_dangling_symlinks=True,
        )
    grouped = {}
    for relative, original, replacement in PATCHES:
        grouped.setdefault(relative, []).append((original, replacement))
    for relative, patches in grouped.items():
        target = destination / relative
        expected = (source / relative).read_text(encoding="utf-8")
        # Accept only the pinned source or a known earlier stage of these patches.
        # This also upgrades existing readback-only packages without overwriting edits.
        known_versions = [expected]
        for original, replacement in patches:
            if expected.count(original) != 1:
                raise RuntimeError(f"Unexpected AdaMCP compatibility source: {relative}")
            expected = expected.replace(original, replacement)
            known_versions.append(expected)
        current = target.read_text(encoding="utf-8")
        if current == expected:
            continue
        if current not in known_versions:
            raise RuntimeError(f"Unexpected AdaMCP staged modifications: {relative}")
        target.write_text(expected, encoding="utf-8")
    applied = subprocess.run(
        ["git", "apply", "--reverse", "--check", str(INSPECTION_PATCH)],
        cwd=destination, capture_output=True,
    )
    if applied.returncode != 0:
        subprocess.run(["git", "apply", "--check", str(INSPECTION_PATCH)], cwd=destination, check=True)
        subprocess.run(["git", "apply", str(INSPECTION_PATCH)], cwd=destination, check=True)
    return destination


def main():
    destination = ROOT / ".build-tools" / ("adamcp-" + REVISION)
    if not destination.exists():
        # AdaMCP chooses the engine's local path when ADAENGINE_PACKAGE_PATH is set.
        # SwiftPM rejects local dependencies inside a remote revision requirement,
        # so declare this exact revision as a local package too; never edit checkouts.
        subprocess.run(["git", "clone", "--no-checkout", "https://github.com/AdaEngine/AdaMCP.git", str(destination)], check=True)
        subprocess.run(["git", "-C", str(destination), "checkout", "--detach", REVISION], check=True)
    actual = subprocess.check_output(["git", "-C", str(destination), "rev-parse", "HEAD"], text=True).strip()
    if actual != REVISION or not (destination / "Package.swift").is_file():
        raise RuntimeError("Staged AdaMCP does not match the pinned revision")
    patched = ROOT / ".build-tools" / ("adamcp-" + REVISION + "-" + PATCH_VERSION)
    print(prepare_windows_package(destination, patched))


if __name__ == "__main__":
    main()
