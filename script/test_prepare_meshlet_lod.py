import os
from pathlib import Path
import unittest

if __package__:
    from .prepare_meshlet_lod import hierarchy
else:
    from prepare_meshlet_lod import hierarchy

TOOL = Path(__file__).resolve().parents[1] / ".build-tools/meshlet-builder" / ("MeshletLOD.exe" if os.name == "nt" else "MeshletLOD")


@unittest.skipUnless(TOOL.is_file(), "Build the pinned native hierarchy tool first")
class PrepareMeshletLODTests(unittest.TestCase):
    def test_actual_simplification_preserves_borders_and_every_cut_covers_source_once(self):
        size = 32
        class CountedPositions(list):
            complete_walks = 0
            def __iter__(self):
                self.complete_walks += 1
                return super().__iter__()
        positions = CountedPositions((float(x), float(y), 0.0) for y in range(size + 1) for x in range(size + 1))
        source = []
        for y in range(size):
            for x in range(size):
                a = y * (size + 1) + x
                source.extend([a, a + 1, a + size + 1, a + 1, a + size + 2, a + size + 1])
        flat, clusters, nodes, roots = hierarchy(positions, source, TOOL)
        self.assertLessEqual(positions.complete_walks, 3, "Hierarchy preparation must not revalidate the entire vertex array per node")

        def own(node):
            values = []
            for cluster in clusters[node[3]:node[3] + node[4]]:
                values.extend(flat[cluster[0]:cluster[0] + cluster[1]])
            return values

        def borders(indices):
            edges = {}
            for offset in range(0, len(indices), 3):
                triangle = indices[offset:offset + 3]
                for i in range(3):
                    edge = tuple(sorted((triangle[i], triangle[(i + 1) % 3])))
                    edges[edge] = edges.get(edge, 0) + 1
            return {edge: count for edge, count in edges.items() if count != 2}

        for i, node in enumerate(nodes):
            if not node[2]:
                self.assertEqual(own(node), source[node[5]:node[5] + node[6]])
                continue
            children = nodes[node[1]:node[1] + node[2]]
            child_indices = [index for child in children for index in own(child)]
            self.assertLess(len(own(node)), len(child_indices))
            self.assertEqual(borders(own(node)), borders(child_indices))
            self.assertTrue(all(child[0] == i and child[-1] <= node[-1] for child in children))

        def cut(threshold, index):
            node = nodes[index]
            if not node[2] or node[-1] <= threshold:
                return [index]
            return [selected for child in range(node[1], node[1] + node[2]) for selected in cut(threshold, child)]

        thresholds = [0.0, *sorted({node[-1] for node in nodes if node[2]}), 1e10]
        counts = []
        for threshold in thresholds:
            selected = [index for root in roots for index in cut(threshold, root)]
            next_source = 0
            for index in selected:
                self.assertEqual(nodes[index][5], next_source)
                next_source += nodes[index][6]
            self.assertEqual(next_source, len(source))
            counts.append(sum(len(own(nodes[index])) for index in selected))
        self.assertEqual(counts[0], len(source))
        self.assertLess(counts[-1], counts[0])
        self.assertEqual(counts, sorted(counts, reverse=True))

    def test_unreducible_independent_triangles_remain_exact_forest_roots(self):
        positions = [(float(i), float(i % 3), 0.0) for i in range(300)]
        source = list(range(300))
        flat, _, nodes, roots = hierarchy(positions, source, TOOL)
        self.assertTrue(all(node[2] == 0 for node in nodes))
        self.assertEqual(flat, source)
        self.assertEqual(len(roots), len(nodes))


if __name__ == "__main__":
    unittest.main()
