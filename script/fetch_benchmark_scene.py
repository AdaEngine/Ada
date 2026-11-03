#!/usr/bin/env python3
"""Fetch the pinned Intel benchmark sources into an external cache; retain attribution and file hashes."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import struct
import subprocess
import threading
import time
from urllib.parse import parse_qs, unquote, urlparse
import zipfile

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "Tools/3DAssets/BenchmarkScenes/intel-sponza.json"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(4 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def contained(root, relative):
    name = PurePosixPath(relative)
    if name.is_absolute() or ".." in name.parts or "\\" in relative or ":" in relative:
        raise ValueError(f"Unsafe archive/dependency path: {relative}")
    target = root.joinpath(*name.parts)
    if not target.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"Path escapes benchmark cache: {relative}")
    return target


def dependency(base, uri):
    if urlparse(uri).scheme or uri.startswith(("/", "\\")):
        raise ValueError(f"External dependency is not allowed: {uri}")
    return str(PurePosixPath(base).parent / unquote(uri))


def fetch(archive, cache):
    path = contained(cache, archive["downloadName"])
    if path.exists() and path.stat().st_size != archive["archiveBytes"]:
        raise ValueError(f"Unexpected size of cached archive: {path}")
    if not path.exists():
        part = path.with_suffix(path.suffix + ".part")
        print(f"Downloading {archive['id']}: {archive['archiveBytes']} bytes", flush=True)
        chunks = cache / (archive["downloadName"] + ".chunks")
        chunks.mkdir(exist_ok=True)
        block_bytes = 16 * 1024 * 1024
        count = (archive["archiveBytes"] + block_bytes - 1) // block_bytes
        # Resolve the publisher redirect once. Repeating it for every range can trigger publisher throttling.
        url_lock = threading.Lock()
        resolved = [""]
        expires = [0]
        def current_url(force=False):
            with url_lock:
                if force or time.time() + 60 >= expires[0]:
                    # HEAD responses can carry an expired cached signature. A one-byte GET obtains
                    # the same public download redirect used for the actual data requests.
                    value = subprocess.check_output([
                        "curl.exe" if os.name == "nt" else "curl", "--fail", "--location", "--silent", "--show-error",
                        "--ipv4", "--connect-timeout", "20", "--max-time", "45", "--retry", "5", "--retry-all-errors", "--retry-delay", "2",
                        "--range", "0-0", "--max-filesize", "1", "--header", "Cache-Control: no-cache",
                        "--output", os.devnull, "--write-out", "%{url_effective}",
                        archive["url"] + "?adaengineDownload=" + str(int(time.time())),
                    ], text=True).strip()
                    if urlparse(value).scheme != "https":
                        raise ValueError("Archive redirect must retain HTTPS")
                    resolved[0] = value
                    expires[0] = int(parse_qs(urlparse(value).query).get("Expires", [time.time() + 600])[0])
                return resolved[0]
        def download(index):
            start = index * block_bytes
            end = min(archive["archiveBytes"], start + block_bytes) - 1
            chunk = contained(chunks, f"{index:05d}.bin")
            if not chunk.exists() or chunk.stat().st_size != end - start + 1:
                temporary = chunk.with_suffix(".downloading")
                # Preserve verified TLS response prefixes between transient network failures.
                for attempt in range(8):
                    existing = temporary.stat().st_size if temporary.exists() else 0
                    if existing == end - start + 1:
                        break
                    remaining = chunk.with_suffix(".remaining")
                    headers = chunk.with_suffix(".headers")
                    response = subprocess.run([
                        "curl.exe" if os.name == "nt" else "curl",
                        "--fail", "--silent", "--show-error", "--connect-timeout", "30", "--max-time", "240",
                        "--max-filesize", str(block_bytes), "--range", f"{start + existing}-{end}",
                        "--dump-header", str(headers), "--output", str(remaining), current_url(),
                    ])
                    header = headers.read_text(encoding="latin-1") if headers.exists() else ""
                    if response.returncode == 22 and "403" in header:
                        current_url(force=True)
                        continue
                    expected_range = f"content-range: bytes {start + existing}-{end}/{archive['archiveBytes']}"
                    if remaining.exists() and expected_range in header.lower():
                        if existing + remaining.stat().st_size > end - start + 1:
                            raise ValueError("HTTP range exceeds expected size")
                        with temporary.open("ab") as output, remaining.open("rb") as source:
                            shutil.copyfileobj(source, output, 1024 * 1024)
                    elif response.returncode == 0:
                        raise ValueError("Server did not honor requested byte range")
                if not temporary.exists() or temporary.stat().st_size != end - start + 1:
                    raise ValueError("HTTP range length mismatch")
                temporary.replace(chunk)
            return chunk
        with ThreadPoolExecutor(max_workers=16) as pool:
            for completed, future in enumerate(as_completed([pool.submit(download, index) for index in range(count)]), 1):
                future.result()
                if completed % 16 == 0 or completed == count:
                    print(f"{archive['id']}: {completed}/{count} blocks", flush=True)
        with part.open("wb") as output:
            for index in range(count):
                with contained(chunks, f"{index:05d}.bin").open("rb") as source:
                    shutil.copyfileobj(source, output, 4 * 1024 * 1024)
        if part.stat().st_size != archive["archiveBytes"]:
            raise ValueError(f"Downloaded archive length mismatch: {part}")
        part.replace(path)
    digest = sha256(path)
    if archive.get("archiveSHA256") and digest != archive["archiveSHA256"]:
        raise ValueError(f"Archive SHA256 mismatch: {path}")
    return path, digest


def extract(archive, path, cache, include_images=True):
    destination = cache / "assets"
    destination.mkdir(exist_ok=True)
    with zipfile.ZipFile(path) as package:
        data = package.read(archive["entry"])
        if hashlib.sha256(data).hexdigest() != archive["entrySHA256"]:
            raise ValueError(f"glTF metadata changed: {archive['entry']}")
        model = json.loads(data)
        names = {archive["entry"], archive["credits"]}
        for item in model.get("buffers", []) + (model.get("images", []) if include_images else []):
            if "uri" in item:
                names.add(dependency(archive["entry"], item["uri"]))
        records = {}
        for name in sorted(names):
            target = contained(destination, name)
            info = package.getinfo(name)
            if info.file_size > 2 * 1024**3 or info.is_dir():
                raise ValueError(f"Unexpected dependency size/type: {name}")
            target.parent.mkdir(parents=True, exist_ok=True)
            part = target.with_name(target.name + ".extracting")
            with package.open(info) as source, part.open("wb") as output:
                shutil.copyfileobj(source, output, 1024 * 1024)
            if part.stat().st_size != info.file_size:
                raise ValueError(f"Extracted dependency length mismatch: {name}")
            part.replace(target)
            record = {"bytes": info.file_size, "sha256": sha256(target)}
            if target.suffix.lower() == ".png":
                with target.open("rb") as image:
                    header = image.read(24)
                if header[:8] != b"\x89PNG\r\n\x1a\n":
                    raise ValueError(f"Invalid PNG signature: {name}")
                record["width"], record["height"] = struct.unpack(">II", header[16:24])
            records[name] = record
        geometry = records[archive["geometryBuffer"]]
        if geometry["bytes"] != archive["geometryBytes"]:
            raise ValueError("Geometry byte count changed")
        if archive.get("geometrySHA256") and geometry["sha256"] != archive["geometrySHA256"]:
            raise ValueError("Geometry SHA256 mismatch")
        # A separately named PBR adaptation fixes only pinned exporter errors. Never relax the
        # production importer's glTF validation or silently clamp arbitrary source materials.
        corrections = archive.get("pbrCorrections", [])
        for correction in corrections:
            owner = model
            parts = correction["path"].split("/")
            for key in parts[:-1]:
                owner = owner[int(key)] if isinstance(owner, list) else owner[key]
            key = int(parts[-1]) if isinstance(owner, list) else parts[-1]
            if owner[key] != correction["from"]:
                raise ValueError("PBR correction no longer matches pinned source")
            owner[key] = correction["to"]
        pbr = contained(destination, str(PurePosixPath(archive["entry"]).with_name("benchmark-pbr.gltf")))
        pbr.write_text(json.dumps(model, separators=(",", ":")), encoding="utf-8")
        records[pbr.relative_to(destination).as_posix()] = {
            "bytes": pbr.stat().st_size, "sha256": sha256(pbr), "corrections": corrections,
        }
        # A named geometry-only profile: preserve nodes, buffers, vertex attributes and opaque part boundaries.
        # Original glTF and materials remain intact for the separate PBR profile.
        materials = model.get("materials", [])
        excluded = 0
        for mesh in model.get("meshes", []):
            kept = []
            for primitive in mesh["primitives"]:
                material = materials[primitive["material"]] if "material" in primitive else {}
                if material.get("alphaMode", "OPAQUE") == "BLEND":
                    excluded += model["accessors"][primitive["indices"]]["count"] // 3
                else:
                    kept.append(primitive)
            mesh["primitives"] = kept
        # BLEND-only meshes become organizational nodes in the opaque profile. Keep the glTF valid
        # by removing empty mesh records and remapping references, without changing transforms/parts.
        retained = [index for index, mesh in enumerate(model.get("meshes", [])) if mesh["primitives"]]
        remap = {source: target for target, source in enumerate(retained)}
        model["meshes"] = [model["meshes"][index] for index in retained]
        for node in model.get("nodes", []):
            if "mesh" in node:
                if node["mesh"] in remap:
                    node["mesh"] = remap[node["mesh"]]
                else:
                    del node["mesh"]
        model["materials"] = [{"name": m.get("name", "") + " benchmark opaque", "doubleSided": m.get("doubleSided", False), "pbrMetallicRoughness": {
            "baseColorFactor": [0.65, 0.65, 0.65, 1], "metallicFactor": 0, "roughnessFactor": 0.8,
        }} for m in materials]
        for key in ("images", "textures", "samplers"):
            model.pop(key, None)
        profile = contained(destination, str(PurePosixPath(archive["entry"]).with_name("benchmark-opaque.gltf")))
        profile.write_text(json.dumps(model, separators=(",", ":")), encoding="utf-8")
        records[str(profile.relative_to(destination).as_posix())] = {
            "bytes": profile.stat().st_size, "sha256": sha256(profile), "sourceMeshIndices": retained,
        }
        return records, excluded


def verify(manifest, cache):
    receipt = json.loads((cache / "receipt.json").read_text(encoding="utf-8"))
    if receipt.get("status") != "complete" or receipt.get("profileGenerator") != 2 or receipt.get("dataset") != manifest["id"]:
        raise ValueError("Cache preparation is incomplete or uses a different profile recipe")
    if {a["id"] for a in receipt["archives"]} != {a["id"] for a in manifest["archives"]}:
        raise ValueError("Cache archive set does not match manifest")
    for archive in manifest["archives"]:
        source = next(a for a in receipt["archives"] if a["id"] == archive["id"])
        if source.get("sha256") != archive["archiveSHA256"] or source.get("geometrySHA256") != archive["geometrySHA256"]:
            raise ValueError(f"Receipt archive hashes disagree: {archive['id']}")
        path = contained(cache, archive["downloadName"])
        if path.stat().st_size != archive["archiveBytes"] or sha256(path) != archive["archiveSHA256"]:
            raise ValueError(f"Cached archive changed: {archive['id']}")
        for name, expected in [(archive["entry"], archive["entrySHA256"]), (archive["geometryBuffer"], archive["geometrySHA256"])]:
            if receipt["files"][name]["sha256"] != expected:
                raise ValueError(f"Receipt disagrees with pinned source: {name}")
    for name, record in receipt["files"].items():
        path = contained(cache / "assets", name)
        if path.stat().st_size != record["bytes"] or sha256(path) != record["sha256"]:
            raise ValueError(f"Prepared asset changed: {name}")
    print(f"Verified {len(receipt['archives'])} archives and {len(receipt['files'])} prepared files", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, default=ROOT / ".build-codex/benchmark-assets/intel-sponza")
    parser.add_argument("--verify", action="store_true", help="Verify pinned archives and every receipt file without downloading or rewriting")
    args = parser.parse_args()
    cache = args.cache.resolve()
    cache.mkdir(parents=True, exist_ok=True)
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    if args.verify:
        verify(manifest, cache)
        return
    receipt = {"schema": 1, "status": "in-progress", "profiles": ["geometry", "pbr"],
               "dataset": manifest["id"], "profileGenerator": 2, "archives": [], "files": {}}
    (cache / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    for archive in manifest["archives"]:
        path, digest = fetch(archive, cache)
        print(f"Extracting {archive['id']}; archive SHA256={digest}", flush=True)
        records, excluded = extract(archive, path, cache)
        receipt["archives"].append({"id": archive["id"], "sha256": digest, "bytes": path.stat().st_size,
                                    "geometrySHA256": records[archive["geometryBuffer"]]["sha256"], "geometryProfileExcludedTriangles": excluded})
        receipt["files"].update(records)
        (cache / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        print(f"Ready {archive['id']}: {len(records)} files; excluded {excluded} BLEND triangles in geometry profile", flush=True)
    pixels = sum(f.get("width", 0) * f.get("height", 0) for f in receipt["files"].values())
    receipt["status"] = "complete"
    (cache / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(f"Dataset ready: {cache / 'assets'}; approximate unique RGBA8+mip bytes: {pixels * 16 // 3}", flush=True)


if __name__ == "__main__":
    main()
