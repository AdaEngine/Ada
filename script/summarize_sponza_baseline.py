#!/usr/bin/env python3
"""Summarize every Sponza A/B round; reject incomplete comparisons."""
import argparse
from collections import defaultdict
import json
import math
from pathlib import Path
from statistics import median

from summarize_meshlet_baseline import percentile


def summarize(report):
    if report["schema"] != 1 or not report.get("complete") or not report["measurements"]:
        raise ValueError("Expected a completed, nonempty Sponza schema 1 report")
    if report.get("cameraPoseProtocol") != "same-frame-root-world-pose-v1":
        raise ValueError("Expected the validated same-frame camera pose protocol")
    groups = defaultdict(list)
    sample_keys = ("updateMilliseconds", "windowMillisecondsPerFrame", "extractionMilliseconds",
                   "listPreparationMilliseconds", "mainNodeMilliseconds")
    for sample in report["measurements"]:
        for key in sample_keys:
            if not sample[key] or not all(math.isfinite(v) and v >= 0 for v in sample[key]):
                raise ValueError(f"Invalid {key}")
        if len(sample["updateMilliseconds"]) != report["frames"]:
            raise ValueError("Measured frame count mismatch")
        wall = sample["drainInclusiveMillisecondsPerFrame"]
        if not math.isfinite(wall) or wall <= 0:
            raise ValueError("Invalid drained wall time")
        groups[(sample["preset"], sample["quality"], sample["route"], sample["hiZ"])].append(sample)
    for key, samples in groups.items():
        if len(samples) != report["rounds"] or {s["round"] for s in samples} != set(range(report["rounds"])):
            raise ValueError(f"Incomplete or duplicate rounds: {key}")
        if key[:-1] + (not key[-1],) not in groups:
            raise ValueError(f"Missing A/B partner: {key}")
        if any(s["census"] != samples[0]["census"] for s in samples):
            raise ValueError(f"End-pose scene census changed between rounds: {key}")
    lines = [
        "# Sponza baseline samples", "",
        f"Backend: {report['backend']}; {report['width']}×{report['height']}; "
        f"{report['warmup']} warmup + {report['frames']} measured frames; {report['rounds']} alternating A/B pairs.", "",
        f"Completion: `{report['completionProtocol']}`, {report['submissionWindowFrames']}-frame submission windows.", "",
        "Wall is the median of all per-round drain-inclusive frame averages. Window p95 describes drained window "
        "averages, not individual frame latency. Update is CPU-side app-update wall time, not GPU time. Extraction, "
        "list preparation (including uploads) and main-node wall time are separate diagnostics at the route end, "
        "outside throughput timing. Import, geometry digest, PNG readback and diagnostics are excluded. "
        "Census is CPU coarse visibility/batching at the final pose, before GPU Hi-Z. No best-round selection.", "",
        "| preset | quality | route | Hi-Z | wall ms | window median / p95 ms | update median ms | extraction / lists / node ms | end batches | end triangles | index ceiling MiB/slot |",
        "| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for (preset, quality, route, hiz), samples in sorted(groups.items()):
        def values(key):
            return [v for s in samples for v in s[key]]
        window = values("windowMillisecondsPerFrame")
        census = samples[0]["census"]
        diagnostics = " / ".join(f"{median(values(k)):.3f}" for k in sample_keys[2:])
        lines.append(
            f"| {preset} | {quality} | {route} | {hiz} | "
            f"{median(s['drainInclusiveMillisecondsPerFrame'] for s in samples):.3f} | "
            f"{median(window):.3f} / {percentile(window, .95):.3f} | "
            f"{median(values('updateMilliseconds')):.3f} | {diagnostics} | "
            f"{census['batches']} | {census['triangles']} | {census['compactedIndexCeilingBytes'] / 2**20:.3f} |"
        )
    gpu_samples = sum(len(s["gpuPasses"]) for s in report["measurements"])
    lines += ["", f"GPU pass timestamp samples: {gpu_samples}. "
              "An empty set does not establish GPU pass cost or prove a geometry bottleneck. "
              "Index ceilings omit the resource ring, scratch and static cluster data; they are not measured peak VRAM."]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = summarize(json.loads(args.report.read_text(encoding="utf-8")))
    if args.output:
        args.output.write_text(result, encoding="utf-8")
    else:
        print(result, end="")


if __name__ == "__main__":
    main()
