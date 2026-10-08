#!/usr/bin/env python3

from __future__ import annotations

import argparse
import collections
import json
import statistics
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Iterable


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Summarize exported AdaEngine Instruments data.")
    parser.add_argument("--input", required=True, type=Path, help="Directory produced by export_instruments_trace.sh")
    parser.add_argument("--process", required=True, help="Process name, for example AdaEditor")
    parser.add_argument("--top", type=int, default=15, help="Number of top functions to report")
    parser.add_argument("--json", action="store_true", help="Emit JSON instead of Markdown")
    return parser.parse_args()


class TraceXML:
    def __init__(self, path: Path) -> None:
        self.root = ET.parse(path).getroot()
        self.ids = {
            element.get("id"): element
            for element in self.root.iter()
            if element.get("id")
        }

    def resolve(self, element: ET.Element) -> ET.Element:
        reference = element.get("ref")
        return self.ids.get(reference, element) if reference else element

    def label(self, element: ET.Element | None) -> str:
        if element is None:
            return ""
        target = self.resolve(element)
        return target.get("fmt") or target.get("name") or target.text or ""

    def number(self, element: ET.Element) -> int:
        return int(self.resolve(element).text or "0")


def matches_process(label: str, process: str) -> bool:
    return label == process or label.startswith(f"{process} (")


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(len(ordered) * fraction))]


def frame_info(document: TraceXML, element: ET.Element) -> tuple[str, str, str]:
    target = document.resolve(element)
    name = target.get("name", "<unknown>")
    binary = document.label(target.find("binary"))
    source_element = target.find("source")
    source = ""
    if source_element is not None:
        source_target = document.resolve(source_element)
        source_path = document.label(source_target.find("path"))
        if source_path:
            source = f"{source_path}:{source_target.get('line', '')}"
    return name, binary, source


def stack_category(frames: list[tuple[str, str, str]]) -> str:
    stack = "\n".join(name for name, _, _ in frames)
    if "EditorTreeSitterSwiftSyntaxHighlighter" in stack or "EditorSyntaxHighlighter" in stack:
        return "syntax highlighting"
    if "TextLayoutManager" in stack or "Text.Storage.applyingEnvironment" in stack or "AttributedText.subscript" in stack:
        return "text shaping/layout"
    if "UIRenderTesselationSystem" in stack or "UITessellator" in stack:
        return "UI tessellation/clipping"
    if "ShaderCompiler" in stack or "glslang::" in stack or "ShaderCache" in stack:
        return "shader compilation/cache"
    if "ViewContainerNode.invalidateContent" in stack or "ViewContainerNode.reconcileChildNodes" in stack or "ViewContainerNode.update(from:)" in stack:
        return "view invalidation/reconciliation"
    if "layoutSubviews" in stack or ".place(" in stack or "performLayout" in stack or "sizeThatFits" in stack:
        return "UI layout"
    if "Render" in stack or "Metal" in stack or "MTL" in stack:
        return "render/Metal other"
    if "__read" in stack or "__open" in stack or "Data(contentsOf" in stack:
        return "file IO"
    return "other/runtime"


def analyze_cpu(path: Path, process: str, top: int) -> dict[str, object]:
    document = TraceXML(path)
    threads: collections.Counter[str] = collections.Counter()
    categories: collections.Counter[str] = collections.Counter()
    leaves: collections.Counter[str] = collections.Counter()
    inclusive: collections.Counter[str] = collections.Counter()
    source_by_function: dict[str, str] = {}
    by_second: collections.Counter[int] = collections.Counter()
    total_weight = 0
    sample_count = 0

    for row in document.root.findall(".//row"):
        process_element = row.find("process")
        if not matches_process(document.label(process_element), process):
            continue
        time_element = row.find("sample-time")
        thread_element = row.find("thread")
        weight_element = row.find("weight")
        backtrace_element = row.find("backtrace")
        if time_element is None or thread_element is None or weight_element is None or backtrace_element is None:
            continue

        frames = [frame_info(document, frame) for frame in document.resolve(backtrace_element).findall("frame")]
        if not frames:
            continue

        weight = document.number(weight_element)
        timestamp = document.number(time_element)
        sample_count += 1
        total_weight += weight
        threads[document.label(thread_element)] += weight
        categories[stack_category(frames)] += weight
        leaves[frames[0][0]] += weight
        by_second[timestamp // 1_000_000_000] += weight

        unique_first_party = set()
        for name, binary, source in frames:
            if binary == process:
                unique_first_party.add(name)
                if source:
                    source_by_function[name] = source
        for name in unique_first_party:
            inclusive[name] += weight

    def counter_rows(counter: collections.Counter[str], limit: int) -> list[dict[str, object]]:
        return [
            {
                "name": name,
                "weight_ms": weight / 1_000_000,
                "percent": (100 * weight / total_weight) if total_weight else 0,
                "source": source_by_function.get(name, ""),
            }
            for name, weight in counter.most_common(limit)
        ]

    return {
        "sample_count": sample_count,
        "active_cpu_ms": total_weight / 1_000_000,
        "threads": counter_rows(threads, 12),
        "categories": counter_rows(categories, len(categories)),
        "leaf_functions": counter_rows(leaves, top),
        "inclusive_first_party": counter_rows(inclusive, top),
        "busiest_seconds": [
            {"second": second, "active_cpu_ms": weight / 1_000_000}
            for second, weight in by_second.most_common(10)
        ],
    }


def analyze_hangs(path: Path, process: str) -> dict[str, object]:
    if not path.exists():
        return {"count": 0, "total_ms": 0.0, "items": []}
    document = TraceXML(path)
    items = []
    for row in document.root.findall(".//row"):
        process_element = row.find("process")
        if not matches_process(document.label(process_element), process):
            continue
        start = row.find("start-time")
        duration = row.find("duration")
        hang_type = row.find("hang-type")
        if start is None or duration is None:
            continue
        items.append({
            "start_s": document.number(start) / 1_000_000_000,
            "duration_ms": document.number(duration) / 1_000_000,
            "type": document.label(hang_type),
        })
    return {
        "count": len(items),
        "total_ms": sum(float(item["duration_ms"]) for item in items),
        "items": items,
    }


def analyze_presents(path: Path, process: str) -> dict[str, object]:
    if not path.exists():
        return {"count": 0}
    document = TraceXML(path)
    timestamps = []
    surfaces: collections.Counter[int] = collections.Counter()
    for row in document.root.findall(".//row"):
        process_element = row.find("process")
        if not matches_process(document.label(process_element), process):
            continue
        timestamps.append(document.number(row[0]))
        surfaces[document.number(row[2])] += 1
    timestamps.sort()
    deltas = [(right - left) / 1_000_000 for left, right in zip(timestamps, timestamps[1:])]
    by_second = collections.Counter(timestamp // 1_000_000_000 for timestamp in timestamps)
    return {
        "count": len(timestamps),
        "surface_count": len(surfaces),
        "median_gap_ms": statistics.median(deltas) if deltas else 0.0,
        "p95_gap_ms": percentile(deltas, 0.95),
        "max_gap_ms": max(deltas, default=0.0),
        "gaps_over_100ms": sum(delta > 100 for delta in deltas),
        "presents_by_second": dict(sorted(by_second.items())),
    }


def metal_object_label(document: TraceXML, element: ET.Element) -> str:
    target = document.resolve(element)
    object_element = target.find("metal-object-label")
    if object_element is not None:
        return document.label(object_element)
    value = document.label(target)
    if "blocked waiting for next drawable" in value:
        return "Wait for Next Drawable"
    return value


def duration_summary(events: Iterable[dict[str, object]]) -> dict[str, object]:
    values = [float(event["duration_ms"]) for event in events]
    return {
        "count": len(values),
        "total_ms": sum(values),
        "median_ms": statistics.median(values) if values else 0.0,
        "p95_ms": percentile(values, 0.95),
        "max_ms": max(values, default=0.0),
    }


def analyze_metal(path: Path, process: str) -> dict[str, object]:
    if not path.exists():
        return {"event_types": {}, "labels": {}}
    document = TraceXML(path)
    by_type: dict[str, list[dict[str, object]]] = collections.defaultdict(list)
    by_label: dict[str, list[dict[str, object]]] = collections.defaultdict(list)
    for row in document.root.findall(".//row"):
        if not matches_process(document.label(row[2]), process):
            continue
        event = {
            "start_s": document.number(row[0]) / 1_000_000_000,
            "duration_ms": document.number(row[1]) / 1_000_000,
        }
        by_type[document.label(row[10])].append(event)
        by_label[metal_object_label(document, row[5])].append(event)
    return {
        "event_types": {name: duration_summary(events) for name, events in by_type.items()},
        "labels": {
            name: duration_summary(events)
            for name, events in sorted(
                by_label.items(),
                key=lambda item: -sum(float(event["duration_ms"]) for event in item[1]),
            )[:15]
        },
    }


def read_issues(path: Path) -> list[str]:
    if not path.exists():
        return []
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    return [line.split("\t", 2)[-1] for line in lines[1:] if line.strip()]


def render_counter(
    title: str,
    rows: list[dict[str, object]],
    item_label: str = "Function",
) -> list[str]:
    result = [f"### {title}", "", f"| Active CPU | Share | {item_label} |", "|---:|---:|---|"]
    for row in rows:
        source = f" — `{row['source']}`" if row.get("source") else ""
        result.append(f"| {row['weight_ms']:.1f} ms | {row['percent']:.2f}% | `{row['name']}`{source} |")
    result.append("")
    return result


def render_markdown(report: dict[str, object]) -> str:
    cpu = report["cpu"]
    hangs = report["hangs"]
    presents = report["presents"]
    metal = report["metal"]
    lines = [
        f"# Instruments summary: {report['process']}",
        "",
        f"- Samples: {cpu['sample_count']}",
        f"- Active CPU: {cpu['active_cpu_ms']:.1f} ms",
        f"- Hangs: {hangs['count']} ({hangs['total_ms']:.1f} ms total)",
        f"- Presents: {presents.get('count', 0)}",
    ]
    main_thread = next(
        (thread for thread in cpu["threads"] if str(thread["name"]).startswith("Main Thread ")),
        None,
    )
    if main_thread:
        lines.append(
            f"- Main-thread active CPU: {main_thread['weight_ms']:.1f} ms "
            f"({main_thread['percent']:.2f}% of sampled CPU)"
        )
    if presents.get("count", 0):
        lines.extend([
            f"- Present gap median/p95/max: {presents['median_gap_ms']:.2f}/{presents['p95_gap_ms']:.2f}/{presents['max_gap_ms']:.2f} ms",
            f"- Present gaps over 100 ms: {presents['gaps_over_100ms']}",
        ])
    lines.append("")
    lines.extend(render_counter("Active CPU by thread", cpu["threads"], item_label="Thread"))
    lines.extend(render_counter("Exclusive subsystem categories", cpu["categories"]))
    lines.extend(render_counter("Inclusive first-party functions", cpu["inclusive_first_party"]))
    lines.extend(render_counter("Active leaf functions", cpu["leaf_functions"]))

    if hangs["items"]:
        lines.extend(["### Hangs", "", "| Start | Duration | Type |", "|---:|---:|---|"])
        for item in hangs["items"]:
            lines.append(f"| {item['start_s']:.3f} s | {item['duration_ms']:.2f} ms | {item['type']} |")
        lines.append("")

    if metal["event_types"]:
        lines.extend(["### Metal application intervals", "", "| Type | Count | Total | Median | P95 | Max |", "|---|---:|---:|---:|---:|---:|"])
        for name, summary in metal["event_types"].items():
            lines.append(
                f"| {name} | {summary['count']} | {summary['total_ms']:.2f} ms | "
                f"{summary['median_ms']:.3f} ms | {summary['p95_ms']:.3f} ms | {summary['max_ms']:.3f} ms |"
            )
        lines.append("")

    if report["issues"]:
        lines.extend(["### Recording issues", ""])
        lines.extend(f"- {issue}" for issue in report["issues"])
        lines.append("")

    lines.extend([
        "## Caveats",
        "",
        "Inclusive functions overlap and must not be summed. Metal Encoding is CPU-side work, not GPU execution time. "
        "Use all present timestamps rather than per-surface gaps when a swapchain rotates surfaces.",
    ])
    return "\n".join(lines)


def main() -> None:
    arguments = parse_arguments()
    input_dir = arguments.input.resolve()
    time_profile = input_dir / "time-profile.xml"
    if not time_profile.is_file():
        raise SystemExit(f"error: missing required export {time_profile}")

    report = {
        "process": arguments.process,
        "cpu": analyze_cpu(time_profile, arguments.process, arguments.top),
        "hangs": analyze_hangs(input_dir / "potential-hangs.xml", arguments.process),
        "presents": analyze_presents(input_dir / "ca-present.xml", arguments.process),
        "metal": analyze_metal(input_dir / "metal-application.xml", arguments.process),
        "issues": read_issues(input_dir / "run-issues.tsv"),
    }

    if arguments.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(render_markdown(report))


if __name__ == "__main__":
    main()
