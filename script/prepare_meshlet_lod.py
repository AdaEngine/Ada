#!/usr/bin/env python3
"""Prepare actual border-preserving adaptive meshlet LOD, separately from exact v1 meshlets."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess

if __package__:
    from .prepare_meshlets import _scan_validated, accessor, geometry_digest, load_gltf, validate_geometry
else:
    from prepare_meshlets import _scan_validated, accessor, geometry_digest, load_gltf, validate_geometry

REVISION = "9e1f07b159d3cb777f1c67ed31fc11fd117986f4"
MAXIMUM_BYTES = 512 * 1024 * 1024


def hierarchy(positions, indices, tool, maximum_vertices=64, maximum_triangles=96):
    validate_geometry(positions, indices, maximum_vertices, maximum_triangles)  # Once before native assertions.
    request = b"ADALOD01" + struct.pack("<IIII", len(positions), len(indices), maximum_vertices, maximum_triangles)
    request += b"".join(struct.pack("<fff", *p) for p in positions)
    request += b"".join(struct.pack("<I", index) for index in indices)
    result = subprocess.run([str(tool.resolve())], input=request, capture_output=True, check=True)
    data = result.stdout
    if len(data) < 20 or data[:8] != b"ADALODO1":
        raise ValueError("Invalid native hierarchy response")
    node_count, root_count, index_count = struct.unpack_from("<III", data, 8)
    if node_count > 1_000_000 or root_count > node_count or len(data) != 20 + node_count * 60 + root_count * 4 + index_count * 4:
        raise ValueError("Hierarchy size mismatch")
    offset = 20 + node_count * 60
    roots = list(struct.unpack_from("<" + "I" * root_count, data, offset))
    flat_indices = list(struct.unpack_from("<" + "I" * index_count, data, offset + root_count * 4))
    nodes, clusters = [], []
    expected_index = 0
    for i in range(node_count):
        record = struct.unpack_from("<IIIIIIIIfffffff", data, 20 + i * 60)
        parent, child, children, source_first, source_count, first, count, level = record[:8]
        lo, hi, error = record[8:11], record[11:14], record[14]
        if first != expected_index or count <= 0 or count % 3 or first + count > len(flat_indices):
            raise ValueError("Invalid node approximation range")
        if source_first + source_count > len(indices):
            raise ValueError("Invalid source span")
        own = flat_indices[first:first + count]
        if not set(own) <= set(indices[source_first:source_first + source_count]):
            raise ValueError("Approximation escaped source vertex identities")
        if children == 0 and own != indices[source_first:source_first + source_count]:
            raise ValueError("Leaf is not exact source geometry")
        first_cluster = len(clusters)
        # Every own ID was checked against the validated source span above. Revalidating
        # ALL positions per node made large foliage preparation O(nodes * global vertices).
        own_clusters = _scan_validated(positions, own, maximum_vertices, maximum_triangles)
        clusters.extend((c[0] + first, *c[1:]) for c in own_clusters)
        nodes.append((parent, child, children, first_cluster, len(own_clusters), source_first, source_count, level, *lo, *hi, error))
        expected_index += count
    expected_source = 0
    for root in roots:
        if root >= len(nodes) or nodes[root][0] != 0xFFFFFFFF or nodes[root][5] != expected_source:
            raise ValueError("Invalid root coverage")
        expected_source += nodes[root][6]
    if expected_source != len(indices) or expected_index != len(flat_indices):
        raise ValueError("Hierarchy did not cover the source")
    return flat_indices, clusters, nodes, roots


def prepare(path, tool, maximum_vertices=64, maximum_triangles=96):
    build = json.loads(tool.with_name("build.json").read_text(encoding="utf-8"))
    if build["revision"] != REVISION or build["lodToolSHA256"] != hashlib.sha256(tool.read_bytes()).hexdigest():
        raise ValueError("LOD tool does not match pinned build receipt")
    model, buffers, dependencies = load_gltf(path)
    records, parts, skipped = [], [], []
    for mesh_index, mesh in enumerate(model.get("meshes", [])):
        for part_index, primitive in enumerate(mesh["primitives"]):
            material = model.get("materials", [])[primitive["material"]] if "material" in primitive else {}
            if material.get("alphaMode", "OPAQUE") != "OPAQUE" or primitive.get("mode", 4) not in (4, 6) or primitive.get("targets"):
                skipped.append(dict(mesh=mesh_index, part=part_index, reason="coverage/topology/deformation"))
                continue
            positions = [struct.unpack("<fff", struct.pack("<fff", *p)) for p in accessor(model, buffers, primitive["attributes"]["POSITION"])]
            indices = [p[0] for p in accessor(model, buffers, primitive["indices"])] if "indices" in primitive else list(range(len(positions)))
            if primitive.get("mode", 4) == 6:
                indices = [v for i in range(1, len(indices) - 1) for v in (indices[0], indices[i], indices[i + 1])]
            if not indices:
                continue
            flat, clusters, nodes, roots = hierarchy(positions, indices, tool, maximum_vertices, maximum_triangles)
            payload = struct.pack("<IIIIIIIIQ", mesh_index, part_index, len(positions), len(indices), len(flat), len(clusters), len(nodes), len(roots),
                                  geometry_digest(positions, indices))
            payload += b"".join(struct.pack("<IIffffff", *cluster) for cluster in clusters)
            payload += b"".join(struct.pack("<IIIIIIIIfffffff", *node) for node in nodes)
            payload += struct.pack("<" + "I" * len(roots), *roots)
            payload += struct.pack("<" + "I" * len(flat), *flat)
            records.append(payload)
            root_indices = sum(sum(clusters[c][1] for c in range(nodes[r][3], nodes[r][3] + nodes[r][4])) for r in roots)
            parts.append(dict(mesh=mesh_index, part=part_index, sourceTriangles=len(indices) // 3, coarsestTriangles=root_indices // 3,
                              nodes=len(nodes), roots=len(roots), flatClusters=len(clusters), flatIndexCount=len(flat),
                              maximumLevel=max(node[7] for node in nodes), reducedNodes=sum(node[2] > 0 for node in nodes)))
    if len(records) > 65536:
        raise ValueError("Too many hierarchy parts")
    data = b"ADAMLOD1" + struct.pack("<IIII", 1, maximum_vertices, maximum_triangles, len(records)) + b"".join(records)
    if len(data) > MAXIMUM_BYTES:
        raise ValueError("LOD resource exceeds decoder budget")
    provenance = {key: build[key] for key in ["version", "revision", "source", "license", "sourceSHA256", "lodToolSHA256"]}
    receipt = dict(schema=1, builder="meshoptimizer-1.3-adaptive-border-locked", maximumVertices=maximum_vertices, maximumTriangles=maximum_triangles,
                   parentTargetRatio=0.5, groupSize=4, visualErrorFloorScale=0.001, errorMetric="cumulative absolute + visual heuristic floor",
                   borderPolicy="exact source-ID boundary edge preservation", dependencies=dependencies, nativeTool=provenance, parts=parts, skipped=skipped)
    return data, receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--tool", type=Path, default=Path(__file__).resolve().parents[1] / ".build-tools/meshlet-builder" / ("MeshletLOD.exe" if os.name == "nt" else "MeshletLOD"))
    args = parser.parse_args()
    data, receipt = prepare(args.source, args.tool)
    destination = args.output or args.source.with_suffix(args.source.suffix + ".meshletlod")
    destination.write_bytes(data)
    receipt["sidecarSHA256"] = hashlib.sha256(data).hexdigest()
    destination.with_suffix(destination.suffix + ".json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(f"Prepared {len(receipt['parts'])} LOD parts, {sum(p['sourceTriangles'] for p in receipt['parts'])} -> {sum(p['coarsestTriangles'] for p in receipt['parts'])} coarsest triangles: {destination}")


if __name__ == "__main__":
    main()
