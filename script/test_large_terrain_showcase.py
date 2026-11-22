import json
import struct
import unittest
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1] / "Editor/Samples/GreenValley"


class GreenValleyTests(unittest.TestCase):
    def test_voxel_canopy_covers_the_same_forest(self):
        terrain = PROJECT / "Assets/Terrain"
        manifest = terrain / "VoxelForest.json"
        self.assertTrue(manifest.is_file(), "The distant forest must have a baked voxel canopy.")
        canopy = json.loads(manifest.read_bytes())
        size = canopy["voxelSize"]
        self.assertEqual(size, 2.5, "Crown silhouettes must sample a 2.5 m voxel grid.")
        crown_centers = []
        triangle_count = 0
        for tile in canopy["tiles"]:
            data = (terrain / tile["file"]).read_bytes()
            json_length, = struct.unpack_from("<I", data, 12)
            model = json.loads(data[20:20 + json_length])
            primitive = model["meshes"][0]["primitives"][0]
            self.assertEqual(model["materials"][primitive["material"]].get("alphaMode", "OPAQUE"), "OPAQUE")
            triangles = model["accessors"][primitive["indices"]]["count"] // 3
            positions = model["accessors"][primitive["attributes"]["POSITION"]]
            self.assertEqual(positions["count"] % 8, 0)
            self.assertEqual(triangles, 12 * (positions["count"] // 8))
            self.assertGreater(triangles, 0)
            triangle_count += triangles
            offset = 28 + json_length + model["bufferViews"][positions["bufferView"]]["byteOffset"]
            for vertex in range(0, positions["count"], 8):
                x, _, z = struct.unpack_from("<3f", data, offset + vertex * 12)
                crown_centers.append((tile["treeDistance"], x, z))
        self.assertLess(triangle_count, 800000, "Dense stands need a shared crown budget.")
        clusters = {440: size, 950: 20}
        crowns = {(distance, int(x // clusters[distance]), int(z // clusters[distance])) for distance, x, z in crown_centers}
        self.assertEqual(len(crowns), len(crown_centers))
        forest = json.loads((terrain / "Forest.aterrain").read_bytes())
        maximum = {prototype["id"]: prototype["maximumDistance"] for prototype in forest["meshPrototypes"]}
        expected = set()
        for region in forest["heightRegions"]:
            placements = (terrain / region["fileName"]).read_bytes()
            for offset in range(40, len(placements), 64):
                species, = struct.unpack_from("<H", placements, offset + 8)
                x, _, z = struct.unpack_from("<3f", placements, offset + 12)
                distance = maximum[species]
                ix, iz = (int((region[axis] * 256 + value) * forest["spacing"] // clusters[distance])
                          for axis, value in (("x", x), ("z", z)))
                expected.add((distance, ix, iz))
        self.assertEqual(crowns, expected)

    def test_free_flight_has_its_own_controls(self):
        project = json.loads((PROJECT / ".ada/project.json").read_bytes())
        bindings = {action["name"]: action["bindings"][0]["key"]["_0"] for action in project["inputActions"]}
        self.assertEqual(bindings.get("FreeFlight"), "f")
        self.assertEqual(bindings.get("Fly"), "g")
        self.assertEqual(bindings.get("Ascend"), " ")
        self.assertEqual(bindings.get("Descend"), "ctrl")

    def test_trail_uses_a_painted_soil_layer_across_region_boundaries(self):
        terrain = PROJECT / "Assets/Terrain"
        manifest = json.loads((terrain / "Valley.aterrain").read_bytes())
        soil = next((layer for layer in manifest["materials"]["layers"] if layer.get("albedoPath") == "trail-earth.png"), None)
        self.assertIsNotNone(soil, "The trail soil must be a terrain material.")
        self.assertTrue((terrain / soil["albedoPath"]).is_file())
        scene = json.loads((PROJECT / "Assets/Scenes/Main.ascn").read_bytes())
        self.assertFalse(any(entity["id"] == "trail" for entity in scene["entities"]))
        strongest_by_row = {}
        for region in manifest["heightRegions"]:
            data = (terrain / region["fileName"]).read_bytes()
            if not data.startswith(b"ADATRN03"):
                continue
            sections = struct.unpack_from("<I", data, 16)[0]
            payload = 24 + 16 * sections
            for index in range(sections):
                tag, _, count, length = struct.unpack_from("<HHIQ", data, 24 + index * 16)
                if tag == 3:
                    self.assertEqual(length, count * 64)
                    for record in range(count):
                        x, z, layer, strength = struct.unpack_from("<BB2xH22xf", data, payload + record * 64)
                        self.assertEqual(layer, soil["id"])
                        self.assertTrue(0 < strength <= 1)
                        grid_z = region["z"] * 256 + z
                        strongest_by_row[grid_z] = max(strongest_by_row.get(grid_z, 0), strength)
                payload += length
            self.assertEqual(payload, len(data))
        for grid_z in range(-425, 426):
            self.assertGreater(strongest_by_row.get(grid_z, 0), 0.85)

    def test_forest_instances_reference_three_dimensional_tree_meshes(self):
        terrain = PROJECT / "Assets/Terrain"
        forest = json.loads((terrain / "Forest.aterrain").read_bytes())
        main = json.loads((terrain / "Valley.aterrain").read_bytes())
        grass = json.loads((terrain / "Grass.aterrain").read_bytes())
        models = {p["assetPath"]: p for source in (main, forest, grass) for p in source["meshPrototypes"]}
        for name, minimum in (("coastal-tree", 60000), ("coastal-grove", 4000), ("coastal-remote", 1000)):
            file = name + ".glb"
            self.assertIn(file, models)
            self.assertNotIn("pathTracingMaximumDistance", models[file])
            raw = (terrain / file).read_bytes()
            document = json.loads(raw[20:20 + struct.unpack_from("<I", raw, 12)[0]])
            parts = [part for mesh in document["meshes"] for part in mesh["primitives"]]
            self.assertGreaterEqual(len({part["material"] for part in parts}), 2)
            self.assertGreaterEqual(sum(document["accessors"][p["indices"]]["count"] // 3 for p in parts), minimum)
            leaves = max(parts, key=lambda p: document["accessors"][p["attributes"]["POSITION"]]["count"])
            bounds = document["accessors"][leaves["attributes"]["POSITION"]]
            self.assertTrue(all(hi - lo > 0.5 for lo, hi in zip(bounds["min"], bounds["max"])))
        ids = set()
        for region in forest["heightRegions"]:
            data = (terrain / region["fileName"]).read_bytes()
            tag, version, count, length = struct.unpack_from("<HHIQ", data, 24)
            self.assertEqual((tag, version, length, len(data)), (2, 1, count * 64, 40 + count * 64))
            for offset in range(40, len(data), 64):
                placement, prototype = struct.unpack_from("<QH", data, offset)
                self.assertIn(prototype, (1, 2))
                self.assertNotIn(placement, ids)
                ids.add(placement)
        self.assertEqual(len(ids), 152167)
        for name, cutoff in (("meadow-patch", 150), ("grass", 120), ("meadow-grass", 90)):
            prototype = models[name + ".glb"]
            self.assertEqual(prototype["maximumDistance"], cutoff)
            self.assertEqual(prototype["pathTracingMaximumDistance"], cutoff)

    def test_detailed_plants_are_packaged_with_embedded_textures(self):
        terrain = PROJECT / "Assets/Terrain"
        world = json.loads((terrain / "Valley.aterrain").read_text())
        by_name = {item["assetPath"]: item for item in world["meshPrototypes"]}
        for name, minimum in (("wild-syringa", 50000), ("understory", 7000), ("fern", 2000), ("meadow-grass", 1000)):
            file = name + ".glb"
            with self.subTest(plant=name):
                self.assertIn(file, by_name)
                self.assertGreater(by_name[file]["maximumDistance"], 0)
                raw = (terrain / file).read_bytes()
                magic, version, size, length, tag = struct.unpack_from("<4sIII4s", raw)
                self.assertEqual((magic, version, size, tag), (b"glTF", 2, len(raw), b"JSON"))
                model = json.loads(raw[20:20 + length])
                triangles = sum(model["accessors"][part["indices"]]["count"] // 3
                                for mesh in model["meshes"] for part in mesh["primitives"])
                self.assertGreaterEqual(triangles, minimum)
                self.assertTrue(any(material.get("alphaMode") == "MASK" for material in model["materials"]))
                self.assertTrue(model["images"])
                self.assertTrue(all("bufferView" in image for image in model["images"]))

    def test_tall_grass_reaches_every_playable_region(self):
        terrain = PROJECT / "Assets/Terrain"
        manifest = json.loads((terrain / "Grass.aterrain").read_bytes())
        meadow = next((model for model in manifest["meshPrototypes"] if model["assetPath"] == "field-grass.glb"), None)
        self.assertIsNotNone(meadow, "The world-wide grass prototype must be packaged.")
        raw = (terrain / meadow["assetPath"]).read_bytes()
        glb = json.loads(raw[20:20 + struct.unpack_from("<I", raw, 12)[0]])
        self.assertGreater(glb["accessors"][0]["max"][1], 1.0)
        self.assertEqual(len(manifest["heightRegions"]) * (256 * manifest["spacing"]) ** 2, 4000 ** 2)
        placements = set()
        for region in manifest["heightRegions"]:
            with self.subTest(region=region["fileName"]):
                data = (terrain / region["fileName"]).read_bytes()
                sections = struct.unpack_from("<I", data, 16)[0]
                payload = 24 + 16 * sections
                quadrants = [0] * 4
                for index in range(sections):
                    tag, _, count, length = struct.unpack_from("<HHIQ", data, 24 + 16 * index)
                    if tag == 2:
                        for record in range(count):
                            offset = payload + record * 64
                            placement, prototype = struct.unpack_from("<QH", data, offset)
                            self.assertNotIn(placement, placements)
                            placements.add(placement)
                            if prototype == meadow["id"]:
                                self.assertTrue(placement & (1 << 30))
                                x, _, z = struct.unpack_from("<3f", data, offset + 12)
                                quadrants[(x >= 128) + 2 * (z >= 128)] += 1
                    payload += length
                self.assertGreater(min(quadrants), 340)

    def test_outer_hills_share_playable_height_samples_at_the_border(self):
        terrain = PROJECT / "Assets/Terrain"
        raw = (terrain / "horizon.glb").read_bytes()
        size = struct.unpack_from("<I", raw, 12)[0]
        glb = json.loads(raw[20:20 + size])
        offset = 28 + size + glb["bufferViews"][0]["byteOffset"]
        count = glb["accessors"][0]["count"]
        border = set()
        for i in range(0, count, 3):
            a, b, c = (struct.unpack_from("<3f", raw, offset + (i + vertex) * 12) for vertex in range(3))
            self.assertGreaterEqual(max(abs((a[0] + b[0] + c[0]) / 3), abs((a[2] + b[2] + c[2]) / 3)), 2000)
            border.update((x, z) for x, _, z in (a, b, c) if max(abs(x), abs(z)) == 2000)
        edge = range(-512, 513)
        self.assertEqual(border, {
            (x, z) for i in edge for x, z in (
                (i * 3.90625, -2000), (i * 3.90625, 2000), (-2000, i * 3.90625), (2000, i * 3.90625)
            )
        })

    def test_playable_map_footprint_and_vegetation(self):
        terrain = PROJECT / "Assets/Terrain"
        manifest = terrain / "Valley.aterrain"
        self.assertTrue(manifest.is_file(), "Playable terrain manifest is missing")
        world = json.loads(manifest.read_text())
        physical_tiles = 0
        population = 0
        for region in world["heightRegions"]:
            data = (terrain / region["fileName"]).read_bytes()
            self.assertEqual(struct.unpack_from("<ii", data, 8), (region["x"], region["z"]))
            if data.startswith((b"ADATRN02", b"ADATRN03")):
                sections = struct.unpack_from("<I", data, 16)[0]
                payload = 24 + 16 * sections
                for i in range(sections):
                    tag, version, count, length = struct.unpack_from("<HHIQ", data, 24 + i * 16)
                    self.assertEqual(version, 1)
                    if tag == 1:
                        physical_tiles += struct.unpack_from("<I", data, payload)[0]
                    if tag == 2:
                        self.assertEqual(length, 64 * count)
                        population += count
                    payload += length
                self.assertEqual(payload, len(data))
            else:
                self.assertEqual(data[:8], b"ADATRN01")
                physical_tiles += struct.unpack_from("<I", data, 16)[0]
        self.assertEqual(physical_tiles * (64 * world["spacing"]) ** 2, 4000 ** 2)
        self.assertGreater(population, 10000)
        self.assertGreaterEqual(len(world["meshPrototypes"]), 5)
        for prototype in world["meshPrototypes"]:
            self.assertTrue((terrain / prototype["assetPath"]).is_file())


if __name__ == "__main__":
    unittest.main()
