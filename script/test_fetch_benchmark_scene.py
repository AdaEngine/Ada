import base64
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

import fetch_benchmark_scene as fetch


class BenchmarkFetchTests(unittest.TestCase):
    def package(self, root, uri="mesh.bin", blend_only=False):
        geometry = b"geometry fixture"
        model = {
            "asset": {"version": "2.0"}, "buffers": [{"uri": uri, "byteLength": len(geometry)}],
            "images": [{"uri": "image.png"}], "materials": [{"emissiveFactor": [1, 0.5, 1.00000012], "doubleSided": True}, {"alphaMode": "BLEND"}],
            "textures": [{"source": 0}], "nodes": [{"mesh": 0}], "accessors": [{"count": 3}, {"count": 6}],
            "meshes": [{"primitives": [{"indices": 0, "material": 0}, {"indices": 1, "material": 1}]}],
        }
        if blend_only:
            model["meshes"].insert(0, {"primitives": [{"indices": 1, "material": 1}]})
            model["nodes"] = [{"mesh": 0, "translation": [1, 2, 3], "children": [1]}, {"mesh": 1}]
        data = json.dumps(model).encode()
        png = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")
        archive = {"entry": "scene/model.gltf", "credits": "scene/credits.txt", "geometryBuffer": "scene/mesh.bin",
                   "entrySHA256": hashlib.sha256(data).hexdigest(), "geometryBytes": len(geometry)}
        path = root / "fixture.zip"
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as package:
            package.writestr(archive["entry"], data)
            package.writestr(archive["geometryBuffer"], geometry)
            package.writestr("scene/image.png", png)
            package.writestr(archive["credits"], "Original fixture credits")
        return path, archive, data

    def test_real_zip_preserves_sources_and_builds_named_opaque_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path, archive, source = self.package(root)
            records, excluded = fetch.extract(archive, path, root)
            self.assertEqual((root / "assets/scene/model.gltf").read_bytes(), source)
            profile = json.loads((root / "assets/scene/benchmark-opaque.gltf").read_text())
            self.assertEqual(profile["nodes"], [{"mesh": 0}])
            self.assertEqual(len(profile["meshes"][0]["primitives"]), 1)
            self.assertEqual(excluded, 2)
            self.assertNotIn("images", profile)
            self.assertTrue(profile["materials"][0]["doubleSided"])
            self.assertEqual(records["scene/image.png"]["width"], 1)
            self.assertEqual(records[archive["geometryBuffer"]]["sha256"], hashlib.sha256(b"geometry fixture").hexdigest())

    def test_stale_metadata_is_rejected_before_extraction(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path, archive, _ = self.package(root)
            archive["entrySHA256"] = "0" * 64
            with self.assertRaisesRegex(ValueError, "metadata changed"):
                fetch.extract(archive, path, root)
            self.assertFalse((root / "assets/scene/model.gltf").exists())

    def test_pbr_adaptation_changes_only_the_pinned_export_error(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path, archive, source = self.package(root)
            correction = {"path": "materials/0/emissiveFactor/2", "from": 1.00000012, "to": 1}
            archive["pbrCorrections"] = [correction]
            records, _ = fetch.extract(archive, path, root)
            expected = json.loads(source)
            expected["materials"][0]["emissiveFactor"][2] = 1
            self.assertEqual(json.loads((root / "assets/scene/benchmark-pbr.gltf").read_text()), expected)
            self.assertEqual((root / "assets/scene/model.gltf").read_bytes(), source)
            self.assertEqual(records["scene/benchmark-pbr.gltf"]["corrections"], [correction])
            archive["pbrCorrections"][0]["from"] = 2
            with self.assertRaisesRegex(ValueError, "no longer matches"):
                fetch.extract(archive, path, root)

    def test_blend_only_mesh_is_removed_and_nodes_are_remapped(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path, archive, _ = self.package(root, blend_only=True)
            records, excluded = fetch.extract(archive, path, root)
            profile = json.loads((root / "assets/scene/benchmark-opaque.gltf").read_text())
            self.assertEqual(len(profile["meshes"]), 1)
            self.assertEqual(profile["nodes"], [{"translation": [1, 2, 3], "children": [1]}, {"mesh": 0}])
            self.assertEqual(records["scene/benchmark-opaque.gltf"]["sourceMeshIndices"], [1])
            self.assertEqual(excluded, 4)

    def test_source_dependency_cannot_escape_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path, archive, _ = self.package(root, uri="../../escape.bin")
            with self.assertRaisesRegex(ValueError, "Unsafe"):
                fetch.extract(archive, path, root)
            self.assertFalse((root.parent / "escape.bin").exists())

    def test_corrupt_geometry_crc_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path, archive, _ = self.package(root)
            data = path.read_bytes().replace(b"geometry fixture", b"corrupt! fixture", 1)
            path.write_bytes(data)
            with self.assertRaises(zipfile.BadZipFile):
                fetch.extract(archive, path, root)

    def test_offline_verification_detects_modified_prepared_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path, archive, _ = self.package(root)
            records, _ = fetch.extract(archive, path, root)
            archive.update(id="fixture", downloadName=path.name, archiveBytes=path.stat().st_size,
                           archiveSHA256=fetch.sha256(path), geometrySHA256=records[archive["geometryBuffer"]]["sha256"])
            manifest = {"id": "fixture", "archives": [archive]}
            receipt = {"status": "complete", "dataset": "fixture", "profileGenerator": 2,
                       "archives": [{"id": "fixture", "sha256": archive["archiveSHA256"], "geometrySHA256": archive["geometrySHA256"]}], "files": records}
            (root / "receipt.json").write_text(json.dumps(receipt))
            fetch.verify(manifest, root)
            (root / "assets/scene/image.png").write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "Prepared asset changed"):
                fetch.verify(manifest, root)


if __name__ == "__main__":
    unittest.main()
