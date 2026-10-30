"""Bake real static GLB geometry to cached mesh SDFs and a tiled scene union.

Closed orientable components use signed nearest-triangle distances. Open or
nonmanifold components use a declared two-sided shell. No collider geometry is
used. Requires NumPy, Pillow and clang++/g++; native code runs offline only.
"""
import argparse
import ctypes
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import numpy as np
from gi_glb import GLB, matrix

ROOT = Path(__file__).resolve().parents[2]
MAX_BYTES = 32 * 1024 * 1024
ENCODING = 'signed-distance-r32f-slices-v1'


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def vector(value):
    return np.asarray([value[k] for k in 'xyz'] if isinstance(value, dict) else value, dtype=float)


def xyz(value):
    return dict(zip('xyz', map(float, value)))


def classify(triangles, weld=1e-5):
    """Weld only for topology; all distances retain the original triangle positions."""
    faces = np.asarray(triangles, dtype=np.float64).copy()
    if faces.ndim != 3 or faces.shape[1:] != (3, 3) or not len(faces) or len(faces) > 5000000:
        raise ValueError('A nonempty bounded triangle array is required')
    if not np.isfinite(faces).all() or np.max(np.abs(faces)) > 1e7:
        raise ValueError('Nonfinite or unreasonably distant geometry')
    area = np.linalg.norm(np.cross(faces[:, 1]-faces[:, 0], faces[:, 2]-faces[:, 0]), axis=1)
    if np.any(area < 1e-12):
        raise ValueError('Degenerate triangles cannot define an SDF surface')
    _, indices = np.unique(np.rint(faces.reshape(-1, 3)/weld).astype(np.int64), axis=0, return_inverse=True)
    indices = indices.reshape(-1, 3)
    parents = np.arange(len(faces))
    def find(i):
        while parents[i] != i:
            parents[i] = parents[parents[i]]
            i = parents[i]
        return i
    edges = {}
    for i, face in enumerate(indices):
        for a, b in zip(face, np.roll(face, -1)):
            key = (min(a, b), max(a, b))
            previous = edges.setdefault(key, [])
            previous.append((i, a < b))
    # A material batch may contain several closed solids touching along an
    # edge. A four-use shared edge must not glue those solids into one invalid
    # manifold; ordinary two-use edges still connect their face interiors.
    for uses in edges.values():
        if len(uses) == 2:
            parents[find(uses[0][0])] = find(uses[1][0])
    groups = {}
    for i in range(len(faces)):
        groups.setdefault(find(i), []).append(i)
    bad = set()
    for uses in edges.values():
        local = {}
        for i, direction in uses:
            local.setdefault(find(i), []).append(direction)
        for root, directions in local.items():
            if len(directions) != 2 or directions[0] == directions[1]:
                bad.add(root)
    solid = np.zeros(len(faces), dtype=np.int32)
    closed_count = open_count = 0
    for root, group in groups.items():
        ix = np.asarray(group)
        points = faces[ix]
        # Translate near the component to avoid cancellation far from the origin.
        points = points - points[0, 0]
        volume = np.einsum('ij,ij->i', points[:, 0], np.cross(points[:, 1], points[:, 2])).sum()/6
        if root not in bad and abs(volume) > 1e-12:
            solid[ix] = 1
            if volume < 0:
                faces[ix] = faces[ix][:, [0, 2, 1]]
            closed_count += 1
        else:
            open_count += 1
    return faces, solid, dict(closedComponents=closed_count, shellComponents=open_count,
                             closedTriangles=int(solid.sum()), shellTriangles=int((solid == 0).sum()),
                             topologyWeldMetres=weld)


class MeshDistance:
    def __init__(self, triangles, cache=None, shell=.075, workers=4):
        if not math.isfinite(shell) or not 0 <= shell <= 1:
            raise ValueError('Invalid shell half-width')
        self.shell = shell
        self.workers = max(1, min(int(workers), 8))
        self.faces, solid, self.topology = classify(triangles)
        source = Path(__file__).with_name('sdf_trace.cpp')
        cache = Path(cache or ROOT/'.build-tools/sdf-baker')
        cache.mkdir(parents=True, exist_ok=True)
        suffix = '.dll' if os.name == 'nt' else '.dylib' if os.uname().sysname == 'Darwin' else '.so'
        library = cache/('sdf-'+digest(source)[:16]+suffix)
        if not library.exists():
            compiler = shutil.which('clang++') or shutil.which('g++')
            if not compiler:
                raise RuntimeError('Install clang++/g++ for the offline SDF baker')
            flags = ['-std=c++17', '-O3', '-shared']
            flags += ['-fms-runtime-lib=dll', '-D_MT', '-D_DLL', '-lucrt', '-lvcruntime', '-lmsvcprt',
                      '-lmsvcrt', '-Xlinker', '/NODEFAULTLIB:libcmt'] if os.name == 'nt' else ['-fPIC', '-pthread']
            subprocess.run([compiler, *flags, str(source), '-o', str(library)], check=True)
        self.lib = ctypes.CDLL(str(library))
        f = ctypes.POINTER(ctypes.c_float)
        self.lib.sdf_create.argtypes = [f, ctypes.POINTER(ctypes.c_int32), ctypes.c_int]
        self.lib.sdf_create.restype = ctypes.c_void_p
        self.lib.sdf_destroy.argtypes = [ctypes.c_void_p]
        self.lib.sdf_distance.argtypes = [ctypes.c_void_p, f, ctypes.c_int, ctypes.c_float, f, ctypes.c_int]
        faces = np.ascontiguousarray(self.faces, dtype=np.float32)
        self.handle = self.lib.sdf_create(faces.ctypes.data_as(f), solid.ctypes.data_as(ctypes.POINTER(ctypes.c_int32)), len(faces))
        if not self.handle:
            raise ValueError('Cannot construct mesh distance BVH')

    def __del__(self):
        if getattr(self, 'handle', None):
            self.lib.sdf_destroy(self.handle)

    def distances(self, points):
        points = np.asarray(points)
        if points.shape[-1:] != (3,) or not np.isfinite(points).all():
            raise ValueError('Finite 3D query points required')
        shape = points.shape[:-1]
        data = np.ascontiguousarray(points.reshape(-1, 3), dtype=np.float32)
        output = np.empty(len(data), dtype=np.float32)
        f = ctypes.POINTER(ctypes.c_float)
        self.lib.sdf_distance(self.handle, data.ctypes.data_as(f), len(data), self.shell, output.ctypes.data_as(f), self.workers)
        if not np.isfinite(output).all():
            raise ValueError('Nonfinite SDF result')
        return output.reshape(shape)


def layout(counts, columns=None):
    counts = np.asarray(counts, dtype=int)
    if counts.shape != (3,) or np.any(counts < 2) or np.any(counts > 4096):
        raise ValueError('Invalid SDF grid dimensions')
    nx, ny, nz = map(int, counts)
    candidates = [columns] if columns is not None else range(1, min(nz, 64)+1)
    allowed = []
    for col in candidates:
        if not isinstance(col, (int, np.integer)) or not 1 <= col <= nz:
            continue
        width, height = nx*col, ny*math.ceil(nz/col)
        if max(width, height) <= 4096 and width*height*4 <= MAX_BYTES:
            allowed.append((max(width, height), width*height, int(col), width, height))
    if not allowed:
        raise ValueError('SDF exceeds 4096 atlas dimensions or the 32 MiB budget')
    _, _, columns, width, height = min(allowed)
    return columns, width, height


def grid_bounds(faces, voxel):
    lo = np.floor(faces.reshape(-1, 3).min(axis=0)/voxel)*voxel-voxel*2
    hi = np.ceil(faces.reshape(-1, 3).max(axis=0)/voxel)*voxel+voxel*2
    counts = np.rint((hi-lo)/voxel).astype(int)+1
    layout(counts)
    return lo, counts


def grid_points(minimum, voxel, counts, z):
    nx, ny, _ = counts
    yy, xx = np.mgrid[:ny, :nx]
    return np.stack([minimum[0]+xx*voxel, minimum[1]+yy*voxel,
                     np.full_like(xx, minimum[2]+z*voxel, dtype=float)], axis=-1)


def write_field(directory, values, minimum, voxel, topology=None, columns=None):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    nz, ny, nx = values.shape
    columns, width, height = layout([nx, ny, nz], columns)
    fill = float(np.linalg.norm(np.asarray(values.shape)*voxel)+voxel)
    atlas = np.full((height, width), fill, dtype='<f4')
    for z in range(nz):
        x, y = (z % columns)*nx, (z//columns)*ny
        atlas[y:y+ny, x:x+nx] = values[z]
    (directory/'Field.r32f').write_bytes(atlas.tobytes())
    m = dict(version=1, encoding=ENCODING, minimum=xyz(minimum), voxelSize=float(voxel),
             counts=[nx, ny, nz], atlasColumns=columns, data='Field.r32f')
    if topology:
        m['geometry'] = topology
    (directory/'Field.sdf3d').write_text(json.dumps(m, indent=2)+'\n', encoding='utf-8')
    return m


def load_field(directory):
    directory = Path(directory)
    m = json.loads((directory/'Field.sdf3d').read_text(encoding='utf-8'))
    if m['version'] != 1 or m['encoding'] != ENCODING or m['data'] != 'Field.r32f':
        raise ValueError('Invalid cached SDF manifest')
    columns, width, height = layout(m['counts'], m.get('atlasColumns', 1))
    raw = (directory/'Field.r32f').read_bytes()
    if len(raw) != width*height*4:
        raise ValueError('Invalid cached SDF byte count')
    atlas = np.frombuffer(raw, dtype='<f4').reshape(height, width)
    if not np.isfinite(atlas).all():
        raise ValueError('Invalid cached SDF data')
    nx, ny, nz = m['counts']
    values = np.stack([atlas[(z//columns)*ny:(z//columns+1)*ny, (z % columns)*nx:(z % columns+1)*nx]
                       for z in range(nz)])
    return m, values


def sample(values, minimum, voxel, points):
    counts = np.asarray(values.shape[::-1])
    position = (points-minimum)/voxel
    clamped = np.clip(position, 0, counts-1)
    base = np.minimum(np.floor(clamped).astype(int), counts-2)
    fraction = clamped-base
    output = np.zeros(points.shape[:-1])
    for z in range(2):
        for y in range(2):
            for x in range(2):
                offset = np.array([x, y, z])
                weight = np.prod(np.where(offset, fraction, 1-fraction), axis=-1)
                at = base+offset
                output += values[at[..., 2], at[..., 1], at[..., 0]]*weight
    outside = np.linalg.norm((position-clamped)*voxel, axis=-1)
    # Lipschitz lower bound outside the cache, continuous at its boundary.
    # Adding the two distances would overstep surfaces near diagonal corners.
    return np.where(outside > 0, np.maximum(outside, output-outside), output)


def bake(scene, output, cache, voxel=.10, shell=None, workers=4, columns=None):
    scene, output, cache = Path(scene).resolve(), Path(output).resolve(), Path(cache).resolve()
    if not math.isfinite(voxel) or not .01 <= voxel <= 1:
        raise ValueError('Voxel size must be between .01 and 1 metre')
    shell = .75*voxel if shell is None else shell
    config = json.loads(scene.read_text(encoding='utf-8-sig'))
    if not 1 <= len(config['models']) <= 256:
        raise ValueError('Scene requires 1..256 static models')
    dependencies = [scene, Path(__file__), Path(__file__).with_name('sdf_trace.cpp'), Path(__file__).with_name('gi_glb.py'), Path(__file__).with_name('gi_transport.py')]
    instances, geometry = [], []
    settings = dict(voxel=voxel, shell=shell, code={p.name: digest(p) for p in dependencies[1:]})
    for i, entry in enumerate(config['models']):
        path = (scene.parent/entry['file']).resolve()
        dependencies.append(path)
        records = GLB(path).collect(np.eye(4), False)
        faces = np.concatenate([r['faces'] for r in records])
        transform = matrix(entry.get('transform', {}))
        if not np.isfinite(transform).all() or not np.allclose(transform[3], [0, 0, 0, 1]):
            raise ValueError('Finite affine model transform required')
        scale = np.linalg.svd(transform[:3, :3], compute_uv=False).min()
        if scale < 1e-5:
            raise ValueError('Singular or subresolution model transform')
        key = hashlib.sha256(json.dumps(dict(source=digest(path), **settings), sort_keys=True).encode()).hexdigest()[:24]
        directory = cache/key
        if (directory/'Field.sdf3d').exists():
            cache_report = json.loads((directory/'Cache.json').read_text(encoding='utf-8'))
            if cache_report['key'] != key or any(digest(directory/name) != h for name, h in cache_report['outputs'].items()):
                raise ValueError('Mesh SDF cache integrity check failed; remove only the named cache entry and rebuild')
            m, values = load_field(directory)
        else:
            tracer = MeshDistance(faces, shell=shell, workers=workers)
            minimum, counts = grid_bounds(faces, voxel)
            values = np.empty(tuple(counts[::-1]), dtype=np.float32)
            for z in range(counts[2]):
                values[z] = tracer.distances(grid_points(minimum, voxel, counts, z))
                if z % 25 == 0:
                    print(f'Mesh {i+1}: slice {z+1}/{counts[2]}', flush=True)
            topology = dict(tracer.topology, shellHalfWidthMetres=shell, sourceSHA256=digest(path),
                            convention='negative-inside-closed-union-or-two-sided-open-shell')
            m = write_field(directory, values, minimum, voxel, topology)
            (directory/'Cache.json').write_text(json.dumps(dict(key=key, settings=settings,
                outputs={name:digest(directory/name) for name in ['Field.sdf3d','Field.r32f']}),indent=2)+'\n',encoding='utf-8')
        instances.append((m, values, transform, scale, key))
        geometry.append((np.c_[faces.reshape(-1, 3), np.ones(faces.size//3)]@transform.T)[:, :3].reshape(-1, 3, 3))
    minimum, counts = grid_bounds(np.concatenate(geometry), voxel)
    columns, _, _ = layout(counts, columns)
    result = np.full(tuple(counts[::-1]), np.inf, dtype=np.float32)
    for z in range(counts[2]):
        points = grid_points(minimum, voxel, counts, z)
        for m, values, transform, scale, _ in instances:
            inverse = np.linalg.inv(transform)
            local = points@inverse[:3, :3].T+inverse[:3, 3]
            d = sample(values, vector(m['minimum']), m['voxelSize'], local)*scale
            result[z] = np.minimum(result[z], d)
    if not np.isfinite(result).all():
        raise ValueError('Nonfinite composed field')
    topology = dict(instances=len(instances), shellHalfWidthMetres=shell,
                    convention='minimum-of-transformed-mesh-fields', staticGeometryOnly=True,
                    meshFields=[dict(cacheKey=key, **m.get('geometry', {})) for m, _, _, _, key in instances])
    manifest = write_field(output, result, minimum, voxel, topology, columns)
    report = dict(version=1, inputs={str(p): digest(p) for p in dependencies},
                  outputs={p.name: digest(p) for p in [output/'Field.sdf3d', output/'Field.r32f']},
                  counts=manifest['counts'], atlasColumns=manifest['atlasColumns'], voxelSize=voxel,
                  runtimeBytes=(output/'Field.r32f').stat().st_size, perMeshCache=[key for *_, key in instances],
                  sourceTriangles=sum(len(f) for f in geometry), geometry=topology)
    (output/'Bake.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    return report


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('scene', type=Path)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--cache', type=Path, required=True)
    p.add_argument('--voxel-size', type=float, default=.10)
    p.add_argument('--shell-half-width', type=float)
    p.add_argument('--workers', type=int, default=4)
    p.add_argument('--atlas-columns', type=int)
    a = p.parse_args()
    print(json.dumps(bake(a.scene, a.output, a.cache, a.voxel_size, a.shell_half_width, a.workers, a.atlas_columns), indent=2))
