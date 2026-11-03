#!/usr/bin/env python3
"""Summarize P0 raw samples without selecting best rounds or claiming GPU timestamps."""
import argparse
from collections import defaultdict
import json
import math
from pathlib import Path
from statistics import median


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]


def summarize(report):
    if report["schema"] != 1 or not report["measurements"]:
        raise ValueError("Expected a nonempty meshlet baseline schema 1 report")
    grouped = defaultdict(list)
    for sample in report["measurements"]:
        for key in ("updateMilliseconds", "windowMillisecondsPerFrame", "extractionMilliseconds", "listPreparationMilliseconds", "mainNodeMilliseconds"):
            if not sample[key] or not all(math.isfinite(value) and value >= 0 for value in sample[key]):
                raise ValueError(f"Invalid samples: {sample['workload']}/{key}")
        grouped[(sample["workload"], sample["hiZ"])].append(sample)
    lines = [
        "# Meshlet P0 baseline samples", "",
        f"Backend: {report['backend']}; {report['width']}x{report['height']}; "
        f"{report['warmupFrames']} warmup / {report['measuredFrames']} measured frames per round; "
        f"{report['rounds']} alternating pairs; resource ring {report['maxFramesInFlight']}; "
        f"submission window {report['submissionWindowFrames']} frames.", "",
        f"Completion protocol: `{report['completionProtocol']}`.", "",
        "`wall` is the median of drain-inclusive per-round frame averages. `window` median/p95 are "
        "GPU-drained window averages per frame, not individual frame-latency percentiles. "
        "`update` is CPU-side app-update wall time (including submission), not exclusive CPU encode time. "
        "Extraction, list preparation and main-node wall time run in a separate diagnostic phase; "
        "uploads are included in list time and the main node includes preparation/encode/submission. "
        "No texture readback is included in throughput timing. GPU pass samples, when available, "
        "come from a separate serialized phase. No best-round selection.", "",
        "| workload | Hi-Z | wall ms | window median / p95 ms | update median ms | extraction median ms | list median ms | main node median ms | batches | batch sizes | singleton triangles | index ceiling MiB |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: |",
    ]
    for (workload, hiz), samples in sorted(grouped.items()):
        rounds = {sample["round"] for sample in samples}
        if len(samples) != report["rounds"] or rounds != set(range(report["rounds"])):
            raise ValueError(f"Incomplete or duplicated rounds for {workload}/{hiz}")
        first = samples[0]["census"]
        if any(sample["census"] != first for sample in samples):
            raise ValueError(f"Static scene census changed between rounds for {workload}/{hiz}")
        def values(key):
            return [value for sample in samples for value in sample[key]]
        window = values("windowMillisecondsPerFrame")
        histogram = ", ".join(f"{size}: {count}" for size, count in sorted(first["batchSizeHistogram"].items(), key=lambda pair: int(pair[0])))
        lines.append(
            f"| {workload} | {hiz} | {median(s['drainInclusiveMillisecondsPerFrame'] for s in samples):.3f} | "
            f"{median(window):.3f} / {percentile(window, .95):.3f} | "
            f"{median(values('updateMilliseconds')):.3f} | {median(values('extractionMilliseconds')):.3f} | "
            f"{median(values('listPreparationMilliseconds')):.3f} | {median(values('mainNodeMilliseconds')):.3f} | {first['batches']} | {histogram} | "
            f"{first['singletonTriangles']} | {first['compactedIndexCeilingBytes'] / 2**20:.3f} |"
        )
    lines += ["", "Geometry census is measured after CPU coarse visibility/LOD/batching, before GPU Hi-Z. "
              "Singleton triangle counts are a potential workload, not full material/deformation eligibility. "
              "The index ceiling is one output slot only; ring, scan scratch and static meshlet data add memory."]
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
