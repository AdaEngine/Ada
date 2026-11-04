"""Check the actual GLB vertex/index buffers and this experiment's asset contract.

This is not a manifold, intersection or artistic-similarity validator.
"""
import hashlib
import json
import math
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parent


def check(path):
    data = path.read_bytes()
    magic, version, total = struct.unpack_from("<4sII", data)
    assert magic == b"glTF" and version == 2 and total == len(data), "Invalid GLB header"
    cursor, chunks = 12, {}
    while cursor < len(data):
        length, kind = struct.unpack_from("<II", data, cursor)
        assert length % 4 == 0 and cursor+8+length <= len(data), "Bad GLB chunk"
        chunks[kind] = data[cursor+8:cursor+8+length]
        cursor += 8+length
    gltf = json.loads(chunks[0x4E4F534A])
    binary = chunks[0x004E4942]
    assert not any("uri" in buffer for buffer in gltf["buffers"]), "Must be self-contained"

    def accessor(index):
        entry = gltf["accessors"][index]
        view = gltf["bufferViews"][entry["bufferView"]]
        fmt = {5121: "B", 5123: "H", 5125: "I", 5126: "f"}[entry["componentType"]]
        width = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[entry["type"]]
        size = struct.calcsize("<"+fmt*width)
        stride = view.get("byteStride", size)
        start = view.get("byteOffset", 0)+entry.get("byteOffset", 0)
        end = start+(entry["count"]-1)*stride+size
        assert stride >= size and end <= len(binary), "Buffer overrun"
        assert end <= view.get("byteOffset", 0)+view["byteLength"], "Accessor exceeds buffer view"
        return [struct.unpack_from("<"+fmt*width, binary, start+i*stride) for i in range(entry["count"])]

    triangles, vertices, min_normal, max_normal = 0, 0, 2, 0
    for mesh in gltf["meshes"]:
        for primitive in mesh["primitives"]:
            assert primitive.get("mode", 4) == 4, "Expected triangle lists"
            attributes = primitive["attributes"]
            positions, normals = accessor(attributes["POSITION"]), accessor(attributes["NORMAL"])
            indices = [value[0] for value in accessor(primitive["indices"])]
            assert len(positions) == len(normals) and len(indices) % 3 == 0
            assert all(0 <= i < len(positions) for i in indices), "Index outside vertex buffer"
            assert all(math.isfinite(x) for v in positions+normals for x in v), "Non-finite geometry"
            assert len(accessor(attributes["TEXCOORD_0"])) == len(positions)
            assert 0 <= primitive["material"] < len(gltf["materials"])
            for normal in normals:
                length = math.sqrt(sum(x*x for x in normal))
                min_normal, max_normal = min(min_normal, length), max(max_normal, length)
                assert abs(length-1) < .002, "Non-unit normal"
            for i in range(0, len(indices), 3):
                a, b, c = [positions[j] for j in indices[i:i+3]]
                u, v = [b[j]-a[j] for j in range(3)], [c[j]-a[j] for j in range(3)]
                normal = [u[1]*v[2]-u[2]*v[1], u[2]*v[0]-u[0]*v[2], u[0]*v[1]-u[1]*v[0]]
                assert sum(x*x for x in normal) > 1e-16, f"Degenerate face: {mesh['name']}"
                # A smooth normal may be nearly perpendicular, but must not point behind its face.
                for j in indices[i:i+3]:
                    assert sum(normal[k]*normals[j][k] for k in range(3)) >= -1e-8, f"Reversed normal: {mesh['name']}"
            vertices += len(positions)
            triangles += len(indices)//3

    nodes = gltf["nodes"]
    parents = {}
    for i, node in enumerate(nodes):
        for child in node.get("children", []):
            assert 0 <= child < len(nodes) and child not in parents, "Invalid hierarchy"
            parents[child] = i
    for i in range(len(nodes)):
        seen = set()
        while i in parents:
            assert i not in seen, "Cycle in node hierarchy"
            seen.add(i)
            i = parents[i]
    required = {"Head", "Torso", "Left arm", "Right arm", "Left leg", "Right leg",
                "Left ember eye", "Right ember eye", "Broken sword", "Round shield"}
    assert required <= {node.get("name") for node in nodes}, "Missing character parts"
    assert not gltf.get("skins") and not gltf.get("animations"), "This is a static asset contract"
    assert not gltf.get("images"), "No image-generation or external texture dependency expected"
    assert triangles < 10000 and len(data) < 1024*1024, "Prototype budget exceeded"
    report = {"passed": True, "asset": str(path.relative_to(ROOT)), "sha256": hashlib.sha256(data).hexdigest(),
              "bytes": len(data), "nodes": len(nodes), "meshes": len(gltf["meshes"]),
              "materials": len(gltf["materials"]), "vertices": vertices, "triangles": triangles,
              "normalLengthRange": [min_normal, max_normal],
              "checks": ["GLB/chunk bounds", "self-contained buffers", "accessor ranges", "index ranges",
                         "finite positions and unit normals", "non-degenerate triangles", "normals agree with winding",
                         "UV counts", "material indices", "acyclic single-parent hierarchy", "named character parts",
                         "static/no-texture contract", "triangle and byte budgets"],
              "notChecked": ["manifoldness", "self-intersections", "rig or deformation quality", "reference similarity"]}
    return report


if __name__ == "__main__":
    result = check(ROOT / "Assets/Models/Skeleton.glb")
    (ROOT / "Evidence/geometry-check.json").write_text(json.dumps(result, indent=2)+"\n", encoding="utf-8")
    print(json.dumps(result, indent=2))
