"""Local publication gates must never be mistaken for complete task validation."""

import argparse
import contextlib
import importlib.util
import io
import json
import subprocess
import sys
import unittest

from contribution import workflow
from contribution.cli import run_checks, status_code
from contribution.execution import Check, execute, tool_state, write_json
from contribution.repository import git, snapshot
from test_contribution import CONFIG, RepositoryFixture


class PublicationTests(RepositoryFixture):
    @unittest.skipUnless(importlib.util.find_spec("detect_secrets"), "Use the full tooling environment")
    def test_new_branch_checks_its_diff_from_configured_remote_base(self):
        self.copy_runtime()
        config = self.policy()
        config["pre_push"]["base_ref"] = "refs/remotes/origin/main"
        write_json(self.root / ".agents/validation.json", config)
        (self.root / "legacy.md").write_text("Unrelated historical whitespace  \n")
        git(self.root, "add", ".")
        git(self.root, "-c", "commit.gpgsign=false", "commit", "-qm", "baseline")
        base = git(self.root, "rev-parse", "HEAD").strip()
        git(self.root, "update-ref", "refs/remotes/origin/main", base)
        (self.root / "design.md").write_text("# Updated design\n")
        git(self.root, "add", "design.md")
        git(self.root, "-c", "commit.gpgsign=false", "commit", "-qm", "new branch change")
        current = git(self.root, "rev-parse", "HEAD").strip()
        stdin = f"refs/heads/new {current} refs/heads/new {'0' * 40}\n"
        command = [sys.executable, str(self.root / "script/check_contribution.py"), "--root", str(self.root),
                   "hook", "pre-push", "origin", "remote-url"]
        result = subprocess.run(command, cwd=self.root, input=stdin, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads((self.root / ".build-tools/contribution/hooks/pre-push/report.json").read_text())
        self.assertEqual(report["paths"], ["design.md"])

    def policy(self):
        config = json.loads(json.dumps(CONFIG))
        directory = self.root / ".github/workflows"
        directory.mkdir(parents=True)
        (directory / "native.yml").write_text(
            "on: [push, pull_request]\njobs:\n  native:\n    runs-on: ubuntu-latest\n"
            "    steps:\n      - run: python -m unittest discover\n"
        )
        config["pre_push"] = {"ci_checks": {"platform-matrix": {
            "targets": [{"workflow": ".github/workflows/native.yml", "job": "native"}],
            "reason": "Platform-specific validation runs on its CI host"}}}
        write_json(self.root / ".agents/validation.json", config)
        return config

    @unittest.skipUnless(importlib.util.find_spec("yaml"), "CI metadata validation needs the tooling environment")
    def test_declared_unavailable_check_is_explicitly_deferred(self):
        from contribution.publication import publication_checks
        config = self.policy()
        check = Check("platform-matrix", "platform", status="blocked", reason="Requires CI")
        selected = publication_checks(self.root, [check], config)[0]
        self.assertEqual(selected.status, "deferred")
        self.assertEqual(selected.ci_targets[0]["job"], "native")
        result = execute(selected, self.root, self.root / ".build-tools/logs")
        report = {"purpose": "publication", "checks": [result]}
        self.assertEqual(status_code(report), 2)
        self.assertEqual(status_code(report, publication=True), 0)

    def test_unmapped_missing_tool_remains_blocked(self):
        from contribution.publication import publication_checks
        check = Check("no-adapter", "tests", status="blocked", reason="Missing executable")
        self.assertEqual(publication_checks(self.root, [check], CONFIG)[0].status, "blocked")

    @unittest.skipUnless(importlib.util.find_spec("yaml"), "CI metadata validation needs the tooling environment")
    def test_real_local_failure_is_not_deferred(self):
        from contribution.publication import publication_checks
        config = self.policy()
        check = Check("platform-matrix", "platform", [sys.executable, "-c", "raise SystemExit(1)"])
        selected = publication_checks(self.root, [check], config)[0]
        self.assertFalse(selected.status)
        self.assertEqual(execute(selected, self.root, self.root / ".build-tools/logs")["status"], "failed")

    @unittest.skipUnless(importlib.util.find_spec("yaml"), "CI metadata validation needs the tooling environment")
    def test_nonexistent_ci_job_cannot_authorize_deferral(self):
        from contribution.publication import publication_checks
        config = self.policy()
        config["pre_push"]["ci_checks"]["platform-matrix"]["targets"][0]["job"] = "missing"
        with self.assertRaisesRegex(ValueError, "CI job"):
            publication_checks(self.root, [Check("platform-matrix", "platform", status="blocked")], config)

    @unittest.skipUnless(importlib.util.find_spec("yaml"), "CI metadata validation needs the tooling environment")
    def test_ci_mapping_accepts_scalar_push_event(self):
        from contribution.publication import publication_checks
        config = self.policy()
        path = self.root / ".github/workflows/native.yml"
        path.write_text(path.read_text().replace("on: [push, pull_request]", "on: push"))
        selected = publication_checks(self.root, [Check("platform-matrix", "platform", status="blocked")], config)
        self.assertEqual(selected[0].status, "deferred")

    def test_publication_receipt_cannot_close_task(self):
        self.init_task()
        state = workflow.load_task(self.root, "test")
        write_json(workflow.task_directory(self.root, "test") / "report.json", {
            "purpose": "publication", "snapshot": snapshot(self.root), "tools": tool_state(),
            "task_fingerprint": workflow.evidence_hash(state), "paths": state["paths"], "stage": "review", "checks": []})
        with self.assertRaisesRegex(ValueError, "Publication"):
            workflow.verify(self.root, "test")

    @unittest.skipUnless(importlib.util.find_spec("detect_secrets"), "Use the full tooling environment")
    def test_deferred_pre_push_still_calls_original_lfs_hook(self):
        self.copy_runtime()
        config = self.policy()
        config["profiles"] = {"platform": {"paths": ["platform.input"]}}
        config["dependency_paths"] = []
        write_json(self.root / ".agents/validation.json", config)
        (self.root / "platform.input").write_text("initial\n")
        git(self.root, "add", ".")
        git(self.root, "-c", "commit.gpgsign=false", "commit", "-qm", "runtime")
        base = git(self.root, "rev-parse", "HEAD").strip()
        (self.root / "platform.input").write_text("updated\n")
        git(self.root, "add", "platform.input")
        git(self.root, "-c", "commit.gpgsign=false", "commit", "-qm", "change")
        original = self.root / ".git/hooks/pre-push.ada-original"
        with original.open("w", newline="\n") as script:
            script.write("#!/bin/sh\nmkdir -p .build-tools\ncat > .build-tools/lfs-input\n")
        original.chmod(original.stat().st_mode | 0o111)
        current = git(self.root, "rev-parse", "HEAD").strip()
        stdin = f"refs/heads/main {current} refs/heads/main {base}\n"
        command = [sys.executable, str(self.root / "script/check_contribution.py"), "--root", str(self.root),
                   "hook", "pre-push", "origin", "remote-url"]
        result = subprocess.run(command, cwd=self.root, input=stdin, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertRegex(result.stdout, r"DEFERRED\s+platform-matrix")
        self.assertEqual((self.root / ".build-tools/lfs-input").read_text(), stdin)
        report = json.loads((self.root / ".build-tools/contribution/hooks/pre-push/report.json").read_text())
        self.assertEqual(report["purpose"], "publication")

    @unittest.skipUnless(importlib.util.find_spec("detect_secrets"), "Use the full tooling environment")
    def test_publication_cache_is_not_complete_validation_cache(self):
        from contribution.evidence import find_full_report
        self.copy_runtime()
        directory = self.root / ".build-tools/contribution/checks/example"
        args = argparse.Namespace(quick=False, runtime_command=None, platform_command=None, dependency_command=None)
        with contextlib.redirect_stdout(io.StringIO()):
            run_checks(self.root.resolve(), ["design.md"], CONFIG, directory.resolve(), args, purpose="publication")
        self.assertIsNone(find_full_report(self.root, ["design.md"], CONFIG)[0])
        self.assertIsNotNone(find_full_report(self.root, ["design.md"], CONFIG, publication=True)[0])

    @unittest.skipUnless(importlib.util.find_spec("detect_secrets"), "Use the full tooling environment")
    def test_cache_rejects_deferral_of_an_executable_local_check(self):
        from contribution.evidence import find_full_report
        self.copy_runtime()
        directory = self.root / ".build-tools/contribution/checks/example"
        args = argparse.Namespace(quick=False, runtime_command=None, platform_command=None, dependency_command=None)
        with contextlib.redirect_stdout(io.StringIO()):
            report = run_checks(self.root.resolve(), ["design.md"], CONFIG, directory.resolve(), args, purpose="publication")
        report["checks"][0]["status"] = "deferred"
        write_json(directory / "report.json", report)
        self.assertIsNone(find_full_report(self.root, ["design.md"], CONFIG, publication=True)[0])


if __name__ == "__main__":
    unittest.main()
