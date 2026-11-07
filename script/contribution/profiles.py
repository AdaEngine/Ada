"""Choose validation scopes from repository-relative changed paths."""

import fnmatch
import json
import importlib.util
from pathlib import Path
import sys

from .execution import Check


def is_documentation_path(path):
    return path.endswith(".md") or ".docc/" in path or path.startswith("Editor/Sources/AdaEditor/Assets/Documentation/")


def select_profiles(paths, config=None):
    """Return the validation profiles required by a change."""
    if config is None:
        config = json.loads((Path(__file__).resolve().parents[2] / ".agents/validation.json").read_text())
    return {"common"} | {
        name for name, profile in config["profiles"].items()
        if any(fnmatch.fnmatchcase(path, pattern) and
               (not is_documentation_path(path) or name in ("documentation", "user_documentation"))
               for path in paths for pattern in profile["paths"])
    }


def python_suites(root, paths, config):
    suites = set()
    for name in paths:
        if not name.endswith(".py"):
            continue
        mapped = [suite for pattern, values in config["python_suites"].items()
                  if fnmatch.fnmatchcase(name, pattern) for suite in values]
        if mapped:
            suites.update(mapped)
            continue
        path = Path(name)
        if path.name.startswith("test_"):
            suites.add(name)
        else:
            candidate = path.with_name("test_" + path.name)
            if (root / candidate).exists():
                suites.add(candidate.as_posix())
            elif (root / path.parent).exists():
                suites.update(p.relative_to(root).as_posix() for p in (root / path.parent).glob("test_*.py"))
    return sorted(suites)


def build_checks(root, paths, config, paths_file, logs, quick=False, runtime=None, platform_command=None,
                 dependency_command=None):
    runtime_requested = runtime is not None
    recipes = config.get("commands", {})
    for recipe in recipes.values():
        if recipe is not None and (not isinstance(recipe, list) or not recipe or
                                   not all(isinstance(value, str) and value for value in recipe)):
            raise ValueError("Configured commands must be nonempty JSON argv arrays")
    runtime = runtime or recipes.get("runtime")
    platform_command = platform_command or recipes.get("platform")
    dependency_command = dependency_command or recipes.get("dependency")
    profiles = select_profiles(paths, config)
    timeout = config["timeout_seconds"]
    python = sys.executable
    entry = str(root / "script/check_contribution.py")

    def adapter(name, category):
        return Check(name, category, [python, entry, "adapter", name, "--files-from", str(paths_file),
                                     "--logs", str(logs)], timeout=timeout)

    def module(name, category, module_name, arguments):
        if importlib.util.find_spec(module_name) is None:
            return Check(name, category, status="blocked", reason="Missing Python tool: " + module_name)
        return Check(name, category, [python, "-m", module_name, *arguments], timeout=timeout)

    checks = [Check("git-diff", "style", ["git", "diff", "--check", "--no-ext-diff", "HEAD", "--", *paths]),
              adapter("content", "style"), adapter("secrets", "security")]
    python_paths = [p for p in paths if p.endswith(".py") and (root / p).is_file()]
    if "workflow" in profiles:
        python_paths = sorted(set(python_paths) | {p.relative_to(root).as_posix()
                              for p in (root / "script/contribution").glob("*.py")}
                              | {"script/check_contribution.py", "script/test_contribution.py"})
    if "python" in profiles or "workflow" in profiles:
        if python_paths:
            checks.append(module("python-lint", "style", "ruff", ["check", "--config", ".agents/ruff.toml", *python_paths]))
            checks.append(module("python-analysis", "analysis", "bandit",
                                 ["--severity-level", "medium", "--confidence-level", "medium", "-f", "json", *python_paths]))
        if not quick:
            suites = python_suites(root, python_paths, config)
            if "workflow" in profiles:
                suites = sorted(set(suites) | {"script/test_contribution.py"})
            if not suites:
                checks.append(Check("python-tests", "tests", status="blocked", reason="No owning Python suite configured"))
            for number, suite in enumerate(suites):
                argv = [python, "-m", "unittest", "discover", "-s", suite] if (root / suite).is_dir() else [
                    python, "-m", "unittest", "discover", "-s", str(Path(suite).parent), "-p", Path(suite).name]
                checks.append(Check("python-tests-" + str(number), "tests", argv, tests=True, timeout=timeout))
    if "swift" in profiles or "editor" in profiles:
        swift_paths = [p for p in paths if p.endswith(".swift") and (root / p).is_file()]
        checks.append(adapter("swift-lint", "style") if swift_paths else
                      Check("swift-lint", "style", status="not_applicable", reason="No existing Swift source changed"))
        if not quick:
            packages = (["."] if "swift" in profiles else []) + ["Editor"]
            for package in packages:
                prefix = "editor" if package == "Editor" else "swift"
                scratch = config["swift_scratch"] + ("-editor" if package == "Editor" else "")
                common = ["--package-path", package, "--scratch-path", scratch]
                jobs = ["--jobs", "2"] if sys.platform == "win32" else []
                parallelism = "--no-parallel" if sys.platform == "win32" else "--parallel"
                checks.append(Check(prefix + "-build", "analysis", ["swift", "build", "--build-tests", "-v", *jobs, *common], timeout=timeout))
                selected = [p for p in swift_paths if p.startswith("Editor/") == (package == "Editor")]
                checks.append(adapter(prefix + "-analysis", "analysis") if selected else
                              Check(prefix + "-analysis", "analysis", status="not_applicable",
                                    reason="No existing Swift source changed in " + package))
                checks.append(Check(prefix + "-tests", "tests", ["swift", "test", parallelism, *jobs, *common], tests=True, timeout=timeout))
    if "web" in profiles:
        selected = [str(root / p) for p in paths if p.startswith("Editor/WebUI/")
                    and Path(p).suffix in (".js", ".jsx", ".mjs", ".ts", ".tsx", ".css") and (root / p).is_file()]
        if selected:
            checks.append(Check("web-lint", "style", ["node", "node_modules/prettier/bin/prettier.cjs", "--check", *selected],
                                cwd="Editor/WebUI", timeout=timeout))
        if not quick:
            checks.append(Check("web-analysis-build", "analysis", ["node", "scripts/build.mjs"], cwd="Editor/WebUI", timeout=timeout))
            tests = sorted(str(p.relative_to(root / "Editor/WebUI")) for p in (root / "Editor/WebUI/test").glob("*.test.mjs"))
            checks.append(Check("web-tests", "tests", ["node", "--test", *tests], cwd="Editor/WebUI", tests=True, timeout=timeout))
            checks.append(Check("web-localization", "style", ["node", "scripts/check-localization.mjs"], cwd="Editor/WebUI", timeout=timeout))
    if not quick and "gpu" in profiles:
        checks.append(Check("webgpu", "dynamic", ["bash", "script/validate_webgpu.sh"], timeout=timeout,
                            tests=True, env={"ADAENGINE_WEBGPU_TEST_FILTER": ""}, required_output=[
                                r"Test rendersLayoutsAndPickingWithWebGPU\(\).*passed",
                                r"Test rendersTileOcclusionWithWebGPU\(\).*passed",
                                r'Suite "3D GPU rendering" passed']))
    runtime_needed = any(not is_documentation_path(p) and fnmatch.fnmatchcase(p, pattern)
                         for p in paths for pattern in config["runtime_paths"])
    if not quick and "user_documentation" in profiles:
        checks.append(Check("offline-docs", "documentation", [python, "Editor/scripts/update-offline-documentation.py", "--check"], timeout=timeout))
    if not quick and (runtime_needed or runtime_requested):
        checks.append(Check("runtime-smoke", "dynamic", runtime or [], timeout=timeout,
                            status="" if runtime else "blocked", reason="" if runtime else "Provide a real runtime smoke command for this change"))
    if not quick and "platform" in profiles:
        checks.append(Check("platform-matrix", "platform", platform_command or [], timeout=timeout,
                            status="" if platform_command else "blocked",
                            reason="" if platform_command else "Provide the required platform validation command or use its CI runner"))
    if not quick and any(fnmatch.fnmatchcase(p, pattern) for p in paths for pattern in config["dependency_paths"]):
        if dependency_command:
            checks.append(Check("dependency-review", "security", dependency_command, timeout=timeout))
        elif all(p == "script/contribution-requirements.txt" or not any(fnmatch.fnmatchcase(p, pattern)
                 for pattern in config["dependency_paths"]) for p in paths):
            checks.append(module("dependency-review", "security", "pip_audit",
                                 ["-r", "script/contribution-requirements.txt", "--progress-spinner", "off"]))
        else:
            checks.append(Check("dependency-review", "security", status="blocked",
                                reason="Provide advisory analysis for the changed dependency manifests"))
    for category in ("style", "analysis", "tests", "dynamic", "platform", "security"):
        if not any(check.category == category for check in checks):
            checks.append(Check(category + "-not-applicable", category, status="not_applicable",
                                reason="No changed paths require this category in the selected profile"))
    return checks
