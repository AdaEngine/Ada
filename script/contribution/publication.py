"""Local publication checks and explicit, still-required CI delegation."""

from dataclasses import replace
from pathlib import Path
import shutil

from .repository import safe_path


def validate_target(root, target):
    name, job = target.get("workflow", ""), target.get("job", "")
    if not name.startswith(".github/workflows/") or Path(name).suffix not in (".yml", ".yaml"):
        raise ValueError("CI delegation requires a repository workflow path")
    path = safe_path(root, name)
    try:
        import yaml
    except ImportError as error:
        raise ValueError("CI metadata validation requires the configured tooling environment") from error
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or job not in data.get("jobs", {}):
        raise ValueError("CI job does not exist: " + name + "/" + job)
    events = data.get("on", data.get(True, {}))
    if isinstance(events, str):
        events = [events]
    if not isinstance(events, (dict, list)) or not any(event in events for event in ("push", "pull_request")):
        raise ValueError("CI workflow must run on push or pull_request: " + name)
    if str(data["jobs"][job].get("if", "")).strip().lower() in ("false", "${{ false }}"):
        raise ValueError("CI job is disabled: " + name + "/" + job)
    return {"workflow": name, "job": job}


def unavailable(check):
    if check.status == "blocked":
        return check.reason or "Required environment is unavailable locally"
    if check.status:
        return ""
    if check.name in ("swift-lint", "swift-analysis", "editor-analysis") and not shutil.which("swiftlint"):
        return "SwiftLint is unavailable on the local PATH"
    if check.argv and not shutil.which(check.argv[0]):
        return "Required executable is unavailable on the local PATH: " + check.argv[0]
    return ""


def publication_checks(root, checks, config):
    rules = config.get("pre_push", {}).get("ci_checks", {})
    selected = []
    for check in checks:
        reason = unavailable(check)
        rule = rules.get(check.name)
        if not reason or not rule:
            selected.append(check)
            continue
        if not rule.get("reason", "").strip() or not rule.get("targets"):
            raise ValueError("CI delegation requires a reason and target jobs: " + check.name)
        targets = [validate_target(root, target) for target in rule["targets"]]
        description = ", ".join(target["workflow"] + "/" + target["job"] for target in targets)
        selected.append(replace(check, status="deferred", ci_targets=targets,
                                reason=reason + "; mandatory CI: " + description))
    return selected
