"""Rebuild Green Valley's original meshes, deterministic plants and native terrain regions."""

import array
import itertools
import json
import math
import random
import struct
import sys
import zlib
from collections import defaultdict
from pathlib import Path

from foliage_cards import TexturedMesh

ROOT = Path(__file__).resolve().parent
ASSETS = ROOT / "Assets"
TERRAIN = ASSETS / "Terrain"
SPACING = 4000 / 1024
SEED = 77123
WIND_PLACEMENT_BIT = 1 << 30
CANOPY_VOXEL_SIZE = 2.5
FOREST_REGION_RANGE = range(-3, 3)
FOREST_VIEW_DISTANCES = {1: 950, 2: 440}
CANOPY_TILE_SIZES = {1: 500, 2: 125}
CANOPY_CLUSTER_SIZES = {1: 20, 2: CANOPY_VOXEL_SIZE}
CANOPY_RING = tuple((math.cos(angle * math.tau / 6), math.sin(angle * math.tau / 6)) for angle in range(6))
GRASS_REGION_SIZE = 500
GRASS_SPACING = GRASS_REGION_SIZE / 256
TRAIL_LAYER = 2
TRAIL_HALF_WIDTH = 2.1
TRAIL_EDGE_BLEND = 2.6


def height(x, z):
    return (
        46 * math.cos(z / 290)
        + 29 * math.sin(x / 240 + z / 410)
        + 65 * (1 - math.cos(x / 350))
        + 8 * math.sin(z / 87 + x / 95)
    )


def trail(z):
    return 36 * math.sin(z / 180)


def forest(x, z):
    return math.sin(x / 89 + z / 167) + 0.65 * math.cos(z / 107) + 0.4 * math.sin(x / 203 - z / 57)


def ground(x, z):
    gx, gz = x / SPACING, z / SPACING
    ix, iz = math.floor(gx), math.floor(gz)
    fx, fz = gx - ix, gz - iz
    return sum(
        weight * height((ix + dx) * SPACING, (iz + dz) * SPACING)
        for dx, wx in enumerate((1 - fx, fx))
        for dz, wz in enumerate((1 - fz, fz))
        for weight in [wx * wz]
    )


def palette_png(rgb):
    def chunk(tag, body):
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body))

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">2I5B", len(rgb) // 3, 1, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(1) + rgb))
        + chunk(b"IEND", b"")
    )


class Model:
    def __init__(self):
        self.faces = defaultdict(list)

    def triangle(self, color, a, b, c):
        self.faces[color].extend((a, b, c))

    def crown(self, color, center, size, rng, sides=7):
        x, y, z = center
        w, h, d = size
        rings = []
        for level, radius in ((-0.82, 0.62), (-0.24, 1), (0.48, 0.89)):
            ring = []
            for i in range(sides):
                angle = (i + level * 0.5) * math.tau / sides
                jitter = rng.uniform(0.83, 1.17)
                ring.append(
                    (
                        x + math.cos(angle) * w * radius * jitter,
                        y + (level + rng.uniform(-0.1, 0.1)) * h,
                        z + math.sin(angle) * d * radius * jitter,
                    )
                )
            rings.append(ring)
        for i in range(sides):
            j = (i + 1) % sides
            self.triangle(color, (x, y - h, z), rings[0][i], rings[0][j])
            for low, high in itertools.pairwise(rings):
                self.triangle(color, low[i], high[i], low[j])
                self.triangle(color, low[j], high[i], high[j])
            self.triangle(color, rings[2][i], (x, y + h, z), rings[2][j])

    def save(self, path):
        data, views, accessors, materials, prims = bytearray(), [], [], [], []

        def channel(values):
            start = len(data)
            for point in values:
                data.extend(struct.pack("<3f", *point))
            views.append({"buffer": 0, "byteOffset": start, "byteLength": len(data) - start})
            accessors.append(
                {
                    "bufferView": len(views) - 1,
                    "componentType": 5126,
                    "count": len(values),
                    "type": "VEC3",
                    "min": list(map(min, zip(*values))),
                    "max": list(map(max, zip(*values))),
                }
            )
            return len(accessors) - 1

        all_positions, all_normals, uv = [], [], []
        for shade, vertices in enumerate(self.faces.values()):
            normals = []
            for i in range(0, len(vertices), 3):
                a, b, c = vertices[i : i + 3]
                u, v = [[p - q for p, q in zip(vertex, a)] for vertex in (b, c)]
                normal = [
                    u[1] * v[2] - u[2] * v[1],
                    u[2] * v[0] - u[0] * v[2],
                    u[0] * v[1] - u[1] * v[0],
                ]
                length = math.hypot(*normal) or 1
                normals.extend([tuple(n / length for n in normal)] * 3)
            all_positions.extend(vertices)
            all_normals.extend(normals)
            uv.extend([(shade + 0.5) / len(self.faces)] * len(vertices))
        positions = channel(all_positions)
        normals = channel(all_normals)
        start = len(data)
        for u in uv:
            data.extend(struct.pack("<2f", u, 0.5))
        views.append({"buffer": 0, "byteOffset": start, "byteLength": len(data) - start})
        accessors.append(
            {
                "bufferView": len(views) - 1,
                "componentType": 5126,
                "count": len(uv),
                "type": "VEC2",
            }
        )
        prims.append(
            {
                "attributes": {
                    "POSITION": positions,
                    "NORMAL": normals,
                    "TEXCOORD_0": len(accessors) - 1,
                },
                "material": 0,
            }
        )

        # A tiny nearest-filtered palette allows every cluster to draw with one material.
        palette = bytes(round(255 * (1.055 * (v ** (1 / 2.4)) - 0.055)) for color in self.faces for v in color)
        png = palette_png(palette)
        views.append({"buffer": 0, "byteOffset": len(data), "byteLength": len(png)})
        data.extend(png)
        data.extend(bytes(-len(data) % 4))
        materials.append(
            {
                "doubleSided": True,
                "pbrMetallicRoughness": {
                    "baseColorTexture": {"index": 0},
                    "metallicFactor": 0,
                    "roughnessFactor": 0.94,
                },
            }
        )
        doc = {
            "asset": {"version": "2.0"},
            "scene": 0,
            "scenes": [{"nodes": [0]}],
            "nodes": [{"mesh": 0}],
            "meshes": [{"primitives": prims}],
            "materials": materials,
            "buffers": [{"byteLength": len(data)}],
            "bufferViews": views,
            "accessors": accessors,
            "textures": [{"sampler": 0, "source": 0}],
            "images": [{"mimeType": "image/png", "bufferView": len(views) - 1}],
            "samplers": [{"magFilter": 9728, "minFilter": 9728, "wrapS": 33071, "wrapT": 33071}],
        }
        js = json.dumps(doc, separators=(",", ":")).encode()
        js += b" " * (-len(js) % 4)
        path.write_bytes(
            struct.pack("<4sII", b"glTF", 2, 28 + len(js) + len(data))
            + struct.pack("<I4s", len(js), b"JSON")
            + js
            + struct.pack("<I4s", len(data), b"BIN\0")
            + data
        )


def plants():
    rng = random.Random(SEED)
    for species, name in enumerate(("oak", "birch", "hazel", "grass", "flowers")):
        model = Model()
        if species < 3:
            radius, top = ((3.3, 9), (1.8, 10), (1.4, 2.5))[species]
            wood = (0.47, 0.42, 0.32) if species == 1 else (0.16, 0.085, 0.035)
            model.crown(wood, (0, top * 0.35, 0), (radius * 0.12, top * 0.4, radius * 0.12), rng)
            for k in range(6):
                angle = k * 2.4
                spread = radius * (0.1 if k == 5 else 0.68)
                color = (
                    (0.075, 0.235, 0.037),
                    (0.18, 0.34, 0.065),
                    (0.09, 0.27, 0.055),
                )[species]
                color = tuple(v * (0.85 + k * 0.06) for v in color)
                model.crown(
                    color,
                    (
                        math.cos(angle) * spread,
                        top * (0.63 + k * 0.055),
                        math.sin(angle) * spread,
                    ),
                    (radius * 0.77, top * 0.23, radius * 0.76),
                    rng,
                )
        else:
            for _ in range(48 if species == 3 else 16):
                x, z = rng.uniform(-1.4, 1.4), rng.uniform(-1.4, 1.4)
                h = rng.uniform(0.26, 0.69)
                model.triangle(
                    (0.21, 0.37, 0.06),
                    (x - 0.04, 0, z),
                    (x + 0.04, 0, z + 0.035),
                    (x + 0.13, h, z),
                )
                if species == 4:
                    model.crown((0.94, 0.66, 0.12), (x + 0.13, h, z), (0.08, 0.04, 0.08), rng, 4)
        model.save(TERRAIN / (name + ".glb"))


def placements(rx, rz):
    rng = random.Random(SEED + (rz + 2) * 4 + rx + 2)
    data = bytearray()
    placement_count = 4600 + (8500 if rx in (-1, 0) and rz in (-1, 0) else 0)
    for i in range(placement_count + 460):
        u, v = rng.random() * 256, rng.random() * 256
        if i >= placement_count:
            # Alternate specimen trees and layered understory along the walking route.
            slot = i - placement_count
            z = -300 + (slot // 4) * 12 + (slot % 4) * 2.3
            side = -1 if (slot // 4 + slot % 4) % 2 else 1
            x = trail(z) + side * (6 + (slot * 7 % 13))
            if slot % 4 == 0 and z < -245:
                x += side * 22
            u, v = x / SPACING - rx * 256, z / SPACING - rz * 256
            if not (0 <= u < 256 and 0 <= v < 256):
                continue
            species = (10 if (slot // 4) % 5 else 6, 7, 8, 9)[slot % 4]
        else:
            if i >= 4600:
                z = rng.uniform(-650, 0) if rz == -1 else rng.uniform(0, 650)
                x = trail(z) + rng.uniform(-60, 60)
                u, v = x / SPACING - rx * 256, z / SPACING - rz * 256
                if not (0 <= u < 256):
                    continue
            x, z = (rx * 256 + u) * SPACING, (rz * 256 + v) * SPACING
            if abs(x - trail(z)) < 4:
                continue
            if i < 1800:
                if forest(x, z) < -0.15 or math.hypot(x, z + 300) < 85:
                    continue
                species = rng.choice((1, 1, 2, 3))
                if species in (1, 2) and abs(x - trail(z)) < 160 and i % 3 != 0:
                    species = 10 if i % 5 else 6
            else:
                if abs(x - trail(z)) > 90 or abs(z) > 650:
                    continue
                species = rng.choice((3, 4, 4, 4, 5))
                if species == 3 and (i % 4 == 0 or abs(x - trail(z)) < 62):
                    species = 7 if i % 12 == 0 else (8 if i % 3 == 0 else 9)
                if species == 4 and (i % 3 != 0 or abs(x - trail(z)) < 40):
                    species = 9
        s = rng.uniform(0.74, 1.32)
        if species == 6:
            s *= 1.7
        elif species == 10:
            s *= 3.25
        elif species == 9:
            s *= 2.4
        a = rng.uniform(-math.pi / 2, math.pi / 2)
        tree_id = (((rz + 2) * 4 + rx + 2) << 32) + i + 1
        data.extend(
            struct.pack(
                "<QHH3f4h3fIIIfI",
                tree_id,
                species,
                0,
                u,
                ground(x, z) / SPACING,
                v,
                0,
                round(32767 * math.sin(a)),
                0,
                round(32767 * math.cos(a)),
                s,
                s,
                s,
                0xFFFFFFFF,
                i,
                0,
                0,
                0,
            )
        )
    return data


def voxel_center(position):
    return (math.floor(position / CANOPY_VOXEL_SIZE) + 0.5) * CANOPY_VOXEL_SIZE


def stamp_canopy(mesh, x, y, z, scale, vertical_scale, yaw):
    """Sample the occupied crown at its poles and around its equator, at 12 triangles per tree."""
    radius = scale * 2.16
    center_y = y + vertical_scale * 2.42
    half_height = vertical_scale * 1.07
    center_x, center_z = voxel_center(x), voxel_center(z)
    # Intersect the central voxel column with the ellipsoid.
    span = half_height * math.sqrt(1 - ((center_x - x) ** 2 + (center_z - z) ** 2) / radius ** 2)
    first = len(mesh.positions) // 3
    vertices = [
        (center_x, voxel_center(center_y + span - CANOPY_VOXEL_SIZE / 2), center_z),
        (center_x, voxel_center(center_y - span + CANOPY_VOXEL_SIZE / 2), center_z),
    ]
    sine, cosine = math.sin(yaw), math.cos(yaw)
    for ux, uz in CANOPY_RING:
        dx, dz = ux * cosine - uz * sine, ux * sine + uz * cosine
        # Walk inward to the outermost occupied voxel along this spoke.
        distance = radius
        vy = voxel_center(center_y + dx * half_height * 0.30)
        horizontal_radius_squared = radius ** 2 * (1 - ((vy - center_y) / half_height) ** 2)
        while True:
            vx, vz = voxel_center(x + dx * distance), voxel_center(z + dz * distance)
            if (vx - x) ** 2 + (vz - z) ** 2 <= horizontal_radius_squared:
                break
            distance -= CANOPY_VOXEL_SIZE / 2
        vertices.append((vx, vy, vz))
    shade = int((math.sin(x / 47) * math.cos(z / 38) + 1) * 1.45)
    for vx, vy, vz in vertices:
        # Normals follow the parent crown surface so individual cells never form flat terraces.
        normal = ((vx - x) / radius ** 2, (vy - center_y) / half_height ** 2, (vz - z) / radius ** 2)
        length = math.hypot(*normal)
        mesh.positions.extend((vx, vy, vz))
        mesh.normals.extend(value / length for value in normal)
        mesh.texcoords.extend(((shade + 0.5) / 3, 0.5))
    for index in range(6):
        current, following = first + index + 2, first + (index + 1) % 6 + 2
        mesh.indices.extend((first, following, current, first + 1, current, following))


def save_voxel_canopy(clusters):
    """Bake opaque indexed meshes so the fine voxel grid stays out of the frame loop."""
    tiles = defaultdict(TexturedMesh)
    for (species, _, _), trees in clusters.items():
        center_x = sum(tree[0] for tree in trees) / len(trees)
        center_z = sum(tree[2] for tree in trees) / len(trees)
        x, y, z, scale, vertical_scale, yaw = min(trees, key=lambda tree: (tree[0] - center_x) ** 2 + (tree[2] - center_z) ** 2)
        tile_size = CANOPY_TILE_SIZES[species]
        tile = (species, math.floor(x / tile_size), math.floor(z / tile_size))
        stamp_canopy(tiles[tile], x, y, z, scale * min(1.27, math.sqrt(len(trees))), vertical_scale, yaw)
    palette = palette_png(bytes((105, 137, 72, 117, 149, 81, 128, 157, 91)))
    manifest = {"voxelSize": CANOPY_VOXEL_SIZE, "tiles": []}
    for (species, tx, tz), mesh in sorted(tiles.items()):
        minimum = [min(mesh.positions[index::3]) for index in range(3)]
        maximum = [max(mesh.positions[index::3]) for index in range(3)]
        filename = f"canopy-{species}-{tx}-{tz}.glb"
        mesh.save(TERRAIN / filename, palette, alpha_masked=False)
        manifest["tiles"].append({
            "file": filename,
            "treeDistance": FOREST_VIEW_DISTANCES[species],
            "bounds": {
                "center": {
                    axis: (low + high) / 2 for axis, low, high in zip("xyz", minimum, maximum)
                },
                "halfExtents": {
                    axis: (high - low) / 2 for axis, low, high in zip("xyz", minimum, maximum)
                },
            },
        })
    (TERRAIN / "VoxelForest.json").write_text(json.dumps(manifest), encoding="utf8")


def forest_regions():
    """Stream actual indexed coastal-tree meshes through GPU-instanced region records."""
    refs = []
    canopy = defaultdict(list)
    for rz in FOREST_REGION_RANGE:
        for rx in FOREST_REGION_RANGE:
            rng = random.Random(SEED + 410 + (rz + 3) * 6 + rx + 3)
            data = bytearray()
            for row in range(77):
                for col in range(77):
                    x = (rx + (col + rng.random()) / 77) * 1000
                    z = (rz + (row + rng.random()) / 77) * 1000
                    distance = abs(x - trail(z))
                    if distance < 15 or (forest(x, z) < -0.55 and distance > 105):
                        continue
                    if ((x - trail(-300)) / 42) ** 2 + ((z + 300) / 30) ** 2 < 1:
                        continue
                    if distance < 35 and rng.random() < 0.54:
                        continue
                    # Mixed stands keep richly branched trees near the trail and a continuous lower-detail forest behind them.
                    detailed = distance < 135 and rng.random() < 0.28
                    species = 2 if detailed else 1
                    scale = rng.uniform(3.2, 5.4)
                    a = rng.uniform(-math.pi / 2, math.pi / 2)
                    seq = row * 77 + col + 1
                    ident = ((rz + 3) * 6 + rx + 3) * 10000 + seq
                    h = ground(x, z) - (2.4 if max(abs(x), abs(z)) >= 2000 else 0.12)
                    vertical_scale = scale * rng.uniform(0.9, 1.2)
                    data.extend(
                        struct.pack(
                            "<QHH3f4h3fIIIfI",
                            ident,
                            species,
                            0,
                            x / SPACING - rx * 256,
                            h / SPACING,
                            z / SPACING - rz * 256,
                            0,
                            round(32767 * math.sin(a)),
                            0,
                            round(32767 * math.cos(a)),
                            scale,
                            vertical_scale,
                            scale,
                            0xFFFFFFFF,
                            seq,
                            0,
                            0,
                            0,
                        )
                    )
                    # Use the written placement coordinates. Rounding a 32-bit record can
                    # move a tree exactly onto a voxel boundary.
                    local_x, local_y, local_z = struct.unpack_from("<3f", data, len(data) - 64 + 12)
                    x, y, z = (rx * 256 + local_x) * SPACING, local_y * SPACING, (rz * 256 + local_z) * SPACING
                    cluster_size = CANOPY_CLUSTER_SIZES[species]
                    cluster = (species, math.floor(x / cluster_size), math.floor(z / cluster_size))
                    canopy[cluster].append((x, y, z, scale, vertical_scale, 2 * a))
            if data:
                file = f"forest-{rx + 3}-{rz + 3}.atregion"
                header = b"ADATRN02" + struct.pack("<iiIIHHIQ", rx, rz, 1, 0, 2, 1, len(data) // 64, len(data))
                (TERRAIN / file).write_bytes(header + data)
                refs.append({"x": rx, "z": rz, "fileName": file})
    forest_manifest = {
        "version": 2,
        "spacing": SPACING,
        "originX": 0,
        "originZ": 0,
        "heightRegions": refs,
        "meshPrototypes": [
            {"id": 1, "assetPath": "coastal-remote.glb", "maximumDistance": FOREST_VIEW_DISTANCES[1]},
            {"id": 2, "assetPath": "coastal-grove.glb", "maximumDistance": FOREST_VIEW_DISTANCES[2]},
        ],
    }
    (TERRAIN / "Forest.aterrain").write_text(json.dumps(forest_manifest), encoding="utf8")
    save_voxel_canopy(canopy)


def cover_record(rx, rz, local_id, species, x, z, scale, yaw):
    if species in (1, 3, 4):
        local_id |= WIND_PLACEMENT_BIT
    placement = (((rz + 4) * 8 + rx + 4) << 32) + local_id
    return struct.pack(
        "<QHH3f4h3fIIIfI",
        placement, species, 0, x / GRASS_SPACING - rx * 256, ground(x, z) / GRASS_SPACING, z / GRASS_SPACING - rz * 256,
        0, round(32767 * math.sin(yaw)), 0, round(32767 * math.cos(yaw)),
        scale, scale, scale, 0xFFFFFFFF, local_id, 0, 0, 0,
    )


def field_cover(rx, rz):
    # One wide clump per 12.5 m cell across the entire playable map.
    data = bytearray()
    rng = random.Random(SEED + 1265 + (rz + 4) * 8 + rx + 4)
    for row in range(40):
        for col in range(40):
            x = rx * GRASS_REGION_SIZE + (col + rng.uniform(0.27, 0.73)) * 12.5
            z = rz * GRASS_REGION_SIZE + (row + rng.uniform(0.27, 0.73)) * 12.5
            if abs(z) < 1700 and abs(x - trail(z)) < 7:
                continue
            data.extend(cover_record(rx, rz, 200000 + row * 40 + col, 3, x, z,
                                     rng.uniform(0.93, 1.16), rng.uniform(-math.pi / 2, math.pi / 2)))
    return data


def meadow_cover(rx, rz):
    """Jitter dense grass and fern clusters beside the footpath."""
    data = bytearray()
    for row in range(972):
        z_base = -1700 + row * 3.5
        if not rz * GRASS_REGION_SIZE - 2 <= z_base <= (rz + 1) * GRASS_REGION_SIZE + 2:
            continue
        for col in range(-9, 10):
            rng = random.Random(SEED + row * 107 + col + 13)
            z = z_base + rng.uniform(-1.2, 1.2)
            x = trail(z) + col * 3.25 + rng.uniform(-1.35, 1.35)
            if abs(x - trail(z)) < 3.6 or not (
                rx * GRASS_REGION_SIZE <= x < (rx + 1) * GRASS_REGION_SIZE
                and rz * GRASS_REGION_SIZE <= z < (rz + 1) * GRASS_REGION_SIZE
            ):
                continue
            species = 2 if rng.random() < 0.21 else 1
            data.extend(cover_record(rx, rz, 100000 + row * 27 + col + 13, species, x, z,
                                     rng.uniform(0.85, 1.26), rng.uniform(-math.pi / 2, math.pi / 2)))
    return data


def trail_verge(rx, rz):
    """Scatter short grass tufts over the shoulders without blocking the footpath."""
    data = bytearray()
    for row in range(-1214, 1215):
        center_z = row * 1.4
        if not rz * GRASS_REGION_SIZE - 1 <= center_z <= (rz + 1) * GRASS_REGION_SIZE + 1:
            continue
        for side_index, side in enumerate((-1, 1)):
            rng = random.Random(SEED + 87361 + (row + 1214) * 2 + side_index)
            z = center_z + rng.uniform(-0.52, 0.52)
            x = trail(z) + side * rng.uniform(3.0, 5.45)
            if rx * GRASS_REGION_SIZE <= x < (rx + 1) * GRASS_REGION_SIZE and rz * GRASS_REGION_SIZE <= z < (rz + 1) * GRASS_REGION_SIZE:
                data.extend(cover_record(rx, rz, 300000 + (row + 1214) * 2 + side_index, 4, x, z,
                                         rng.uniform(0.8, 1.28), rng.uniform(-math.pi / 2, math.pi / 2)))
    return data


def grass_regions():
    refs = []
    for rz in range(-4, 4):
        for rx in range(-4, 4):
            props = field_cover(rx, rz) + meadow_cover(rx, rz) + trail_verge(rx, rz)
            name = f"grass-{rx + 4}-{rz + 4}.atregion"
            header = b"ADATRN02" + struct.pack("<iiIIHHIQ", rx, rz, 1, 0, 2, 1, len(props) // 64, len(props))
            (TERRAIN / name).write_bytes(header + props)
            refs.append({"x": rx, "z": rz, "fileName": name})
    prototypes = [
        {"id": i, "assetPath": name + ".glb", "maximumDistance": distance, "pathTracingMaximumDistance": distance}
        for i, name, distance in ((1, "meadow-patch", 150), (2, "fern-patch", 105), (3, "field-grass", 125), (4, "verge-grass", 48))
    ]
    manifest = {"version": 2, "spacing": GRASS_SPACING, "originX": 0, "originZ": 0,
                "heightRegions": refs, "meshPrototypes": prototypes}
    (TERRAIN / "Grass.aterrain").write_text(json.dumps(manifest), encoding="utf8")


def ground_cover_models():
    rng = random.Random(SEED + 410)
    for name, texture, count, pitch, heights in (
        ("meadow-patch", "grass-silhouette.png", 5, 0.94, (0.52, 0.79)),
        ("fern-patch", "fern-silhouette.png", 5, 0.94, (0.28, 0.43)),
        ("field-grass", "grass-silhouette.png", 6, 1.72, (0.60, 0.85)),
    ):
        mesh = TexturedMesh()
        center = (count - 1) / 2
        for row in range(count):
            for col in range(count):
                x = (col - center + rng.uniform(-0.34, 0.34)) * pitch
                z = (row - center + rng.uniform(-0.34, 0.34)) * pitch
                w = rng.uniform(1.15, 1.83)
                mesh.plant(x, -0.18, z, w, w * rng.uniform(*heights), rng.uniform(0, math.tau))
        mesh.save(TERRAIN / (name + ".glb"), TERRAIN / texture)

    # Model the close shoulder with narrow curved blades so it holds up from eye level.
    blades = Model()
    for _ in range(68):
        x, z = rng.uniform(-1, 1), rng.uniform(-0.8, 0.8)
        angle = rng.uniform(0, math.tau)
        blade_height = rng.uniform(0.20, 0.62)
        dx, dz = 0.032 * math.cos(angle), 0.032 * math.sin(angle)
        bend_x, bend_z = dz * 4.3, -dx * 4.3
        base_a = (x - dx, -0.04, z - dz)
        base_b = (x + dx, -0.04, z + dz)
        knee_a = (x + bend_x * 0.3 - dx * 0.55, blade_height * 0.62, z + bend_z * 0.3 - dz * 0.55)
        knee_b = (x + bend_x * 0.3 + dx * 0.55, blade_height * 0.62, z + bend_z * 0.3 + dz * 0.55)
        tip = (x + bend_x, blade_height, z + bend_z)
        color = rng.choice(((0.11, 0.23, 0.036), (0.16, 0.31, 0.050), (0.21, 0.34, 0.072)))
        blades.triangle(color, base_a, base_b, knee_a)
        blades.triangle(color, knee_a, base_b, knee_b)
        blades.triangle(color, knee_a, knee_b, tip)
    blades.save(TERRAIN / "verge-grass.glb")


def trail_surface(rx, rz):
    """Paint soil into the canonical field shared by every render LOD of the terrain."""
    payload = bytearray()
    for z in range(256):
        world_z = (rz * 256 + z) * SPACING
        if abs(world_z) >= 1700:
            continue
        center = trail(world_z)
        radius = TRAIL_HALF_WIDTH + TRAIL_EDGE_BLEND
        left = max(0, math.ceil((center - radius) / SPACING) - rx * 256)
        right = min(255, math.floor((center + radius) / SPACING) - rx * 256)
        for x in range(left, right + 1):
            world_x = (rx * 256 + x) * SPACING
            edge = (abs(world_x - center) - TRAIL_HALF_WIDTH) / TRAIL_EDGE_BLEND
            blend = max(0, min(1, 1 - edge))
            blend *= blend * (3 - 2 * blend)
            if blend > 0:
                payload.extend(struct.pack("<BB2x4H4ff4f3f4x", x, z, TRAIL_LAYER, 0, 0, 0,
                                           1, 0, 0, 0, blend, 1, 1, 1, 1, 0, 1, 0))
    return payload


def regions():
    refs = []
    for rz in range(-2, 3):
        for rx in range(-2, 3):
            tiles = [(x, z) for z in range(4) for x in range(4) if rx < 2 and rz < 2]
            pages = [(x, z) for z in range(1 if rz == 2 else 4) for x in range(1 if rx == 2 else 4)]
            heights = bytearray(struct.pack("<II", len(tiles), len(pages)))
            for x, z in tiles:
                heights.extend(bytes((x, z, 64, 64)))
            for px, pz in pages:
                heights.extend(bytes((px, pz, 0, 0)))
                page = array.array(
                    "f",
                    (
                        height(
                            (rx * 256 + px * 64 + x) * SPACING,
                            (rz * 256 + pz * 64 + z) * SPACING,
                        )
                        for z in range(64)
                        for x in range(64)
                    ),
                )
                if sys.byteorder != "little":
                    page.byteswap()
                heights.extend(page.tobytes())
            props = placements(rx, rz) if tiles else b""
            surface = trail_surface(rx, rz) if tiles else b""
            if props or surface:
                sections = [(1, len(tiles) + len(pages), heights)]
                if props:
                    sections.append((2, len(props) // 64, props))
                if surface:
                    sections.append((3, len(surface) // 64, surface))
                tag = b"ADATRN03" if surface else b"ADATRN02"
                header = b"".join(struct.pack("<HHIQ", section, 1, count, len(body)) for section, count, body in sections)
                data = tag + struct.pack("<iiII", rx, rz, len(sections), 0) + header + b"".join(body for _, _, body in sections)
            else:
                data = b"ADATRN01" + struct.pack("<ii", rx, rz) + heights
            name = f"valley-{rx + 2}-{rz + 2}.atregion"
            (TERRAIN / name).write_bytes(data)
            refs.append({"x": rx, "z": rz, "fileName": name})
    models = [
        {"id": i + 1, "assetPath": name + ".glb", "maximumDistance": dist}
        for i, (name, dist) in enumerate(
            (
                ("oak", 160),
                ("birch", 160),
                ("hazel", 75),
                ("grass", 120),
                ("flowers", 85),
                ("wild-syringa", 60),
                ("understory", 35),
                ("fern", 80),
                ("meadow-grass", 90),
                ("coastal-tree", 68),
            )
        )
    ]
    for model in models:
        if model["assetPath"] in {"grass.glb", "flowers.glb", "fern.glb", "meadow-grass.glb"}:
            model["pathTracingMaximumDistance"] = model["maximumDistance"]
    (TERRAIN / "Valley.aterrain").write_text(
        json.dumps(
            {
                "version": 3,
                "materials": {
                    "layers": [
                        {
                            "id": 1,
                            "name": "Leafy meadow",
                            "albedoPath": "leafy-ground.png",
                            "scale": 2.1,
                            "variation": {
                                "isEnabled": True, "seed": SEED, "macroStrength": 0.44, "macroScale": 64,
                            },
                        },
                        {
                            "id": TRAIL_LAYER, "name": "Woodland trail", "albedoPath": "trail-earth.png", "scale": 0.42,
                            "variation": {
                                "isEnabled": True, "seed": SEED + 1, "cellScale": 2.4, "macroStrength": 0.12, "macroScale": 8,
                            },
                        },
                    ],
                    "fallbackLayerID": 1,
                    "interiorLayerID": 1,
                    "rules": [],
                },
                "spacing": SPACING,
                "originX": 0,
                "originZ": 0,
                "heightRegions": refs,
                "meshPrototypes": models,
            }
        ),
        encoding="utf8",
    )


def scenery():
    hills = Model()

    def ridge(x, z):
        outside = max(abs(x), abs(z)) - 2000
        return (x, height(x, z) - min(2.5, max(0, outside / 12)), z)

    step = 62.5
    for row in range(-64, 64):
        for col in range(-64, 64):
            if -32 <= row < 32 and -32 <= col < 32:
                continue
            x, z = col * step, row * step
            color = (0.145, 0.24, 0.095)
            corners = ((x, z), (x + step, z), (x + step, z + step), (x, z + step))
            start = next(i for i, point in enumerate(corners) if max(map(abs, point)) > 2000)
            ordered = corners[start:] + corners[:start]
            border = []
            for a, b in zip(ordered, ordered[1:] + ordered[:1]):
                border.append(ridge(*a))
                if max(map(abs, a)) == max(map(abs, b)) == 2000:
                    for segment in range(1, 16):
                        along = segment / 16
                        border.append(ridge(a[0] + (b[0] - a[0]) * along, a[1] + (b[1] - a[1]) * along))
            for i in range(1, len(border) - 1):
                hills.triangle(color, border[0], border[i + 1], border[i])
    hills.save(TERRAIN / "horizon.glb")


if __name__ == "__main__":
    TERRAIN.mkdir(parents=True, exist_ok=True)
    plants()
    ground_cover_models()
    regions()
    forest_regions()
    grass_regions()
    scenery()
