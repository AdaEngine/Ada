"""Exercise the real offline catalog generator with the authored terrain guides."""
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("terrain_documentation", ROOT / "Editor/scripts/update-offline-documentation.py")
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)


class TerrainDocumentationTests(unittest.TestCase):
    def test_both_terrain_guides_have_distinct_stable_ids(self):
        articles = GENERATOR.articles()
        by_source = {article["source"]: article for article in articles}
        self.assertIn("Editor/Documentation/Terrain.md", by_source)
        self.assertEqual(by_source["Editor/Documentation/Terrain.md"]["id"], "EditorTerrain")
        self.assertEqual(by_source["Sources/AdaEngine/AdaEngine.docc/Articles/3D/Terrain.md"]["id"], "Terrain")
        self.assertEqual(len({article["id"] for article in articles}), len(articles))

    def test_editor_guide_links_to_its_bundled_terrain_article(self):
        guide = next(article for article in GENERATOR.articles() if article["id"] == "EditorGuide")
        destinations = {link["destination"] for block in guide["blocks"] for link in block.get("links", [])}
        self.assertIn("EditorTerrain", destinations)


if __name__ == "__main__":
    unittest.main()
