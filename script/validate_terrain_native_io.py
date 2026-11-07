"""Run real terrain codec/writer sources and filesystem tests in an isolated native host probe.

The fixture supplies only unused asset-protocol interfaces and metadata declarations;
it does not replace filesystem, codecs, bounded reads or the writer. This complements
the full engine suite and does not validate the complete AssetsManager or Studio.
"""

import argparse
import hashlib
import shutil
import subprocess
import sys
from pathlib import Path

CONTEXT = """import Foundation
public struct AssetMetaInfo: Sendable {}
public protocol Asset: Sendable {
    static var maximumEncodedBytes: Int? { get }
    var assetMetaInfo: AssetMetaInfo? { get set }
    init(from assetDecoder: any AssetDecoder) async throws
    func encodeContents(with assetEncoder: any AssetEncoder) async throws
    static func extensions() -> [String]
}
public protocol AssetDecoder: Sendable { var assetData: Data { get } }
public protocol AssetEncoder: Sendable { func encode<T: Encodable>(_ value: T) throws }
struct AssetsManager {}
enum AssetError: Error {
    case notExistAtPath(String)
    case message(String)
    case encodedSizeLimitExceeded(path: String, limit: Int)
}
"""

MANIFEST = """// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "TerrainNativeIOProbe", targets: [
    .target(name: "TerrainNativeIO"),
    .testTarget(name: "TerrainNativeIOTests", dependencies: ["TerrainNativeIO"],
                swiftSettings: [.define("TERRAIN_NATIVE_IO_PROBE")])
])
"""


def write_if_changed(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists() or path.read_bytes() != data:
        path.write_bytes(data)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", default=shutil.which("swift"))
    args = parser.parse_args()
    if not args.swift or not Path(args.swift).is_file():
        parser.error("A native Swift compiler is required; pass --swift PATH")
    root = Path(__file__).resolve().parents[1]
    package = root / ".build-tools/terrain-native-io"
    sources = package / "Sources/TerrainNativeIO"
    tests = package / "Tests/TerrainNativeIOTests"
    originals = [
        "Sources/AdaAssets/Terrain/TerrainRegionAsset.swift",
        "Sources/AdaAssets/Terrain/TerrainManifestAsset.swift",
        "Sources/AdaAssets/Terrain/TerrainAssetWriter.swift",
        "Sources/AdaAssets/AssetsManager+BoundedRead.swift",
    ]
    for relative in originals:
        original = root / relative
        data = original.read_bytes()
        print("PRODUCTION-SOURCE", relative, hashlib.sha256(data).hexdigest(), flush=True)
        write_if_changed(sources / original.name, data)
    test = root / "Tests/AdaAssetsTests/TerrainAtomicPlatformTests.swift"
    data = test.read_bytes()
    print("TEST-SOURCE", test.relative_to(root), hashlib.sha256(data).hexdigest(), flush=True)
    write_if_changed(tests / test.name, data)
    write_if_changed(sources / "AssetInterfaces.swift", CONTEXT.encode())
    write_if_changed(package / "Package.swift", MANIFEST.encode())
    command = [args.swift, "test", "--package-path", str(package), "--jobs", "4", "--filter", "TerrainAtomicPlatformTests"]
    print("COMMAND", command, flush=True)
    return subprocess.run(command, cwd=root, check=False).returncode


if __name__ == "__main__":
    sys.exit(main())
