"""Independent checks on the actual authored GLB: bind pose, weights and loop seam.

Uses only the standard library. Artistic deformation and intersections still need visual review.
"""
import hashlib
import argparse
import json
import math
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parent


def identity():
    return [[float(i == j) for j in range(4)] for i in range(4)]


def multiply(a, b):
    return [[sum(a[i][k]*b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def transform(matrix, vector):
    return [sum(matrix[i][j]*vector[j] for j in range(4)) for i in range(4)]


def matrix(node):
    if "matrix" in node:
        return [[node["matrix"][j*4+i] for j in range(4)] for i in range(4)]
    x, y, z, w = node.get("rotation", [0, 0, 0, 1])
    s = node.get("scale", [1, 1, 1])
    t = node.get("translation", [0, 0, 0])
    rows = [[1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w)],
            [2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w)],
            [2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)]]
    return [[rows[i][j]*s[j] for j in range(3)]+[t[i]] for i in range(3)]+[[0, 0, 0, 1]]


class GLB:
    def __init__(self, path):
        data = path.read_bytes()
        magic, version, size = struct.unpack_from("<4sII", data)
        assert magic == b"glTF" and version == 2 and size == len(data)
        offset, chunks = 12, {}
        while offset < len(data):
            size, kind = struct.unpack_from("<II", data, offset)
            assert size % 4 == 0 and offset+8+size <= len(data)
            chunks[kind] = data[offset+8:offset+8+size]
            offset += size+8
        self.doc, self.binary = json.loads(chunks[0x4E4F534A]), chunks[0x004E4942]
        nodes = self.doc["nodes"]
        parents = {child: i for i, node in enumerate(nodes) for child in node.get("children", [])}
        self.globals = {}

        def world(i):
            if i not in self.globals:
                self.globals[i] = multiply(world(parents[i]), matrix(nodes[i])) if i in parents else matrix(nodes[i])
            return self.globals[i]
        for i in range(len(nodes)):
            world(i)

    def accessor(self, index):
        entry = self.doc["accessors"][index]
        view = self.doc["bufferViews"][entry["bufferView"]]
        code = {5123: "H", 5125: "I", 5126: "f"}[entry["componentType"]]
        width = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}[entry["type"]]
        fmt = "<"+code*width
        stride = view.get("byteStride", struct.calcsize(fmt))
        start = view.get("byteOffset", 0)+entry.get("byteOffset", 0)
        end = start+(entry["count"]-1)*stride+struct.calcsize(fmt)
        assert end <= len(self.binary) and end <= view.get("byteOffset", 0)+view["byteLength"]
        return [struct.unpack_from(fmt, self.binary, start+i*stride) for i in range(entry["count"])]


def check(path=None):
    path = path or ROOT / "Assets/Models/Skeleton-Walk.glb"
    rig, source = GLB(path), GLB(ROOT / "Assets/Models/Skeleton.glb")
    assert len(rig.doc["skins"]) == 1
    skin = rig.doc["skins"][0]
    assert len(skin["joints"]) == 23 and len(set(skin["joints"])) == 23
    inverse = rig.accessor(skin["inverseBindMatrices"])
    palettes = [multiply(rig.globals[joint], [[bind[j*4+i] for j in range(4)] for i in range(4)])
                for joint, bind in zip(skin["joints"], inverse)]
    expected, expected_normals = {}, {}
    for i, node in enumerate(source.doc["nodes"]):
        if "mesh" not in node:
            continue
        for primitive in source.doc["meshes"][node["mesh"]]["primitives"]:
            for position in source.accessor(primitive["attributes"]["POSITION"]):
                expected.setdefault(primitive["material"], []).append(transform(source.globals[i], [*position, 1]))
            # The original generator baked all nonuniform leaf scales; these remaining matrices are rigid.
            world = source.globals[i]
            assert all(abs(sum(world[row][col]**2 for row in range(3))-1) < 1e-4 for col in range(3))
            for normal in source.accessor(primitive["attributes"]["NORMAL"]):
                value = transform(world, [*normal, 0])[:3]
                length = math.sqrt(sum(v*v for v in value))
                expected_normals.setdefault(primitive["material"], []).append([v/length for v in value])
    vertices, blended, rest_error, source_error, sum_error, normal_error, triangles = 0, 0, 0., 0., 0., 0., 0
    for i, node in enumerate(rig.doc["nodes"]):
        if "mesh" not in node:
            continue
        assert node["skin"] == 0
        for primitive in rig.doc["meshes"][node["mesh"]]["primitives"]:
            a = primitive["attributes"]
            assert rig.doc["accessors"][a["JOINTS_0"]]["componentType"] == 5123
            assert rig.doc["accessors"][a["WEIGHTS_0"]]["componentType"] == 5126
            positions, joints, weights = [rig.accessor(a[key]) for key in ["POSITION", "JOINTS_0", "WEIGHTS_0"]]
            normals = rig.accessor(a["NORMAL"])
            assert len(positions) == len(joints) == len(weights) == len(normals)
            indices = [v[0] for v in rig.accessor(primitive["indices"])]
            assert len(indices) % 3 == 0 and all(index < len(positions) for index in indices)
            triangles += len(indices)//3
            original = expected[primitive["material"]]
            assert len(original) == len(positions)
            for normal, original_normal in zip(normals, expected_normals[primitive["material"]]):
                assert all(math.isfinite(x) for x in normal)
                normal_error = max(normal_error, math.dist(normal, original_normal))
                assert abs(sum(x*x for x in normal)-1) < 1e-5
            for offset in range(0, len(indices), 3):
                corners = indices[offset:offset+3]
                a, b, c = [positions[j] for j in corners]
                u, v = [b[k]-a[k] for k in range(3)], [c[k]-a[k] for k in range(3)]
                face = [u[1]*v[2]-u[2]*v[1], u[2]*v[0]-u[0]*v[2], u[0]*v[1]-u[1]*v[0]]
                assert sum(x*x for x in face) > 1e-16
                assert all(sum(face[k]*normals[j][k] for k in range(3)) >= -1e-8 for j in corners)
            for vertex, (p, js, ws) in enumerate(zip(positions, joints, weights)):
                assert all(0 <= joint < 23 for joint in js)
                assert all(math.isfinite(w) and 0 <= w <= 1 for w in ws)
                sum_error = max(sum_error, abs(sum(ws)-1))
                assert sum_error < 1e-5
                influences = sum(w > 1e-6 for w in ws)
                assert 1 <= influences <= 2
                blended += influences == 2
                targets = [transform(palettes[joint], [*p, 1]) for joint in js]
                deformed = [sum(ws[j]*targets[j][axis] for j in range(4)) for axis in range(3)]
                authored = transform(rig.globals[i], [*p, 1])
                rest_error = max(rest_error, math.dist(deformed, authored[:3]))
                source_error = max(source_error, math.dist(authored[:3], original[vertex][:3]))
            vertices += len(positions)
    assert rest_error < 1e-5 and source_error < 1e-5 and normal_error < 1e-5 and blended > 0
    walk = next(clip for clip in rig.doc["animations"] if clip["name"] == "Walk")
    seam_error = 0.
    for channel in walk["channels"]:
        sampler = walk["samplers"][channel["sampler"]]
        times, values = rig.accessor(sampler["input"]), rig.accessor(sampler["output"])
        assert len(times) == len(values) == 49 and times[0][0] == 0 and abs(times[-1][0]-1.2) < 1e-6
        assert all(a[0] < b[0] for a, b in zip(times, times[1:]))
        seam_error = max(seam_error, max(abs(a-b) for a, b in zip(values[0], values[-1])))
        assert seam_error < 1e-6
    return {"passed": True, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "vertices": vertices,
            "triangles": triangles, "joints": 23, "skinnedMeshes": len(rig.doc["meshes"]), "blendedVertices": blended,
            "maximumWeightSumError": sum_error, "maximumBindPoseErrorMeters": rest_error,
            "maximumSourcePositionErrorMeters": source_error, "maximumLoopSeamError": seam_error,
            "maximumSourceNormalError": normal_error,
            "walkDurationSeconds": 1.2, "keysPerTrack": 49,
            "notChecked": ["arbitrary character auto-rigging", "manifoldness", "all possible self-intersections"]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--asset", type=Path, default=ROOT / "Assets/Models/Skeleton-Walk.glb")
    parser.add_argument("--output", type=Path, default=ROOT / "Evidence/Rig/buffer-check.json")
    args = parser.parse_args()
    result = check(args.asset.resolve())
    target = args.output
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(result, indent=2)+"\n", encoding="utf-8")
    print(json.dumps(result, indent=2))
