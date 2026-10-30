"""Offline SDF geometry, sign, composition, layout and input-budget regressions."""
import json
from pathlib import Path
import struct
import tempfile
import unittest
import numpy as np
from bake_sdf import MeshDistance, bake, classify, grid_bounds, grid_points, layout, load_field, sample, write_field


def box(lo=(-1, -1, -1), hi=(1, 1, 1)):
    lo, hi = np.asarray(lo), np.asarray(hi)
    points = np.array([[x, y, z] for z in (lo[2], hi[2]) for y in (lo[1], hi[1]) for x in (lo[0], hi[0])])
    # Consistent outward faces, welded through actual positions by the baker.
    quads = [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]]
    return np.array([points[[a, b, c]] for a, b, c, d in quads for a, b, c in [(a, b, c), (a, c, d)]], dtype=float)


class SDFTests(unittest.TestCase):
    def test_exact_closed_cube_and_reversed_orientation(self):
        points = np.array([[0, 0, 0], [2, 0, 0], [2, 2, 0], [1, .1, .2], [-.5, 0, 0]])
        expected = [-1, 1, np.sqrt(2), 0, -.5]
        for faces in (box(), box()[:, [0, 2, 1]]):
            mesh = MeshDistance(faces)
            np.testing.assert_allclose(mesh.distances(points), expected, atol=2e-6)
            self.assertEqual(mesh.topology['closedComponents'], 1)
            self.assertEqual(mesh.topology['shellTriangles'], 0)

    def test_overlapping_solids_remain_inside_union(self):
        geometry = np.concatenate([box(), box((-.5, -.75, -.75), (1.5, .75, .75))[:, [0, 2, 1]]])
        mesh = MeshDistance(geometry)
        distances = mesh.distances([[.25, .1, .2], [1.25, 0, 0], [2, 0, 0]])
        self.assertLess(distances[0], 0)
        self.assertAlmostEqual(float(distances[1]), -.25, places=6)
        self.assertAlmostEqual(float(distances[2]), .5, places=6)
        self.assertEqual(mesh.topology['closedComponents'], 2)

    def test_door_opening_is_not_replaced_with_a_collision_box(self):
        geometry = np.concatenate([box((-2, 0, -.12), (-.5, 3, .12)),
                                   box((.5, 0, -.12), (2, 3, .12)),
                                   box((-.5, 2.2, -.12), (.5, 3, .12))])
        mesh = MeshDistance(geometry)
        self.assertGreater(mesh.distances([[0, 1, 0]])[0], .45)
        self.assertLess(mesh.distances([[-1, 1, 0]])[0], 0)
        self.assertLess(mesh.distances([[0, 2.7, 0]])[0], 0)

    def test_two_sided_open_shell_and_thin_closed_surface(self):
        plane = np.array([[[-1, -1, 0], [1, -1, 0], [1, 1, 0]],
                          [[-1, -1, 0], [1, 1, 0], [-1, 1, 0]]], dtype=float)
        mesh = MeshDistance(plane, shell=.075)
        np.testing.assert_allclose(mesh.distances([[0, 0, .05], [0, 0, -.05], [0, 0, .2]]), [-.025, -.025, .125], atol=2e-6)
        self.assertEqual(mesh.topology['shellComponents'], 1)
        self.assertEqual(mesh.topology['closedComponents'], 0)
        thin = MeshDistance(box((-.01, -1, -1), (.01, 1, 1)))
        self.assertAlmostEqual(float(thin.distances([[0, 0, 0]])[0]), -.01, places=6)
        self.assertAlmostEqual(float(thin.distances([[.02, 0, 0]])[0]), .01, places=6)

    def test_baked_lattice_atlas_roundtrip_and_interpolation(self):
        mesh = MeshDistance(box())
        lo, counts = grid_bounds(box(), .2)
        data = np.stack([mesh.distances(grid_points(lo, .2, counts, z)) for z in range(counts[2])])
        with tempfile.TemporaryDirectory() as folder:
            m = write_field(folder, data, lo, .2, columns=4)
            restored, read = load_field(folder)
            self.assertEqual(m, restored)
            np.testing.assert_array_equal(data, read)
            self.assertEqual((Path(folder)/'Field.r32f').stat().st_size,
                             counts[0]*4*counts[1]*int(np.ceil(counts[2]/4))*4)
            self.assertTrue(np.isfinite(np.fromfile(Path(folder)/'Field.r32f', dtype='<f4')).all())
        points = np.array([[0, 0, 0], [1.4, 0, 0], [0, .2, .4]])
        np.testing.assert_allclose(sample(data, lo, .2, points), mesh.distances(points), atol=2e-6)

    def test_translated_instance_min_composition_and_conservative_nonuniform_scale(self):
        mesh = MeshDistance(box())
        lo, counts = grid_bounds(box(), .25)
        data = np.stack([mesh.distances(grid_points(lo, .25, counts, z)) for z in range(counts[2])])
        points = np.array([[0, 0, 0], [3, 0, 0], [1.5, 0, 0]])
        a = sample(data, lo, .25, points)
        b = sample(data, lo, .25, points-[3, 0, 0])
        composed = np.minimum(a, b)
        self.assertLess(composed[0], 0)
        self.assertLess(composed[1], 0)
        self.assertGreater(composed[2], 0)
        local = np.array([[4, 0, 0]])/[2, 1, 1]
        # Minimum singular-value scaling is conservative for a stretched mesh.
        self.assertLessEqual(float(sample(data, lo, .25, local)[0]), 2)

    def test_query_worker_count_is_deterministic(self):
        points = np.random.default_rng(1234).uniform(-2, 2, (10000, 3))
        a = MeshDistance(box(), workers=1).distances(points)
        b = MeshDistance(box(), workers=4).distances(points)
        np.testing.assert_array_equal(a, b)

    def test_real_glb_instances_cache_reuse_and_integrity(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            vertices = np.asarray(box(), dtype='<f4').reshape(-1, 3)
            binary = vertices.tobytes()
            doc = dict(asset=dict(version='2.0'), scene=0, scenes=[dict(nodes=[0])], nodes=[dict(mesh=0)],
                       meshes=[dict(primitives=[dict(attributes=dict(POSITION=0))])], materials=[{}],
                       buffers=[dict(byteLength=len(binary))], bufferViews=[dict(buffer=0, byteLength=len(binary))],
                       accessors=[dict(bufferView=0, componentType=5126, count=len(vertices), type='VEC3')])
            encoded = json.dumps(doc).encode()
            encoded += b' '*(-len(encoded) % 4)
            (root/'Cube.glb').write_bytes(struct.pack('<III',0x46546c67,2,28+len(encoded)+len(binary))+
                struct.pack('<II',len(encoded),0x4e4f534a)+encoded+struct.pack('<II',len(binary),0x004e4942)+binary)
            scene = root/'Scene.sdfscene'
            scene.write_text(json.dumps(dict(models=[dict(file='Cube.glb'),
                dict(file='Cube.glb',transform=dict(position=[3,0,0]))])),encoding='utf-8')
            first = bake(scene,root/'A',root/'Cache',voxel=.25,columns=4)
            second = bake(scene,root/'B',root/'Cache',voxel=.25,columns=4)
            self.assertEqual(first['perMeshCache'][0],first['perMeshCache'][1])
            self.assertEqual(first['outputs'],second['outputs'])
            m, values = load_field(root/'A')
            lo = np.array([m['minimum'][axis] for axis in 'xyz'])
            distances = sample(values,lo,m['voxelSize'],np.array([[0,0,0],[3,0,0],[1.5,0,0]]))
            np.testing.assert_allclose(distances,[-1,-1,.5],atol=2e-6)
            cache = root/'Cache'/first['perMeshCache'][0]/'Field.r32f'
            damaged = bytearray(cache.read_bytes());damaged[0] ^= 1;cache.write_bytes(damaged)
            with self.assertRaisesRegex(ValueError,'integrity'):
                bake(scene,root/'C',root/'Cache',voxel=.25,columns=4)

    def test_invalid_geometry_grid_and_cache_are_rejected(self):
        for faces in (np.zeros((0, 3, 3)), np.zeros((1, 3, 3)), np.full((1, 3, 3), np.nan)):
            with self.assertRaises(ValueError):
                classify(faces)
        for counts in ([1, 2, 2], [5000, 2, 2], [1000, 1000, 1000]):
            with self.assertRaises(ValueError):
                layout(counts)
        with tempfile.TemporaryDirectory() as folder:
            write_field(folder, np.ones((3, 2, 2)), [0, 0, 0], .1, columns=2)
            (Path(folder)/'Field.r32f').write_bytes(b'bad')
            with self.assertRaises(ValueError):
                load_field(folder)


if __name__ == '__main__':
    unittest.main(verbosity=2)
