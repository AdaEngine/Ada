"""Small adapters for existing tools. Exit 2 means a required prerequisite is missing."""

import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess

from .repository import safe_path


def content(root, paths):
    errors = []
    for name in paths:
        path = safe_path(root, name)
        if not path.is_file():
            continue
        data = path.read_bytes()
        if b"\0" in data:
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            continue
        if path.suffix in (".yml", ".yaml") or path.name == "SKILL.md":
            if importlib.util.find_spec("yaml") is None:
                print("PyYAML from the validation requirements is needed for YAML/skill checks")
                return 2
            import yaml
            try:
                if path.name == "SKILL.md":
                    frontmatter = re.match(r"\A---\r?\n(.*?)\r?\n---(?:\r?\n|$)", text, re.DOTALL)
                    metadata = yaml.safe_load(frontmatter[1]) if frontmatter else None
                    if not isinstance(metadata, dict) or metadata.get("name") != path.parent.name or not metadata.get("description"):
                        errors.append(name + ": skill name/description/frontmatter is invalid")
                else:
                    yaml.safe_load(text)
            except yaml.YAMLError:
                errors.append(name + ": invalid YAML (source values omitted)")
        if path.suffix == ".json" and (name.startswith(".agents/") or path.name == "package.json"):
            try:
                json.loads(text)
            except ValueError:
                errors.append(name + ": invalid JSON (source values omitted)")
        for number, line in enumerate(text.splitlines(), 1):
            if line.rstrip(" \t") != line:
                errors.append(f"{name}:{number}: trailing whitespace")
            if re.match(r"^(<{7}|={7}|>{7})(?: |$)", line):
                errors.append(f"{name}:{number}: unresolved merge conflict marker")
        if name.startswith("Documentation/Designs/") and re.search(r"[\u0400-\u052f]", text):
            errors.append(name + ": design documents must be English")
        if path.suffix == ".md":
            for match in re.finditer(r"(?<!!)\[[^\]\n]+\]\(([^)\n]+)\)", text):
                target = match.group(1).strip().strip("<>").split("#", 1)[0]
                if not target or re.match(r"[a-zA-Z][a-zA-Z0-9+.-]*:", target) or " " in target:
                    continue
                if not (path.parent / target).exists():
                    errors.append(name + ": missing local link: " + target)
    print("\n".join(errors) if errors else "Content checks passed")
    return bool(errors)


def reviewed_findings(root, findings):
    exceptions_file = root / ".agents/secret-exceptions.json"
    exceptions = json.loads(exceptions_file.read_text(encoding="utf-8"))["exceptions"] if exceptions_file.is_file() else []
    reviewed = {(entry["path"], entry["type"], entry["fingerprint"]) for entry in exceptions if entry["reason"].strip()}
    return {filename: [item for item in items if (
        Path(filename).relative_to(root).as_posix(), item["type"], "sha1:" + item["hashed_secret"]
    ) not in reviewed] for filename, items in findings.items()}


def secrets(root, paths):
    if importlib.util.find_spec("detect_secrets") is None:
        print("Install script/contribution-requirements.txt with this Python interpreter")
        return 2
    from detect_secrets import SecretsCollection
    from detect_secrets.settings import transient_settings

    collection = SecretsCollection()
    # Disable online verification: source and suspected credentials must not leave the machine.
    from detect_secrets.settings import default_settings
    with default_settings() as defaults:
        settings = defaults.json()
    settings["filters_used"] = [item for item in settings["filters_used"]
                                if not item["path"].endswith("is_ignored_due_to_verification_policies")]
    with transient_settings(settings):
        for name in paths:
            path = safe_path(root, name)
            if path.is_file():
                collection.scan_file(str(path))
    findings = reviewed_findings(root, collection.json())
    count = sum(len(items) for items in findings.values())
    for filename, items in findings.items():
        for item in items:
            print(f"{Path(filename).relative_to(root)}:{item['line_number']}: {item['type']} (value redacted)")
    print(f"Secret scanner: {count} findings; heuristic detection is not proof that no secrets exist")
    return bool(count)


def swiftlint(root, paths, mode, logs, package="."):
    executable = shutil.which("swiftlint")
    if not executable:
        print("SwiftLint is required; use a supported host/CI runner")
        return 2
    original = (root / ".swiftlint.yml").read_text(encoding="utf-8")
    # Preserve project rules, replacing only the path scopes excluded by the parent configuration.
    stripped = re.sub(r"(?m)^(included|excluded):[^\n]*(?:\n(?:[ \t]+[^\n]*|#[^\n]*|[ \t]*))*", "", original)
    config = Path(logs) / "swiftlint.yml"
    config.write_text(stripped + "\nincluded: " + json.dumps([str(safe_path(root, p)) for p in paths])
                      + "\nexcluded: []\n", encoding="utf-8")
    command = [executable, mode, "--strict", "--config", str(config)]
    if mode == "analyze":
        compiler_log = Path(logs) / ("editor-build.log" if package == "Editor" else "swift-build.log")
        if not compiler_log.exists():
            print("SwiftLint analyze requires the current compiler log from swift-build")
            return 2
        text = compiler_log.read_text(encoding="utf-8", errors="replace")
        if not all(Path(p).name in text for p in paths) or not re.search(r"swift(?:c|-frontend).* -", text):
            print("Compiler log has no compilation commands for all selected files; use a fresh task-local scratch path")
            return 2
        command += ["--compiler-log-path", str(compiler_log)]
    return subprocess.run(command, cwd=root, check=False).returncode


def main(root, action, paths_file, logs):
    paths = json.loads(Path(paths_file).read_text(encoding="utf-8"))
    if action == "content":
        return int(content(root, paths))
    if action == "secrets":
        return int(secrets(root, paths))
    if action in ("swift-lint", "swift-analysis", "editor-analysis"):
        selected = [p for p in paths if p.endswith(".swift") and safe_path(root, p).is_file()]
        if action != "swift-lint":
            selected = [p for p in selected if p.startswith("Editor/") == (action == "editor-analysis")]
        if not selected:
            print("No existing Swift files selected; compiler validation is still required for deletions")
            return 0
        return swiftlint(root, selected, "lint" if action == "swift-lint" else "analyze", logs,
                         "Editor" if action == "editor-analysis" else ".")
    raise ValueError("Unknown adapter: " + action)
