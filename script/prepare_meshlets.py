#!/usr/bin/env python3
"""Prepare deterministic order-preserving reference meshlets, without a GPU or runtime C++ dependency."""
import argparse
import base64
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import subprocess
from urllib.parse import unquote

MAGIC = b"ADAMSHL1"
MAXIMUM_BYTES = 64 * 1024 * 1024
COMPONENTS = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}
FORMATS = {5120: "b", 5121: "B", 5122: "h", 5123: "H", 5125: "I", 5126: "f"}


def load_gltf(path):
    raw = path.read_bytes()
    binary = None
    if path.suffix.lower() == ".glb":
        if len(raw) < 20 or struct.unpack_from("<III", raw) != (0x46546C67, 2, len(raw)):
            raise ValueError("Invalid GLB header")
        offset, document = 12, None
        while offset < len(raw):
            length, kind = struct.unpack_from("<II", raw, offset)
            offset += 8
            if length > len(raw) - offset:
                raise ValueError("Truncated GLB chunk")
            chunk = raw[offset:offset + length]
            if kind == 0x4E4F534A:
                document = json.loads(chunk)
            elif kind == 0x004E4942:
                binary = chunk
            offset += length
        if document is None:
            raise ValueError("Missing GLB JSON")
    else:
        document = json.loads(raw)
    buffers, dependencies = [], {path.name: hashlib.sha256(raw).hexdigest()}
    for item in document.get("buffers", []):
        uri = item.get("uri")
        if uri is None:
            if binary is None:
                raise ValueError("Missing embedded buffer")
            value = binary
        elif uri.startswith("data:"):
            header, payload = uri.split(",", 1)
            if not header.endswith(";base64"):
                raise ValueError("Only base64 data buffers are supported")
            value = base64.b64decode(payload, validate=True)
        else:
            dependency = path.parent / unquote(uri)
            value = dependency.read_bytes()
            dependencies[uri] = hashlib.sha256(value).hexdigest()
        if len(value) < item["byteLength"]:
            raise ValueError("Truncated geometry buffer")
        buffers.append(value)
    return document, buffers, dependencies


def accessor(model, buffers, index):
    item = model["accessors"][index]
    if "sparse" in item:
        raise ValueError("Sparse geometry requires import normalization before meshlet preparation")
    view = model["bufferViews"][item["bufferView"]]
    fmt = FORMATS[item["componentType"]]
    width = COMPONENTS[item["type"]]
    element = struct.Struct("<" + fmt * width)
    stride = view.get("byteStride", element.size)
    offset = view.get("byteOffset", 0) + item.get("byteOffset", 0)
    count = item["count"]
    buffer = buffers[view["buffer"]]
    if count < 0 or stride < element.size or offset < 0 or (count and offset + (count - 1) * stride + element.size > len(buffer)):
        raise ValueError("Accessor range exceeds geometry buffer")
    values = [element.unpack_from(buffer, offset + i * stride) for i in range(count)]
    if item.get("normalized"):
        limits = {5120: (127, True), 5121: (255, False), 5122: (32767, True), 5123: (65535, False)}
        divisor, signed = limits[item["componentType"]]
        values = [tuple(max(-1, v / divisor) if signed else v / divisor for v in row) for row in values]
    return values


def geometry_digest(positions, indices):
    value = 14695981039346656037
    def append(data):
        nonlocal value
        for byte in data:
            value = ((value ^ byte) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    append(struct.pack("<II", len(positions), len(indices)))
    for position in positions:
        append(struct.pack("<fff", *position))
    for index in indices:
        append(struct.pack("<I", index))
    return value


def validate_geometry(positions, indices, maximum_vertices=64, maximum_triangles=96):
    if not 3 <= maximum_vertices <= 256 or not 1 <= maximum_triangles <= 256:
        raise ValueError("Invalid meshlet profile")
    if len(indices) % 3 or any(i < 0 or i >= len(positions) for i in indices):
        raise ValueError("Invalid triangle indices")
    if any(not math.isfinite(v) for p in positions for v in p):
        raise ValueError("Nonfinite source position")


def _scan_validated(positions, indices, maximum_vertices=64, maximum_triangles=96):
    """Internal scan over already-validated geometry; never rewalk unrelated source positions."""
    clusters, vertices, first = [], set(), 0
    lo, hi = [math.inf] * 3, [-math.inf] * 3
    for offset in range(0, len(indices), 3):
        triangle = indices[offset:offset + 3]
        additional = set(triangle) - vertices
        if offset > first and (len(vertices) + len(additional) > maximum_vertices or (offset - first) // 3 >= maximum_triangles):
            clusters.append((first, offset - first, *lo, *hi))
            vertices, first = set(), offset
            lo, hi = [math.inf] * 3, [-math.inf] * 3
        for index in triangle:
            vertices.add(index)
            for axis in range(3):
                lo[axis] = min(lo[axis], positions[index][axis])
                hi[axis] = max(hi[axis], positions[index][axis])
    if first < len(indices):
        clusters.append((first, len(indices) - first, *lo, *hi))
    return clusters


def scan(positions, indices, maximum_vertices=64, maximum_triangles=96):
    validate_geometry(positions, indices, maximum_vertices, maximum_triangles)
    return _scan_validated(positions, indices, maximum_vertices, maximum_triangles)


def native_scan(positions, indices, tool, maximum_vertices=64, maximum_triangles=96):
    manifest = json.loads(tool.with_name("build.json").read_text(encoding="utf-8"))
    if manifest["revision"] != "9e1f07b159d3cb777f1c67ed31fc11fd117986f4" or manifest["toolSHA256"] != hashlib.sha256(tool.read_bytes()).hexdigest():
        raise ValueError("Native meshlet tool does not match its pinned build receipt")
    # Validate independently before passing indices to an asserting native API.
    reference = scan(positions, indices, maximum_vertices, maximum_triangles)
    request = b"ADAMIN01" + struct.pack("<IIII", len(positions), len(indices), maximum_vertices, maximum_triangles)
    request += b"".join(struct.pack("<I", index) for index in indices)
    result = subprocess.run([str(tool.resolve())], input=request, capture_output=True, check=True)
    output = result.stdout
    if len(output) < 12 or output[:8] != b"ADAMOUT1":
        raise ValueError("Invalid native meshlet response")
    count = struct.unpack_from("<I", output, 8)[0]
    if len(output) != 12 + count * 8:
        raise ValueError("Truncated native meshlet response")
    clusters, next_index = [], 0
    for i in range(count):
        first, size = struct.unpack_from("<II", output, 12 + i * 8)
        if first != next_index or size == 0 or size % 3 or size // 3 > maximum_triangles or size > len(indices) - first:
            raise ValueError("Native meshlet range is invalid")
        ids = indices[first:first + size]
        if len(set(ids)) > maximum_vertices:
            raise ValueError("Native meshlet vertex limit exceeded")
        lo = [min(positions[index][axis] for index in ids) for axis in range(3)]
        hi = [max(positions[index][axis] for index in ids) for axis in range(3)]
        clusters.append((first, size, *lo, *hi))
        next_index += size
    if next_index != len(indices):
        raise ValueError("Native meshlets lost source triangles")
    return clusters, clusters == reference


def prepare(path, maximum_vertices=64, maximum_triangles=96, native_tool=None):
    model, buffers, dependencies = load_gltf(path)
    records, receipt = [], []
    for mesh_index, mesh in enumerate(model.get("meshes", [])):
        for part_index, part in enumerate(mesh["primitives"]):
            mode = part.get("mode", 4)
            if mode not in (4, 6):  # The production importer retains triangle strips; v1 falls back for them.
                continue
            raw_positions = accessor(model, buffers, part["attributes"]["POSITION"])
            # Match Swift import's Float32 positions before bounds/digest calculation.
            positions = [struct.unpack("<fff", struct.pack("<fff", *p)) for p in raw_positions]
            indices = [row[0] for row in accessor(model, buffers, part["indices"])] if "indices" in part else list(range(len(positions)))
            if mode == 6:
                indices = [v for i in range(1, len(indices) - 1) for v in (indices[0], indices[i], indices[i + 1])]
            boundary_match = True
            if native_tool:
                clusters, boundary_match = native_scan(positions, indices, native_tool, maximum_vertices, maximum_triangles)
            else:
                clusters = scan(positions, indices, maximum_vertices, maximum_triangles)
            digest = geometry_digest(positions, indices)
            header = struct.pack("<IIIIIQ", mesh_index, part_index, len(positions), len(indices), len(clusters), digest)
            records.append(header + b"".join(struct.pack("<IIffffff", *c) for c in clusters))
            receipt.append(dict(mesh=mesh_index, part=part_index, triangles=len(indices) // 3, meshlets=len(clusters), referenceBoundariesMatch=boundary_match))
    if len(records) > 65536:
        raise ValueError("Too many mesh parts")
    data = MAGIC + struct.pack("<IIII", 1, maximum_vertices, maximum_triangles, len(records)) + b"".join(records)
    if len(data) > MAXIMUM_BYTES:
        raise ValueError("Sidecar exceeds runtime decoding budget")
    result = dict(schema=1, builder="meshoptimizer-1.3-scan" if native_tool else "adaengine-reference-scan-v1", maximumVertices=maximum_vertices,
                  maximumTriangles=maximum_triangles, primitiveOrder="preserved", dependencies=dependencies, parts=receipt)
    if native_tool:
        build = json.loads(native_tool.with_name("build.json").read_text(encoding="utf-8"))
        result["nativeTool"] = {key: build[key] for key in ["version", "revision", "source", "license", "sourceSHA256", "toolSHA256"]}
    return data, result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--maximum-vertices", type=int, default=64)
    parser.add_argument("--maximum-triangles", type=int, choices=[64, 96, 126], default=96)
    parser.add_argument("--builder", choices=["reference", "native"], default="reference")
    parser.add_argument("--meshoptimizer-tool", type=Path,
                        default=Path(__file__).resolve().parents[1] / ".build-tools/meshlet-builder" / ("MeshletScan.exe" if os.name == "nt" else "MeshletScan"))
    args = parser.parse_args()
    data, receipt = prepare(args.source, args.maximum_vertices, args.maximum_triangles,
                            native_tool=args.meshoptimizer_tool if args.builder == "native" else None)
    destination = args.output or args.source.with_suffix(args.source.suffix + ".meshlets")
    destination.write_bytes(data)
    receipt["sidecarSHA256"] = hashlib.sha256(data).hexdigest()
    destination.with_suffix(destination.suffix + ".json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(f"Prepared {sum(p['meshlets'] for p in receipt['parts'])} meshlets in {len(receipt['parts'])} parts: {destination}")


if __name__ == "__main__":
    main()
