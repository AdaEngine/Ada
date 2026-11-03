"""Verify retained check evidence and locate reusable full-profile results."""

import hashlib
import json
from pathlib import Path

from .execution import tool_state
from .profiles import build_checks
from .repository import snapshot


def validate_checks(root, report, directory, config, stage="review"):
    recipes = report.get("recipes", {})
    expected = build_checks(Path(root), report["paths"], config, directory / "paths.json", directory,
                            runtime=recipes.get("runtime"), platform_command=recipes.get("platform"),
                            dependency_command=recipes.get("dependency"))
    if stage != "review":
        expected = [check for check in expected if check.name == "content"]
    if {check.name for check in expected} != {item["name"] for item in report["checks"]}:
        raise ValueError("Required check inventory is missing or altered")
    if json.loads((directory / "paths.json").read_text(encoding="utf-8")) != report["paths"]:
        raise ValueError("Retained check inputs changed")
    for item in report["checks"]:
        required = next(check for check in expected if check.name == item["name"])
        if item.get("command") != required.argv or item.get("cwd") != required.cwd:
            raise ValueError("Recorded command does not match the required check: " + item["name"])
        if item.get("environment") != required.env or item.get("required_output") != required.required_output:
            raise ValueError("Recorded execution requirements changed: " + item["name"])
        if required.status and item["status"] != required.status:
            raise ValueError("Recorded status contradicts the required profile: " + item["name"])
        if item["status"] not in ("passed", "not_applicable"):
            raise ValueError("Mandatory checks failed or remain blocked")
        if item["status"] == "not_applicable" and required.status != "not_applicable":
            raise ValueError("A mandatory check was marked inapplicable: " + item["name"])
        if item["status"] == "passed":
            log = Path(item.get("log", ""))
            if not log.is_file() or hashlib.sha256(log.read_bytes()).hexdigest() != item.get("log_sha256"):
                raise ValueError("Validation log is missing or changed: " + item["name"])


def find_full_report(root, paths, config):
    """Return (fresh report, previously successful recipes). Stale results themselves are never reused."""
    root = Path(root).resolve()
    directory = root / ".build-tools/contribution"
    candidates = list(directory.glob("tasks/*/report.json")) + list(directory.glob("checks/*/report.json"))
    candidates += list(directory.glob("hooks/*/report.json"))
    current = snapshot(root)
    tools = tool_state()
    hint = None
    for path in sorted(candidates, key=lambda p: p.stat().st_mtime_ns, reverse=True)[:100]:
        try:
            report = json.loads(path.read_text(encoding="utf-8"))
            if report.get("stage") != "review" or report.get("quick") or set(report["paths"]) != set(paths):
                continue
            validate_checks(root, report, path.parent, config)
            if hint is None:
                hint = report.get("recipes", {})
            if report["snapshot"] == current and report["tools"] == tools:
                return path, hint
        except (ValueError, OSError, KeyError, TypeError):
            continue
    return None, hint
