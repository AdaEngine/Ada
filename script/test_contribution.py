"""Behavioral tests for contributor validation; no engine build is needed."""

import json
import importlib.util
import contextlib
import io
import shlex
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from contribution import adapters, hooks, workflow
from contribution.cli import main
from contribution.cli import status_code
from contribution.evidence import find_full_report
from contribution.documentation import is_article
from contribution.execution import Check, execute, has_executed_tests, tool_state, write_json
from contribution.profiles import build_checks, select_profiles
from contribution.repository import changed_files, git, safe_path, snapshot, staged_files

REPO = Path(__file__).resolve().parents[1]
CONFIG = json.loads((REPO / ".agents/validation.json").read_text())


class ProfileTests(unittest.TestCase):
    def test_browser_agent_instructions_do_not_build_frontend(self):
        checks = build_checks(REPO, ["Editor/WebUI/AGENTS.md"], CONFIG, REPO / "files.json", REPO)
        self.assertNotIn("web-analysis-build", [check.name for check in checks])
        self.assertNotIn("runtime-smoke", [check.name for check in checks])
    def test_studio_user_guide_requires_offline_snapshot_validation(self):
        checks = build_checks(REPO, ["Editor/Documentation/EditorGuide.md"], CONFIG, REPO / "files.json", REPO)
        self.assertIn("offline-docs", [check.name for check in checks])
        self.assertNotIn("runtime-smoke", [check.name for check in checks])

    def test_offline_catalog_update_does_not_select_editor_runtime(self):
        checks = build_checks(REPO, ["Editor/Sources/AdaEditor/Assets/Documentation/catalog.json"], CONFIG, REPO / "files.json", REPO)
        self.assertNotIn("editor-tests", [check.name for check in checks])
        self.assertNotIn("runtime-smoke", [check.name for check in checks])
        self.assertIn("offline-docs", [check.name for check in checks])
    def test_user_article_does_not_select_engine_or_gpu_builds(self):
        profiles = select_profiles(["Sources/AdaRender/AdaRender.docc/RayTracing.md"])
        self.assertNotIn("swift", profiles)
        self.assertNotIn("gpu", profiles)
        self.assertNotIn("platform", profiles)
    def test_python_changes_require_analysis_and_tests(self):
        self.assertIn("python", select_profiles(["script/contribution/profiles.py"]))

    def test_public_manifest_requires_platform_validation(self):
        profiles = select_profiles(["Package.swift"])
        self.assertTrue({"swift", "platform"}.issubset(profiles))

    def test_shared_ecs_change_requires_downstream_and_platform_evidence(self):
        checks = build_checks(REPO, ["Sources/AdaECS/World.swift"], CONFIG, REPO / "files.json", REPO)
        self.assertTrue({"editor-tests", "platform-matrix"}.issubset({check.name for check in checks}))

    def test_renderer_requires_real_gpu_and_runtime_checks(self):
        checks = build_checks(REPO, ["Sources/AdaRender/RenderEngine.swift"], CONFIG, REPO / "files.json", REPO)
        self.assertIn("webgpu", [check.name for check in checks])
        self.assertEqual(next(check for check in checks if check.name == "runtime-smoke").status, "blocked")

    def test_editor_and_root_tests_both_selected_for_shared_change(self):
        checks = build_checks(REPO, ["Sources/AdaUI/View.swift", "Editor/Package.swift"], CONFIG, REPO / "files.json", REPO)
        self.assertTrue({"swift-tests", "editor-tests"}.issubset({check.name for check in checks}))

    def test_windows_swift_checks_limit_compiler_jobs_and_test_workers(self):
        with patch.object(sys, "platform", "win32"):
            checks = build_checks(REPO, ["Sources/AdaUI/View.swift"], CONFIG, REPO / "files.json", REPO)
        commands = {check.name: check.argv for check in checks}
        for prefix in ("swift", "editor"):
            self.assertIn("--jobs", commands[prefix + "-build"])
            self.assertIn("--jobs", commands[prefix + "-tests"])
            self.assertIn("--num-workers", commands[prefix + "-tests"])

    def test_document_change_does_not_build_engine(self):
        checks = build_checks(REPO, ["Documentation/Designs/example.md"], CONFIG, REPO / "files.json", REPO)
        self.assertFalse(any("swift" in check.argv for check in checks))
        self.assertEqual(next(check for check in checks if check.category == "tests").status, "not_applicable")

    def test_validation_policy_change_runs_its_behavioral_suite(self):
        checks = build_checks(REPO, [".agents/validation.json"], CONFIG, REPO / "files.json", REPO)
        self.assertTrue(any("test_contribution.py" in check.argv for check in checks))

    def test_web_change_selects_build_tests_lint_and_runtime(self):
        checks = build_checks(REPO, ["Editor/WebUI/package.json"], CONFIG, REPO / "files.json", REPO)
        names = {check.name for check in checks}
        self.assertTrue({"web-tests", "web-analysis-build", "runtime-smoke", "dependency-review"}.issubset(names))

    def test_explicit_platform_and_dependency_checks_are_executed(self):
        checks = build_checks(REPO, ["Package.swift"], CONFIG, REPO / "files.json", REPO,
                              platform_command=["platform-check"], dependency_command=["advisory-check"])
        self.assertEqual(next(c for c in checks if c.name == "platform-matrix").argv, ["platform-check"])
        self.assertEqual(next(c for c in checks if c.name == "dependency-review").argv, ["advisory-check"])


class RepositoryFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ada workflow with spaces ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        git(self.root, "config", "user.name", "Workflow Test")
        git(self.root, "config", "user.email", "workflow@example.invalid")
        git(self.root, "config", "core.autocrlf", "false")
        git(self.root, "config", "core.whitespace", "cr-at-eol")
        git(self.root, "config", "core.hooksPath", ".git/hooks")
        (self.root / ".gitignore").write_text(".build-tools/\n__pycache__/\n")
        (self.root / ".agents").mkdir()
        write_json(self.root / ".agents/validation.json", CONFIG)
        (self.root / "sample.py").write_text("value = 1\n")
        (self.root / "design.md").write_text("# Design\nExpected behavior.\n")
        (self.root / "plan.md").write_text("# Plan\nImplement behavior.\n")
        git(self.root, "add", ".")
        git(self.root, "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")

    def init_task(self, kind="maintenance", paths=None):
        state = workflow.initialize(self.root, "test", kind, paths or ["sample.py"], "design.md", "plan.md")
        if kind == "feature":
            workflow.configure_documentation(self.root, "test", ["Sources/Example/Example.docc/Guide.md"],
                                             ["Sources/Example/Example.docc/Example.md"])
            state = workflow.load_task(self.root, "test")
        return state

    def copy_runtime(self):
        (self.root / ".agents").mkdir(exist_ok=True)
        write_json(self.root / ".agents/validation.json", CONFIG)
        shutil.copy2(REPO / ".agents/ruff.toml", self.root / ".agents/ruff.toml")
        (self.root / "script").mkdir(exist_ok=True)
        shutil.copy2(REPO / "script/check_contribution.py", self.root / "script/check_contribution.py")
        shutil.copytree(REPO / "script/contribution", self.root / "script/contribution", ignore=shutil.ignore_patterns("__pycache__"))


class RepositoryTests(RepositoryFixture):
    def test_snapshot_detects_modified_new_deleted_and_staged_files(self):
        previous = snapshot(self.root)
        for action in (
            lambda: (self.root / "sample.py").write_text("value = 2\n"),
            lambda: (self.root / "new file.py").write_text("value = 3\n"),
            lambda: git(self.root, "add", "."),
            lambda: (self.root / "sample.py").unlink(),
        ):
            action()
            current = snapshot(self.root)
            self.assertNotEqual(previous, current)
            previous = current

    def test_generated_evidence_does_not_invalidate_snapshot(self):
        before = snapshot(self.root)
        write_json(self.root / ".build-tools/report.json", {"value": "report"})
        self.assertEqual(before, snapshot(self.root))

    def test_changed_paths_include_untracked_files_with_spaces(self):
        (self.root / "new file.py").write_text("value = 3\n")
        self.assertEqual(changed_files(self.root), ["new file.py"])

    def test_rename_retains_both_source_and_destination_for_profile_selection(self):
        git(self.root, "mv", "sample.py", "renamed.txt")
        self.assertEqual(set(changed_files(self.root)), {"sample.py", "renamed.txt"})

    def test_partial_staging_is_rejected_without_changing_worktree(self):
        (self.root / "sample.py").write_text("value = 2\n")
        git(self.root, "add", "sample.py")
        (self.root / "sample.py").write_text("value = 3\n")
        before = snapshot(self.root)
        with self.assertRaisesRegex(ValueError, "Partially staged"):
            staged_files(self.root)
        self.assertEqual(before, snapshot(self.root))

    def test_safe_path_rejects_escape_and_git_internals(self):
        for name in ("../outside", ".git/config", str(self.root / "sample.py")):
            with self.subTest(name=name), self.assertRaises(ValueError):
                safe_path(self.root, name)


class ExecutionTests(RepositoryFixture):
    def test_deferred_check_does_not_pass_complete_validation(self):
        report = {"purpose": "publication", "checks": [{"status": "deferred"}]}
        self.assertEqual(status_code(report), 2)
    def test_utility_success_cannot_replace_required_gpu_evidence(self):
        result = self.run_check([sys.executable, "-c", "print('Ran 1 test')"], tests=True,
                                required_output=["GPU pixel test passed"])
        self.assertEqual(result["status"], "blocked")

    def run_check(self, command, **kwargs):
        return execute(Check("example", "tests", command, **kwargs), self.root, self.root / ".build-tools/logs")

    def test_failure_is_not_success(self):
        result = self.run_check([sys.executable, "-c", "raise SystemExit(1)"])
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["exit_code"], 1)

    def test_missing_executable_blocks(self):
        self.assertEqual(self.run_check(["ada-nonexistent-validator-42"])["status"], "blocked")

    def test_timeout_blocks_and_returns(self):
        result = self.run_check([sys.executable, "-c", "import time; time.sleep(10)"], timeout=0.1)
        self.assertEqual(result["status"], "blocked")
        self.assertLess(result["duration_seconds"], 5)

    def test_empty_test_filter_blocks(self):
        result = self.run_check([sys.executable, "-c", "print('Ran 0 tests')"], tests=True)
        self.assertEqual(result["status"], "blocked")

    def test_positive_test_count_passes_and_log_is_kept(self):
        result = self.run_check([sys.executable, "-c", "print('Ran 2 tests')"], tests=True)
        self.assertEqual(result["status"], "passed")
        self.assertIn("Ran 2 tests", Path(result["log"]).read_text())

    def test_supported_test_runners(self):
        for text in ("Ran 1 test", "Test run with 2 tests passed after 1 second.", "# tests 3\n# pass 3", "Executed 4 tests"):
            self.assertTrue(has_executed_tests(text), text)
        self.assertFalse(has_executed_tests("0 tests passed"))

    def test_entirely_skipped_suite_does_not_pass(self):
        self.assertFalse(has_executed_tests("Ran 3 tests\nOK (skipped=3)"))
        self.assertFalse(has_executed_tests("# tests 3\n# pass 0\n# skipped 3"))

    def test_argv_handles_spaces_and_shell_metacharacters(self):
        value = "a file & echo should-not-execute"
        result = self.run_check([sys.executable, "-c", "import sys; print(sys.argv[1])", value])
        self.assertEqual(Path(result["log"]).read_text().strip(), value)


class WorkflowTests(RepositoryFixture):
    def test_existing_human_guides_are_valid_article_sources(self):
        self.assertTrue(is_article(self.root, "Documentation/Tooling.md"))
        self.assertTrue(is_article(self.root, "Documentation/PathTracing.md"))
        for name in ("Documentation/Designs/feature.md", "Documentation/Plans/feature.md",
                     "Documentation/ArchitectureDecisions/decision.md", "Editor/Documentation/AgentGuides/build.md"):
            self.assertFalse(is_article(self.root, name), name)
    def make_user_guide(self):
        article = "Sources/Example/Example.docc/Guide.md"
        navigation = "Sources/Example/Example.docc/Example.md"
        (self.root / article).parent.mkdir(parents=True)
        (self.root / article).write_text("# Guide\nOriginal public behavior.\n")
        (self.root / navigation).write_text("# Example\n## Topics\n- <doc:Guide>\n")
        return article, navigation

    def documented_feature(self):
        article, navigation = self.make_user_guide()
        workflow.initialize(self.root, "test", "feature", ["sample.py"], "design.md", "plan.md")
        workflow.configure_documentation(self.root, "test", [article], [navigation])
        workflow.approve_design(self.root, "test", "Human approval")
        return article, navigation

    def test_feature_cannot_exempt_user_documentation(self):
        workflow.initialize(self.root, "test", "feature", ["sample.py"], "design.md", "plan.md")
        with self.assertRaisesRegex(ValueError, "feature"):
            workflow.configure_documentation(self.root, "test", [], [], "Internal implementation")

    def test_design_document_does_not_count_as_user_article(self):
        self.init_task()
        with self.assertRaisesRegex(ValueError, "user-facing"):
            workflow.configure_documentation(self.root, "test", ["Documentation/Designs/feature.md"], ["README.md"])

    def test_unchanged_user_article_blocks_review(self):
        self.documented_feature()
        with self.assertRaisesRegex(ValueError, "updated"):
            workflow.gate(self.root, workflow.load_task(self.root, "test"), "review")

    def test_changed_article_must_be_discoverable(self):
        article, navigation = self.documented_feature()
        (self.root / article).write_text("# Guide\nEnable the new behavior with the documented option.\n")
        (self.root / navigation).write_text("# Example\nNavigation without the article.\n")
        with self.assertRaisesRegex(ValueError, "navigation"):
            workflow.gate(self.root, workflow.load_task(self.root, "test"), "review")
        (self.root / navigation).write_text("# Example\n## Topics\n- <doc:Guide>\n")
        workflow.gate(self.root, workflow.load_task(self.root, "test"), "review")

    def test_internal_improvement_has_explicit_documentation_reason(self):
        self.init_task("improvement")
        workflow.configure_documentation(self.root, "test", [], [], "Internal algorithm; public behavior is unchanged")
        workflow.approve_design(self.root, "test", "Human approval")
        workflow.gate(self.root, workflow.load_task(self.root, "test"), "review")

    def test_feature_review_must_confirm_documentation_review(self):
        article, _ = self.documented_feature()
        (self.root / article).write_text("# Guide\nDescribe the implemented capability and its limitations.\n")
        state = workflow.load_task(self.root, "test")
        report = {"reviewer": "separate", "context": "independent", "snapshot": snapshot(self.root),
                  "task_fingerprint": workflow.evidence_hash(state), "verdict": "approved", "findings": []}
        with self.assertRaisesRegex(ValueError, "documentation"):
            workflow.record_review(self.root, "test", report)
        report["user_documentation_reviewed"] = True
        workflow.record_review(self.root, "test", report)
    def test_feature_cannot_advance_without_user_article_plan(self):
        workflow.initialize(self.root, "test", "feature", ["sample.py"], "design.md", "plan.md")
        workflow.approve_design(self.root, "test", "Human approval")
        with self.assertRaisesRegex(ValueError, "user documentation"):
            workflow.gate(self.root, workflow.load_task(self.root, "test"), "code")
    def test_scope_normalizes_windows_file_arguments(self):
        self.copy_runtime()
        self.init_task(paths=["design.md"])
        (self.root / "Sources").mkdir()
        (self.root / "Sources/new.py").write_text("value = 2\n")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(main(["--root", str(self.root), "scope", "--task", "test", "--files", "Sources\\new.py"]), 0)
        state = workflow.load_task(self.root, "test")
        self.assertIn("Sources/new.py", state["paths"])
        workflow.check_scope(self.root, state)

    def run_design_stage(self):
        self.copy_runtime()
        self.init_task(paths=["design.md"])
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(main(["--root", str(self.root), "run", "--task", "test", "--stage", "design"]), 0)
        return workflow.task_directory(self.root, "test") / "report.json"

    def test_matching_earlier_stage_verifies(self):
        self.run_design_stage()
        workflow.verify(self.root, "test", "design")

    def test_removed_check_cannot_verify(self):
        path = self.run_design_stage()
        report = json.loads(path.read_text())
        report["checks"] = []
        write_json(path, report)
        with self.assertRaisesRegex(ValueError, "inventory"):
            workflow.verify(self.root, "test", "design")

    def test_changed_log_cannot_verify(self):
        path = self.run_design_stage()
        report = json.loads(path.read_text())
        Path(report["checks"][0]["log"]).write_text("altered")
        with self.assertRaisesRegex(ValueError, "log is missing or changed"):
            workflow.verify(self.root, "test", "design")

    def test_task_evidence_edit_invalidates_report(self):
        self.run_design_stage()
        state = workflow.load_task(self.root, "test")
        state["tdd_exception"] = "new explanation"
        workflow.save_task(self.root, "test", state)
        with self.assertRaisesRegex(ValueError, "workflow evidence"):
            workflow.verify(self.root, "test", "design")

    @unittest.skipUnless(importlib.util.find_spec("detect_secrets") and importlib.util.find_spec("ruff"), "Use the validation venv for tool integration")
    def test_missing_red_log_blocks_complete_real_workflow(self):
        self.copy_runtime()
        (self.root / "test_sample.py").write_text(
            "import unittest\nfrom sample import value\nclass Example(unittest.TestCase):\n"
            "    def test_value(self): self.assertEqual(value, 2)\n"
        )
        self.init_task("bug", ["sample.py", "test_sample.py"])
        command = [sys.executable, "-B", "-m", "unittest", "discover", "-s", ".", "-p", "test_sample.py"]
        workflow.tdd_cycle(self.root, "test", "red", command, ["test_sample.py"], "1 != 2", "Value should be two")
        (self.root / "sample.py").write_text("value = 2\n")
        workflow.tdd_cycle(self.root, "test", "green", command, ["test_sample.py"])
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            code = main(["--root", str(self.root), "run", "--task", "test", "--stage", "review"])
        self.assertEqual(code, 0, captured.getvalue())
        state = workflow.load_task(self.root, "test")
        workflow.record_review(self.root, "test", {"reviewer": "separate", "context": "separate context",
            "snapshot": snapshot(self.root), "task_fingerprint": workflow.evidence_hash(state), "verdict": "approved", "findings": []})
        workflow.verify(self.root, "test")
        Path(state["tdd"]["red"]["result"]["log"]).unlink()
        with self.assertRaisesRegex(ValueError, "TDD red log"):
            workflow.verify(self.root, "test")

    def test_new_out_of_scope_change_blocks(self):
        state = self.init_task(paths=["design.md"])
        (self.root / "sample.py").write_text("invalid implementation\n")
        with self.assertRaisesRegex(ValueError, "scope"):
            workflow.check_scope(self.root, state)

    def test_feature_requires_human_design_approval(self):
        state = self.init_task("feature")
        with self.assertRaisesRegex(ValueError, "explicit approval"):
            workflow.gate(self.root, state, "plan")
        workflow.approve_design(self.root, "test", "Human approval in test conversation")
        workflow.gate(self.root, workflow.load_task(self.root, "test"), "code")

    def test_design_edit_invalidates_approval(self):
        self.init_task("improvement")
        workflow.approve_design(self.root, "test", "Human approval")
        (self.root / "design.md").write_text("Different requirements\n")
        with self.assertRaisesRegex(ValueError, "changed after"):
            workflow.gate(self.root, workflow.load_task(self.root, "test"), "review")

    def test_existing_task_evidence_is_not_overwritten(self):
        self.init_task()
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.init_task()

    def test_bug_does_not_require_new_design(self):
        state = workflow.initialize(self.root, "bug", "bug", ["sample.py"])
        workflow.gate(self.root, state, "code")

    def test_green_before_red_is_rejected(self):
        self.init_task()
        with self.assertRaisesRegex(ValueError, "Run Red"):
            workflow.tdd_cycle(self.root, "test", "green", [sys.executable, "sample.py"], ["sample.py"])

    def test_tdd_runs_real_regression_then_fix(self):
        (self.root / "test_sample.py").write_text(
            "import unittest\nfrom sample import value\nclass Example(unittest.TestCase):\n"
            "    def test_value(self): self.assertEqual(value, 2)\n"
            "if __name__ == '__main__': unittest.main()\n"
        )
        self.init_task("bug", ["sample.py", "test_sample.py"])
        command = [sys.executable, "test_sample.py"]
        workflow.tdd_cycle(self.root, "test", "red", command, ["test_sample.py"], "1 != 2", "Value should be two")
        (self.root / "sample.py").write_text("value = 2\n")
        # Disable bytecode caching: quick same-size writes can otherwise reuse a timestamp-based pyc.
        command[1:1] = ["-B"]
        with self.assertRaisesRegex(ValueError, "exact command"):
            workflow.tdd_cycle(self.root, "test", "green", command, ["test_sample.py"])

    def test_infrastructure_failure_is_not_red(self):
        self.init_task()
        command = [sys.executable, "-c", "raise ImportError('expected')"]
        with self.assertRaisesRegex(ValueError, "behavioral failure"):
            workflow.tdd_cycle(self.root, "test", "red", command, ["sample.py"], "expected", "Behavior")

    def test_swift_missing_module_is_not_red(self):
        self.init_task()
        command = [sys.executable, "-c", "print('error: no such module MissingDependency'); raise SystemExit(1)"]
        with self.assertRaisesRegex(ValueError, "behavioral failure"):
            workflow.tdd_cycle(self.root, "test", "red", command, ["sample.py"], "no such module", "Behavior")

    def test_complete_tdd_cycle_keeps_production_and_test_evidence(self):
        (self.root / "test_sample.py").write_text(
            "import unittest\nfrom sample import value\nclass Example(unittest.TestCase):\n"
            "    def test_value(self): self.assertEqual(value, 2)\n"
            "if __name__ == '__main__': unittest.main()\n"
        )
        self.init_task("bug", ["sample.py", "test_sample.py"])
        command = [sys.executable, "-B", "test_sample.py"]
        workflow.tdd_cycle(self.root, "test", "red", command, ["test_sample.py"], "1 != 2", "Value should be two")
        (self.root / "sample.py").write_text("value = 2\n")
        workflow.tdd_cycle(self.root, "test", "green", command, ["test_sample.py"])
        (self.root / "sample.py").write_text("value = 1 + 1\n")
        workflow.tdd_cycle(self.root, "test", "refactor", command, ["test_sample.py"])
        state = workflow.load_task(self.root, "test")
        self.assertEqual(set(state["tdd"]), {"red", "green", "refactor"})
        self.assertNotEqual(state["tdd"]["red"]["snapshot"], state["tdd"]["green"]["snapshot"])

    def test_self_review_and_stale_review_rejected(self):
        self.init_task()
        report = {"reviewer": "implementer", "context": "separate", "snapshot": snapshot(self.root),
                  "verdict": "approved", "findings": []}
        with self.assertRaisesRegex(ValueError, "different reviewer"):
            workflow.record_review(self.root, "test", report)
        report.update(reviewer="reviewer", snapshot="outdated")
        with self.assertRaisesRegex(ValueError, "current code"):
            workflow.record_review(self.root, "test", report)

    def test_stale_validation_is_rejected(self):
        self.init_task()
        write_json(workflow.task_directory(self.root, "test") / "report.json",
                   {"snapshot": snapshot(self.root), "tools": tool_state(), "stage": "review", "checks": []})
        (self.root / "sample.py").write_text("value = 2\n")
        with self.assertRaisesRegex(ValueError, "stale"):
            workflow.verify(self.root, "test")


class HookTests(RepositoryFixture):
    @unittest.skipUnless(importlib.util.find_spec("detect_secrets"), "Use the validation venv for full-profile integration")
    def test_pre_push_preserves_recipes_and_reuses_only_fresh_success(self):
        self.copy_runtime()
        config = dict(CONFIG, runtime_paths=["design.md"])
        write_json(self.root / ".agents/validation.json", config)
        git(self.root, "add", ".")
        git(self.root, "-c", "commit.gpgsign=false", "commit", "-qm", "runtime")
        base = git(self.root, "rev-parse", "HEAD").strip()
        counter = "from pathlib import Path; from sample import value; assert value == 1; " \
                  "p=Path('.build-tools/counter'); p.write_text(str(int(p.read_text())+1) if p.exists() else '1')"
        recipe = [sys.executable, "-c", counter]
        with contextlib.redirect_stdout(io.StringIO()):
            code = main(["--root", str(self.root), "check", "--files", "design.md", "--runtime-command", json.dumps(recipe)])
        self.assertEqual(code, 0)
        cached, hint = find_full_report(self.root, ["design.md"], config)
        self.assertIsNotNone(cached)
        self.assertEqual(hint["runtime"], recipe)
        (self.root / "design.md").write_text("# Updated design\n")
        git(self.root, "add", "design.md")
        git(self.root, "-c", "commit.gpgsign=false", "commit", "-qm", "design")
        self.assertIsNone(find_full_report(self.root, ["design.md"], config)[0])
        current = git(self.root, "rev-parse", "HEAD").strip()
        stdin = f"refs/heads/main {current} refs/heads/main {base}\n"
        command = [sys.executable, str(self.root / "script/check_contribution.py"), "--root", str(self.root),
                   "hook", "pre-push", "origin", "remote-url"]
        first = subprocess.run(command, cwd=self.root, input=stdin, capture_output=True, text=True, check=False)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertEqual((self.root / ".build-tools/counter").read_text(), "2")
        second = subprocess.run(command, cwd=self.root, input=stdin, capture_output=True, text=True, check=False)
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertIn("Reused verified full validation", second.stdout)
        self.assertEqual((self.root / ".build-tools/counter").read_text(), "2")

    @unittest.skipUnless(importlib.util.find_spec("detect_secrets"), "Use the validation venv for secret scanning")
    def test_linked_worktree_commit_scans_linked_content(self):
        self.copy_runtime()
        (self.root / "README.md").write_text("Safe main checkout\n")
        with (self.root / ".gitignore").open("a") as output:
            output.write("linked/\n")
        git(self.root, "add", ".")
        git(self.root, "-c", "commit.gpgsign=false", "commit", "-qm", "runtime")
        git(self.root, "config", "core.hooksPath", str(self.root / ".git/hooks"))
        linked = self.root / "linked"
        git(self.root, "worktree", "add", "-qb", "linked-test", str(linked))
        hooks.install(self.root)
        (linked / "README.md").write_text("-----BEGIN " + "RSA PRIVATE KEY-----\n")
        git(linked, "add", "README.md")
        result = subprocess.run(["git", "-C", str(linked), "-c", "commit.gpgsign=false", "commit", "-qm", "reject synthetic key"],
                                capture_output=True, text=True, check=False)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertRegex(result.stdout + result.stderr, r"FAILED\s+secrets")
        self.assertEqual((self.root / "README.md").read_text(), "Safe main checkout\n")

    def test_original_hook_receives_arguments_stdin_and_preserves_failure(self):
        directory = hooks.hooks_directory(self.root)
        output = self.root / ".build-tools/original-hook.json"
        output.parent.mkdir()
        code = "import json,sys; from pathlib import Path; Path(sys.argv[1]).write_text(json.dumps([sys.argv[2:],sys.stdin.read()])); sys.exit(7)"
        command = " ".join(shlex.quote(arg) for arg in (Path(sys.executable).as_posix(), "-c", code, output.as_posix()))
        path = directory / "pre-push.ada-original"
        with path.open("w", newline="\n") as script:
            script.write('#!/bin/sh\n' + command + ' "$@"\n')
        path.chmod(path.stat().st_mode | 0o111)
        stdin = b"refs/heads/main local refs/heads/main remote\n"
        self.assertEqual(hooks.original(self.root, "pre-push", ["origin", "remote-url"], stdin), 7)
        self.assertEqual(json.loads(output.read_text()), [["origin", "remote-url"], stdin.decode()])
    def test_install_preserves_existing_hook_and_is_idempotent(self):
        directory = hooks.hooks_directory(self.root)
        original = b"#!/bin/sh\n# git lfs original\nexit 0\n"
        (directory / "pre-push").write_bytes(original)
        hooks.install(self.root)
        self.assertEqual((directory / "pre-push.ada-original").read_bytes(), original)
        hooks.install(self.root)
        self.assertEqual((directory / "pre-push.ada-original").read_bytes(), original)
        self.assertIn(hooks.MARKER, (directory / "pre-push").read_text())

    def test_conflict_is_detected_before_mutating_any_hook(self):
        directory = hooks.hooks_directory(self.root)
        (directory / "pre-push").write_text("original")
        (directory / "pre-push.ada-original").write_text("backup")
        with self.assertRaisesRegex(ValueError, "conflict"):
            hooks.install(self.root)
        self.assertFalse((directory / "pre-commit").exists())
        self.assertEqual((directory / "pre-push").read_text(), "original")

    def test_custom_hook_path_is_respected(self):
        git(self.root, "config", "core.hooksPath", ".custom-hooks")
        directory = hooks.install(self.root)
        self.assertEqual(directory, self.root / ".custom-hooks")
        self.assertEqual(git(self.root, "config", "core.hooksPath").strip(), ".custom-hooks")


class AdapterTests(RepositoryFixture):
    def test_secret_exception_matches_one_exact_fingerprint_only(self):
        name = str(self.root / "sample.py")
        fingerprint_key = "_".join(("hashed", "secret"))
        findings = {name: [{"type": "Example", fingerprint_key: "reviewed"},
                           {"type": "Example", fingerprint_key: "different"}]}
        write_json(self.root / ".agents/secret-exceptions.json", {"exceptions": [{
            "path": "sample.py", "type": "Example", "fingerprint": "sha1:reviewed", "reason": "Public checksum"}]})
        self.assertEqual(adapters.reviewed_findings(self.root, findings)[name],
                         [{"type": "Example", fingerprint_key: "different"}])
    def test_conflict_markers_fail_content_check(self):
        (self.root / "design.md").write_text("<<<<<<< HEAD\none\n=======\ntwo\n>>>>>>> branch\n")
        self.assertTrue(adapters.content(self.root, ["design.md"]))
    def test_english_design_policy_and_broken_links_are_checked(self):
        directory = self.root / "Documentation/Designs"
        directory.mkdir(parents=True)
        (directory / "example.md").write_text("# Design\n[Missing](missing.md)\n", encoding="utf-8")
        self.assertTrue(adapters.content(self.root, ["Documentation/Designs/example.md"]))

    def test_deleted_files_do_not_crash_content_validation(self):
        self.assertFalse(adapters.content(self.root, ["deleted.md"]))


if __name__ == "__main__":
    unittest.main()
