import json
import os
from pathlib import Path
import struct
import tempfile
import unittest

if __package__:
    from .prepare_meshlets import MAGIC, geometry_digest, native_scan, prepare, scan
else:
    from prepare_meshlets import MAGIC, geometry_digest, native_scan, prepare, scan

NATIVE_TOOL = Path(__file__).resolve().parents[1] / ".build-tools/meshlet-builder" / ("MeshletScan.exe" if os.name == "nt" else "MeshletScan")


class PrepareMeshletsTests(unittest.TestCase):
    @unittest.skipUnless(NATIVE_TOOL.is_file(), "Build the pinned native adapter first")
    def test_pinned_native_scan_profiles_preserve_every_triangle(self):
        positions = [(float(i), 0.0, 0.0) for i in range(240)]
        for maximum in [64, 96, 126]:
            indices = list(range(240)) + [0, 0, 0, 2, 1, 0]
            clusters, same = native_scan(positions, indices, NATIVE_TOOL, 64, maximum)
            self.assertTrue(same)
            self.assertEqual(sum(c[1] for c in clusters), len(indices))
        # Native scan can close a meshlet conservatively at a repeated-vertex triangle.
        # Boundaries may differ from the reference, but the adapter verifies expanded index identity.
        indices = list(range(63)) + [63, 63, 63, 64, 65, 66]
        clusters, _ = native_scan(positions, indices, NATIVE_TOOL)
        self.assertEqual(sum(c[1] for c in clusters), len(indices))
        self.assertEqual(clusters[0][0], 0)

    def test_real_interleaved_gltf_and_sidecar_geometry(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            positions = [(-1.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)]
            binary = b"".join(struct.pack("<ffff", *p, 99) for p in positions) + struct.pack("<HHH", 0, 1, 2)
            (root / "geometry.bin").write_bytes(binary)
            gltf = {"asset": {"version": "2.0"}, "buffers": [{"uri": "geometry.bin", "byteLength": len(binary)}],
                    "bufferViews": [{"buffer": 0, "byteLength": 48, "byteStride": 16}, {"buffer": 0, "byteOffset": 48, "byteLength": 6}],
                    "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"},
                                  {"bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"}],
                    "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1}]}]}
            source = root / "triangle.gltf"
            source.write_text(json.dumps(gltf))
            data, receipt = prepare(source)
            self.assertEqual(data[:8], MAGIC)
            self.assertEqual(struct.unpack_from("<IIII", data, 8), (1, 64, 96, 1))
            mesh, part, vertices, indices, count, digest = struct.unpack_from("<IIIIIQ", data, 24)
            self.assertEqual((mesh, part, vertices, indices, count), (0, 0, 3, 3, 1))
            self.assertEqual(digest, geometry_digest(positions, [0, 1, 2]))
            self.assertEqual(struct.unpack_from("<IIffffff", data, 52), (0, 3, -1, 0, 0, 1, 1, 0))
            self.assertEqual(receipt["primitiveOrder"], "preserved")
            old = receipt["dependencies"]["geometry.bin"]
            (root / "geometry.bin").write_bytes(binary[:-2] + struct.pack("<H", 0))
            _, changed = prepare(source)
            self.assertNotEqual(old, changed["dependencies"]["geometry.bin"])

    def test_scan_keeps_duplicates_degenerates_and_consecutive_ranges(self):
        positions = [(float(i), 0, 0) for i in range(66)]
        indices = list(range(66)) + [0, 0, 0, 2, 1, 0]
        clusters = scan(positions, indices)
        self.assertEqual([(c[0], c[1]) for c in clusters], [(0, 63), (63, 9)])
        self.assertEqual(sum(c[1] for c in clusters), len(indices))
        with self.assertRaises(ValueError):
            scan(positions, [0, 1, 100])


if __name__ == "__main__":
    unittest.main()
