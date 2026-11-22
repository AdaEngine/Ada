"""Pack the sample's baked vegetation silhouettes as portable GLBs."""

import array
import json
import math
import struct
import sys


class TexturedMesh:
    def __init__(self):
        self.positions = array.array("f")
        self.normals = array.array("f")
        self.texcoords = array.array("f")
        self.indices = array.array("I")

    def quad(self, corners, normal, uv):
        start = len(self.positions) // 3
        for vertex, texcoord in zip(corners, uv):
            self.positions.extend(vertex)
            self.normals.extend(normal)
            self.texcoords.extend(texcoord)
        self.indices.extend(start + offset for offset in (0, 1, 2, 0, 2, 3))

    def plant(self, x, y, z, width, height, angle):
        for face in range(2):
            a = angle + face * math.pi * 0.5
            dx, dz = math.cos(a) * width / 2, math.sin(a) * width / 2
            u, v = face / 3, (face + 1) / 3
            corners = ((x - dx, y, z - dz), (x + dx, y, z + dz), (x + dx, y + height, z + dz), (x - dx, y + height, z - dz))
            uv = ((u, 1), (v, 1), (v, 0), (u, 0))
            # Follow each card's facing direction with a slight upward tilt. A
            # straight-up normal switches direct lighting off at the view horizon.
            nx, nz = -0.92 * math.sin(a), 0.92 * math.cos(a)
            self.quad(corners, (nx, 0.39, nz), uv)
            self.quad(corners[::-1], (-nx, 0.39, -nz), uv[::-1])

    def save(self, path, texture, *, alpha_masked=True):
        data, views, accessors = bytearray(), [], []

        def view(payload):
            data.extend(bytes(-len(data) % 4))
            views.append({"buffer": 0, "byteOffset": len(data), "byteLength": len(payload)})
            data.extend(payload)
            return len(views) - 1

        for values, arity, kind in (
            (self.positions, 3, "VEC3"),
            (self.normals, 3, "VEC3"),
            (self.texcoords, 2, "VEC2"),
            (self.indices, 1, "SCALAR"),
        ):
            if sys.byteorder != "little":
                values = values[:]
                values.byteswap()
            accessor = {
                "bufferView": view(values.tobytes()),
                "componentType": 5125 if kind == "SCALAR" else 5126,
                "count": len(values) // arity,
                "type": kind,
            }
            if not accessors:
                accessor.update(
                    min=[min(self.positions[i::3]) for i in range(3)], max=[max(self.positions[i::3]) for i in range(3)]
                )
            accessors.append(accessor)
        image = view(texture if isinstance(texture, bytes) else texture.read_bytes())
        material = {
            "pbrMetallicRoughness": {"baseColorTexture": {"index": 0}, "metallicFactor": 0, "roughnessFactor": 1},
            "doubleSided": False,
        }
        if alpha_masked:
            material.update(alphaMode="MASK", alphaCutoff=0.30, emissiveTexture={"index": 0}, emissiveFactor=[0.23, 0.31, 0.18])
        doc = {
            "asset": {"version": "2.0"},
            "scene": 0,
            "scenes": [{"nodes": [0]}],
            "nodes": [{"mesh": 0}],
            "meshes": [
                {
                    "primitives": [
                        {"attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2}, "indices": 3, "material": 0}
                    ]
                }
            ],
            "materials": [material],
            "images": [{"mimeType": "image/png", "bufferView": image}],
            "textures": [{"source": 0, "sampler": 0}],
            "samplers": [{"magFilter": 9729, "minFilter": 9987}],
            "accessors": accessors,
            "bufferViews": views,
            "buffers": [{"byteLength": len(data)}],
        }
        binary = json.dumps(doc, separators=(",", ":")).encode()
        binary += b" " * (-len(binary) % 4)
        data.extend(bytes(-len(data) % 4))
        path.write_bytes(
            struct.pack("<4sIII4s", b"glTF", 2, 28 + len(binary) + len(data), len(binary), b"JSON")
            + binary
            + struct.pack("<I4s", len(data), b"BIN\0")
            + data
        )
