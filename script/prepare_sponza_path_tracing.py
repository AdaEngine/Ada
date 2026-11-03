#!/usr/bin/env python3
"""Build an explicit Sponza lighting LOD within the portable path tracer's triangle budget."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def triangle_count(model):
    return sum(
        model["accessors"][part["indices"]]["count"] // 3
        for node in model["nodes"] if "mesh" in node
        for part in model["meshes"][node["mesh"]]["primitives"]
    )


def material_triangles(model):
    result = {}
    for node in model["nodes"]:
        if "mesh" not in node:
            continue
        for part in model["meshes"][node["mesh"]]["primitives"]:
            name = model["materials"][part["material"]]["name"]
            result[name] = result.get(name, 0) + model["accessors"][part["indices"]]["count"] // 3
    return result


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets", type=Path, default=root / ".build-codex/benchmark-assets/intel-sponza/assets")
    parser.add_argument("--gltfpack", type=Path, default=root / ".build-tools/gltfpack/v1.3/gltfpack.exe")
    args = parser.parse_args()
    tool = args.gltfpack.resolve()
    version = subprocess.check_output([str(tool), "-v"], text=True).strip()
    if "1.3" not in version:
        raise ValueError("This preparation profile requires gltfpack 1.3")
    receipt = {"schema": 1, "profile": "sponza-lighting-pt-lod", "tool": version,
               "toolSHA256": sha256(tool), "maximumRelativeError": 0.01, "triangleBudget": 131072, "models": []}
    for folder in ["main_sponza", "pkg_b_ivy"]:
        source = args.assets / folder / "benchmark-pbr.gltf"
        output = source.with_name("lighting-pt.gltf")
        # Spend the budget on architecture; the former 100% error erased entire floors/walls.
        ratio = "0.028" if folder == "main_sponza" else "0.003"
        options = ["-si", ratio, "-sp", "-sv", "-se", "0.01", "-noq", "-tr"]
        subprocess.run([str(tool), "-i", str(source), "-o", str(output), *options], check=True)
        model = json.loads(output.read_text(encoding="utf-8"))
        original = json.loads(source.read_text(encoding="utf-8"))
        coverage = material_triangles(model)
        missing = material_triangles(original).keys() - coverage.keys()
        if missing:
            raise ValueError(f"LOD discarded material groups: {sorted(missing)}")
        # Keep identical image URIs so both geometries share the engine's original texture assets.
        images = {Path(item["uri"]).name: item["uri"] for item in original.get("images", [])}
        for item in model.get("images", []):
            item["uri"] = images[Path(item["uri"]).name]
        output.write_text(json.dumps(model, separators=(",", ":")) + "\n", encoding="utf-8")
        files = [output, *(output.parent / item["uri"] for item in model.get("buffers", []))]
        receipt["models"].append({"folder": folder, "triangles": triangle_count(model),
                                  "materialTriangles": coverage,
                                  "sourceSHA256": sha256(source), "options": options,
                                  "files": {p.name: sha256(p) for p in files}})
    receipt["triangles"] = sum(model["triangles"] for model in receipt["models"])
    if not 0 < receipt["triangles"] <= receipt["triangleBudget"]:
        raise ValueError(f"LOD exceeds portable path tracing budget: {receipt['triangles']}")
    destination = args.assets / "lighting-pt-receipt.json"
    destination.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(f"Prepared {receipt['triangles']} triangles: {destination}")


if __name__ == "__main__":
    main()
