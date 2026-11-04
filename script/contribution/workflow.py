"""Local workflow evidence. Human and reviewer identity are attestations, not authentication."""

import hashlib
import json
from pathlib import Path
import re
import time

from .execution import Check, execute, tool_state, write_json
from .evidence import validate_checks
from .documentation import baseline as documentation_baseline, declaration, require_documentation
from .repository import changed_files, document_hash, git, safe_path, snapshot


def task_directory(root, task):
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}", task):
        raise ValueError("Task IDs contain only letters, digits, '-' and '_'")
    return Path(root) / ".build-tools/contribution/tasks" / task


def load_task(root, task):
    path = task_directory(root, task) / "task.json"
    if not path.exists():
        raise ValueError("Initialize the task first with init")
    return json.loads(path.read_text(encoding="utf-8"))


def save_task(root, task, state):
    write_json(task_directory(root, task) / "task.json", state)


def initialize(root, task, kind, paths, design=None, plan=None, implementer="implementer"):
    directory = task_directory(root, task)
    if (directory / "task.json").exists():
        raise ValueError("Task already exists; use a new ID rather than replacing evidence")
    for name in [*paths, *([design] if design else []), *([plan] if plan else [])]:
        safe_path(root, name)
    owned = sorted(set(paths) | ({design} if design else set()) | ({plan} if plan else set()))
    state = {"kind": kind, "paths": owned, "design": design, "plan": plan, "implementer": implementer,
             "baseline": snapshot(root), "created": time.time(), "tdd": {},
             "documentation_baseline": documentation_baseline(root),
             "base_revision": git(root, "rev-parse", "HEAD").strip(),
             "initial_changes": {name: file_hash(root, name) for name in changed_files(root)}}
    save_task(root, task, state)
    return state


def file_hash(root, name):
    path = safe_path(root, name)
    return document_hash(root, name) if path.is_file() else "<missing>"


def check_scope(root, state):
    outside = [name for name in changed_files(root, state["base_revision"]) if name not in state["paths"]
               and file_hash(root, name) != state["initial_changes"].get(name)]
    if outside:
        raise ValueError("New changes outside task scope; inspect them and use scope --files: " + ", ".join(outside))


def evidence_hash(state):
    data = {key: value for key, value in state.items() if key != "review"}
    return hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()


def approve_design(root, task, source):
    state = load_task(root, task)
    if not source.strip() or not state.get("design"):
        raise ValueError("A design path and an explicit human approval source are required")
    state["approval"] = {"source": source, "design_hash": document_hash(root, state["design"]),
                         "recorded": time.time(), "trust": "local attestation; human source must be reviewed"}
    save_task(root, task, state)


def configure_documentation(root, task, articles, navigation, reason=""):
    state = load_task(root, task)
    declaration(root, state, articles, navigation, reason)
    save_task(root, task, state)


def gate(root, state, stage):
    check_scope(root, state)
    if stage in ("plan", "code", "review", "done") and state["kind"] in ("feature", "improvement"):
        if not state.get("design") or not state.get("approval"):
            raise ValueError("Give the design to the human and record their explicit approval before proceeding")
        if document_hash(root, state["design"]) != state["approval"]["design_hash"]:
            raise ValueError("Design changed after human approval; return the document for approval")
    if stage in ("plan", "code", "review", "done") and state["kind"] == "feature":
        if not state.get("plan") or not safe_path(root, state["plan"]).is_file():
            raise ValueError("An implementation plan is required after design approval")
    require_documentation(root, state, stage)


def tdd_cycle(root, task, phase, command, test_files, expected="", reason=""):
    state = load_task(root, task)
    gate(root, state, "code")
    if not command or not test_files:
        raise ValueError("A test command and test files are required")
    hashes = {p: document_hash(root, p) for p in test_files}
    history = state["tdd"]
    if phase != "red":
        previous = history.get("red")
        if not previous or previous["command"] != command or previous["tests"] != hashes:
            raise ValueError("Run Red for this exact command and test content before Green/Refactor")
        if phase == "refactor" and "green" not in history:
            raise ValueError("Run Green before Refactor")
    elif not expected or not reason.strip():
        raise ValueError("Red requires an expected failure regex and a behavioral explanation")
    directory = task_directory(root, task) / ("tdd-" + str(time.time_ns()))
    before = snapshot(root)
    result = execute(Check("tdd-" + phase, "tests", command, tests=phase != "red"), root, directory)
    output = Path(result["log"]).read_text(encoding="utf-8", errors="replace") if result.get("log") else ""
    if phase == "red":
        infrastructure_failure = re.search(
            r"ModuleNotFoundError|ImportError|SyntaxError|no such file|command not found|failed to build|"
            r"no such module|could not build|could not compile|no tests found", output, re.IGNORECASE
        )
        selected = re.search(r"Ran [1-9]\d* tests?|Test run with [1-9]\d* tests?|# tests [1-9]\d*|Executed [1-9]\d* tests?", output)
        assertion = re.search(r"AssertionError|FAIL:|FAILED.*failures|Expectation failed|# fail [1-9]", output)
        accepted = result["status"] == "failed" and selected and assertion and not infrastructure_failure and re.search(expected, output)
        if not accepted:
            raise ValueError("Red must demonstrate the expected behavioral failure, not an infrastructure failure")
        history.clear()
    elif result["status"] != "passed":
        raise ValueError("TDD test did not pass; inspect " + result.get("log", "the prerequisite"))
    if snapshot(root) != before:
        raise ValueError("The test command changed repository inputs; inspect its side effects and rerun")
    history[phase] = {"command": command, "tests": hashes, "result": result,
                      "snapshot": before, "reason": reason, "recorded": time.time()}
    save_task(root, task, state)
    return result


def record_review(root, task, report):
    state = load_task(root, task)
    if report.get("reviewer") == state["implementer"] or not report.get("reviewer") or not report.get("context"):
        raise ValueError("Review requires a different reviewer and an explicit independent context reference")
    if report.get("snapshot") != snapshot(root):
        raise ValueError("Review does not cover the current code state")
    if report.get("task_fingerprint") != evidence_hash(state):
        raise ValueError("Review does not cover the current task, approval, and TDD evidence")
    if report.get("verdict") not in ("approved", "changes_requested", "needs_human"):
        raise ValueError("Invalid review verdict")
    if not isinstance(report.get("findings"), list):
        raise ValueError("Review must contain a findings list")
    if report["verdict"] == "approved" and report["findings"]:
        raise ValueError("An approved review cannot contain unresolved findings")
    if report["verdict"] == "approved" and state.get("user_documentation") and report.get("user_documentation_reviewed") is not True:
        raise ValueError("Independent approval must explicitly confirm user documentation review")
    state["review"] = report
    save_task(root, task, state)


def verify(root, task, stage="done"):
    root = Path(root).resolve()
    state = load_task(root, task)
    gate(root, state, stage)
    report_path = task_directory(root, task) / "report.json"
    if not report_path.exists():
        raise ValueError("Run the full validation profile first")
    report = json.loads(report_path.read_text(encoding="utf-8"))
    if report.get("purpose", "complete") != "complete":
        raise ValueError("Publication evidence cannot close a task; obtain complete validation and required CI results")
    current = snapshot(root)
    if report["snapshot"] != current or report["tools"] != tool_state():
        raise ValueError("Validation evidence is stale: source, configuration, tools, or environment changed")
    if report.get("task_fingerprint") != evidence_hash(state) or report.get("paths") != state["paths"]:
        raise ValueError("Validation does not cover the current task scope and workflow evidence")
    expected_stage = "review" if stage == "done" else stage
    if report["stage"] != expected_stage or report.get("quick"):
        raise ValueError("A complete validation report for " + expected_stage + " is required")
    config = json.loads((Path(root) / ".agents/validation.json").read_text(encoding="utf-8"))
    validate_checks(root, report, report_path.parent, config, expected_stage)
    if stage == "done":
        for name, digest in state.get("tdd_exception_evidence", {}).items():
            if document_hash(root, name) != digest:
                raise ValueError("Referenced TDD exception evidence changed")
        for phase, evidence in state["tdd"].items():
            log = Path(evidence["result"].get("log", ""))
            if not log.is_file() or hashlib.sha256(log.read_bytes()).hexdigest() != evidence["result"].get("log_sha256"):
                raise ValueError("TDD " + phase + " log is missing or changed")
        review = state.get("review", {})
        if review.get("snapshot") != current or review.get("verdict") != "approved":
            raise ValueError("Independent review of the final code is required")
        if review.get("task_fingerprint") != evidence_hash(state):
            raise ValueError("Independent review is stale after workflow evidence changed")
        code_changed = any(Path(p).suffix in (".py", ".swift", ".js", ".jsx", ".ts", ".tsx", ".c", ".cpp")
                           for p in state["paths"])
        if code_changed and "green" not in state["tdd"] and not state.get("tdd_exception"):
            raise ValueError("TDD evidence or a reviewer-visible applicability explanation is required")
        if "green" in state["tdd"] and any(document_hash(root, name) != digest
                    for name, digest in state["tdd"]["green"]["tests"].items()):
            raise ValueError("TDD tests changed after Green; record a fresh cycle or reviewed explanation")
    return report
