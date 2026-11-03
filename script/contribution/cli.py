"""Contributor validation CLI."""

import argparse
from dataclasses import asdict
import json
import os
from pathlib import Path
import subprocess
import sys
import time

from . import adapters, hooks, workflow
from .execution import execute, tool_state, write_json
from .evidence import find_full_report
from .profiles import build_checks, select_profiles
from .repository import changed_files, git, safe_path, snapshot, staged_files


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    commands = result.add_subparsers(dest="command", required=True)
    for name in ("init", "approve-design", "plan", "run", "verify", "tdd", "explain-tdd", "record-review", "snapshot", "check", "scope", "documentation"):
        command = commands.add_parser(name)
        command.add_argument("--task", default="current")
        if name in ("init", "plan", "check"):
            command.add_argument("--base", default="HEAD")
            command.add_argument("--files", nargs="+")
            command.add_argument("--files-from", type=Path)
        if name == "init":
            command.add_argument("--kind", choices=("feature", "improvement", "bug", "maintenance"), required=True)
            command.add_argument("--design")
            command.add_argument("--plan")
            command.add_argument("--implementer", default="implementer")
        if name in ("run", "verify"):
            command.add_argument("--stage", choices=("design", "plan", "code", "review", "done"),
                                 default="done" if name == "verify" else "review")
        if name in ("plan", "run", "check"):
            command.add_argument("--quick", action="store_true")
            command.add_argument("--runtime-command", type=json.loads)
            command.add_argument("--platform-command", type=json.loads)
            command.add_argument("--dependency-command", type=json.loads)
        if name in ("approve-design", "explain-tdd"):
            command.add_argument("--source" if name == "approve-design" else "--reason", required=True)
            if name == "explain-tdd":
                command.add_argument("--evidence-files", nargs="*", default=[])
        if name == "record-review":
            command.add_argument("--file", type=Path, required=True)
        if name == "scope":
            command.add_argument("--files", nargs="+", required=True)
        if name == "documentation":
            command.add_argument("--articles", nargs="*", default=[])
            command.add_argument("--navigation", nargs="*", default=[])
            command.add_argument("--internal-only-reason", default="")
        if name == "tdd":
            command.add_argument("--phase", choices=("red", "green", "refactor"), required=True)
            test_command = command.add_mutually_exclusive_group(required=True)
            test_command.add_argument("--command-json", type=json.loads)
            test_command.add_argument("--command-file", type=Path)
            command.add_argument("--test-files", nargs="+", required=True)
            command.add_argument("--expected", default="")
            command.add_argument("--reason", default="")
    commands.add_parser("install-hooks")
    ci_files = commands.add_parser("ci-files")
    ci_files.add_argument("--output", type=Path, required=True)
    adapter = commands.add_parser("adapter")
    adapter.add_argument("action", choices=("content", "secrets", "swift-lint", "swift-analysis", "editor-analysis"))
    adapter.add_argument("--files-from", type=Path, required=True)
    adapter.add_argument("--logs", type=Path, required=True)
    hook = commands.add_parser("hook")
    hook.add_argument("event", choices=("pre-commit", "pre-push"))
    hook.add_argument("arguments", nargs="*")
    return result


def input_paths(args, root):
    if getattr(args, "files_from", None):
        paths = json.loads(args.files_from.read_text(encoding="utf-8"))
    elif getattr(args, "files", None):
        paths = args.files
    else:
        paths = changed_files(root, args.base)
    if not isinstance(paths, list) or not all(isinstance(p, str) for p in paths):
        raise ValueError("Files must be a JSON array of repository-relative paths")
    paths = sorted({Path(p.replace("\\", "/")).as_posix() for p in paths})
    for name in paths:
        if safe_path(root, name).is_dir():
            raise ValueError("Pass exact file paths, not directories: " + name)
    return paths


def command_vector(value):
    if value is not None and (not isinstance(value, list) or not value or
                              not all(isinstance(item, str) and item for item in value)):
        raise ValueError("Commands are nonempty JSON argv arrays, not shell strings")
    return value


def checks_for(root, paths, config, directory, args):
    return build_checks(root, paths, config, directory / "paths.json", directory,
                        quick=args.quick, runtime=command_vector(args.runtime_command),
                        platform_command=command_vector(args.platform_command),
                        dependency_command=command_vector(args.dependency_command))


def run_checks(root, paths, config, directory, args, stage="review"):
    directory.mkdir(parents=True, exist_ok=True)
    write_json(directory / "paths.json", paths)
    before = snapshot(root)
    before_tools = tool_state()
    checks = checks_for(root, paths, config, directory, args)
    if stage != "review":
        checks = [check for check in checks if check.name == "content"]
    results = []
    for check in checks:
        result = execute(check, root, directory)
        results.append(result)
        print(f"{result['status'].upper():14} {result['name']}" +
              (": " + result["reason"] if result.get("reason") else ""), flush=True)
    report = {"schema": 1, "snapshot": before, "tools": tool_state(), "stage": stage,
              "quick": args.quick, "paths": paths, "profiles": sorted(select_profiles(paths, config)),
              "checks": results, "created": time.time(),
              "recipes": {"runtime": args.runtime_command, "platform": args.platform_command,
                          "dependency": args.dependency_command}}
    if snapshot(root) != before or tool_state() != before_tools:
        report["checks"].append({"name": "input-freshness", "status": "blocked", "reason": "Inputs changed during validation"})
    write_json(directory / "report.json", report)
    print("Report: " + str(directory / "report.json"))
    return report


def status_code(report):
    statuses = {check["status"] for check in report["checks"]}
    return 1 if "failed" in statuses else (2 if "blocked" in statuses else 0)


def hook(root, args, config):
    stdin = sys.stdin.buffer.read() if args.event == "pre-push" else b""
    if args.event == "pre-commit":
        paths = staged_files(root)
    else:
        if changed_files(root):
            raise ValueError("Pre-push requires a clean worktree so checks cover the outgoing commit")
        paths = set()
        for line in stdin.decode("utf-8").splitlines():
            _local_ref, local, _remote_ref, remote = line.split()
            if set(local) == {"0"}:
                continue
            if local != git(root, "rev-parse", "HEAD").strip():
                raise ValueError("Check out each outgoing branch before validating its push")
            if set(remote) == {"0"}:
                paths.update(filter(None, git(root, "ls-files", "-z").split("\0")))
            else:
                paths.update(changed_files(root, remote))
        paths = sorted(paths)
    if paths:
        args.quick = args.event == "pre-commit"
        args.runtime_command = args.platform_command = args.dependency_command = None
        if args.event == "pre-push":
            cached, recipes = find_full_report(root, paths, config)
            if cached:
                print("Reused verified full validation: " + str(cached))
                return hooks.original(root, args.event, args.arguments, stdin)
            if recipes:
                args.runtime_command = command_vector(recipes.get("runtime"))
                args.platform_command = command_vector(recipes.get("platform"))
                args.dependency_command = command_vector(recipes.get("dependency"))
        directory = root / ".build-tools/contribution/hooks" / args.event
        report = run_checks(root, paths, config, directory, args)
        if status_code(report):
            return status_code(report)
    return hooks.original(root, args.event, args.arguments, stdin)


def main(argv=None):
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="backslashreplace")
    args = parser().parse_args(argv)
    root = args.root.resolve()
    try:
        if args.command == "adapter":
            return adapters.main(root, args.action, args.files_from, args.logs)
        config = json.loads((root / ".agents/validation.json").read_text(encoding="utf-8"))
        if config.get("version") != 1:
            raise ValueError("Unsupported validation configuration version")
        if args.command == "install-hooks":
            print("Installed hooks in " + str(hooks.install(root)))
        elif args.command == "ci-files":
            event_path = os.environ.get("GITHUB_EVENT_PATH")
            if not event_path:
                raise ValueError("GITHUB_EVENT_PATH is required for ci-files")
            event = json.loads(Path(event_path).read_text(encoding="utf-8"))
            base = event.get("pull_request", {}).get("base", {}).get("sha") or event.get("before")
            if base and set(base) != {"0"}:
                paths = changed_files(root, base)
            else:
                paths = sorted(filter(None, git(root, "ls-files", "-z").split("\0")))
            write_json(args.output, paths)
            if os.environ.get("GITHUB_OUTPUT"):
                profiles = select_profiles(paths, config)
                with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
                    output.write("swift=" + str(bool(profiles & {"swift", "editor"})).lower() + "\n")
                    output.write("web=" + str("web" in profiles).lower() + "\n")
            print("Selected " + str(len(paths)) + " CI paths")
        elif args.command == "hook":
            return hook(root, args, config)
        elif args.command == "snapshot":
            data = {"snapshot": snapshot(root)}
            if (workflow.task_directory(root, args.task) / "task.json").exists():
                data["task_fingerprint"] = workflow.evidence_hash(workflow.load_task(root, args.task))
            print(json.dumps(data))
        elif args.command == "init":
            paths = input_paths(args, root)
            workflow.initialize(root, args.task, args.kind, paths, args.design, args.plan, args.implementer)
            print("Initialized task " + args.task)
        elif args.command == "approve-design":
            workflow.approve_design(root, args.task, args.source)
            print("Recorded approval reference; the human source remains subject to review")
        elif args.command == "tdd":
            command = json.loads(args.command_file.read_text(encoding="utf-8")) if args.command_file else args.command_json
            workflow.tdd_cycle(root, args.task, args.phase, command_vector(command),
                               args.test_files, args.expected, args.reason)
            print("Recorded " + args.phase + " evidence")
        elif args.command == "explain-tdd":
            state = workflow.load_task(root, args.task)
            state["tdd_exception"] = args.reason
            state["tdd_exception_evidence"] = {name: workflow.document_hash(root, name) for name in args.evidence_files}
            workflow.save_task(root, args.task, state)
            print("Recorded TDD applicability explanation for independent review")
        elif args.command == "scope":
            state = workflow.load_task(root, args.task)
            names = input_paths(args, root)
            state["paths"] = sorted(set(state["paths"]) | set(names))
            workflow.save_task(root, args.task, state)
            print("Expanded task scope; prior evidence must be refreshed")
        elif args.command == "documentation":
            workflow.configure_documentation(root, args.task, args.articles, args.navigation, args.internal_only_reason)
            print("Recorded user documentation delivery requirements for independent review")
        elif args.command == "record-review":
            workflow.record_review(root, args.task, json.loads(args.file.read_text(encoding="utf-8")))
            print("Recorded independent review")
        elif args.command == "verify":
            workflow.verify(root, args.task, args.stage)
            print("Verified " + args.stage + " evidence; this is not proof of hosted branch protection")
        else:
            state = None
            if args.command == "run":
                state = workflow.load_task(root, args.task)
                workflow.gate(root, state, args.stage)
                paths = state["paths"]
            else:
                paths = input_paths(args, root)
            directory = (workflow.task_directory(root, args.task) if state else
                         root / ".build-tools/contribution/checks" / str(time.time_ns()))
            if args.command == "plan":
                print(json.dumps([asdict(check) for check in checks_for(root, paths, config, directory, args)], indent=2))
            else:
                report = run_checks(root, paths, config, directory, args, args.stage if state else "review")
                if state:
                    report["task_fingerprint"] = workflow.evidence_hash(state)
                    write_json(directory / "report.json", report)
                return status_code(report)
        return 0
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print("BLOCKED: " + str(error), file=sys.stderr)
        return 2
