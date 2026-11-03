"""User-facing documentation requirements; content accuracy remains an independent review responsibility."""

import fnmatch
import hashlib
import json
from pathlib import Path
import re

from .repository import git, safe_path


def is_article(root, name):
    config = json.loads((Path(root) / ".agents/validation.json").read_text(encoding="utf-8"))
    return (name.endswith(".md") and
            any(fnmatch.fnmatchcase(name, pattern) for pattern in config["user_documentation_roots"]) and
            not any(fnmatch.fnmatchcase(name, pattern) for pattern in config["internal_documentation_roots"]))


def baseline(root):
    paths = set(filter(None, git(root, "ls-files", "--cached", "--others", "--exclude-standard", "-z").split("\0")))
    return {name: hashlib.sha256(safe_path(root, name).read_bytes()).hexdigest()
            for name in paths if name.endswith(".md") and is_article(root, name) and safe_path(root, name).is_file()}


def declaration(root, state, articles, navigation, reason):
    articles = sorted({Path(p.replace("\\", "/")).as_posix() for p in articles})
    navigation = sorted({Path(p.replace("\\", "/")).as_posix() for p in navigation})
    if reason:
        if state["kind"] == "feature":
            raise ValueError("Every feature requires a user-facing article; it cannot be exempted")
        if articles or navigation or not reason.strip():
            raise ValueError("An internal-only reason cannot accompany article paths")
    elif not articles or not navigation:
        raise ValueError("Declare user documentation article and navigation source paths")
    for name in [*articles, *navigation]:
        safe_path(root, name)
    if any(not is_article(root, name) for name in articles):
        raise ValueError("Declare authored user-facing articles; designs, ADRs and generated docs do not qualify")
    if any(name not in ("README.md", "CONTRIBUTING.md") and not is_article(root, name) for name in navigation):
        raise ValueError("Article navigation must be user-facing, not agent/internal documentation")
    if set(articles) & set(navigation):
        raise ValueError("Article and navigation source must be distinct")
    if "documentation_baseline" not in state:
        state["documentation_baseline"] = baseline(root)
    state["user_documentation"] = {"articles": articles, "navigation": navigation, "internal_only_reason": reason}
    state["paths"] = sorted(set(state["paths"]) | set(articles) | set(navigation))


def is_linked(root, article, navigation):
    text = safe_path(root, navigation).read_text(encoding="utf-8")
    target = safe_path(root, article).resolve()
    for link in re.findall(r"\[[^\]\n]+\]\(([^)\n]+)\)", text):
        name = link.strip().strip("<>").split("#", 1)[0]
        if name and (safe_path(root, navigation).parent / name).resolve() == target:
            return True
    article_catalog = next((p for p in target.parents if p.suffix == ".docc"), None)
    nav_catalog = next((p for p in safe_path(root, navigation).resolve().parents if p.suffix == ".docc"), None)
    for link in re.findall(r"<doc:([^>]+)>", text):
        parts = link.split("#", 1)[0].split("/")
        if parts[-1] == target.stem and article_catalog and (
                article_catalog == nav_catalog or article_catalog.stem in parts[:-1]):
            return True
    return False


def require_documentation(root, state, stage):
    if stage not in ("plan", "code", "review", "done"):
        return
    docs = state.get("user_documentation")
    if state["kind"] in ("feature", "improvement") and not docs:
        raise ValueError("Declare the user documentation plan or an internal-only improvement reason")
    if state["kind"] == "feature" and docs and docs.get("internal_only_reason"):
        raise ValueError("Every feature requires user documentation")
    if not docs or docs.get("internal_only_reason"):
        return
    if stage not in ("review", "done"):
        return
    for article in docs["articles"]:
        if not is_article(root, article):
            raise ValueError("Required article is not a user-facing documentation source: " + article)
        path = safe_path(root, article)
        if not path.is_file() or not path.read_text(encoding="utf-8").strip():
            raise ValueError("Required user article is missing or empty: " + article)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest == state.get("documentation_baseline", {}).get(article):
            raise ValueError("User article must be updated for this task: " + article)
        if not any(safe_path(root, nav).is_file() and is_linked(root, article, nav) for nav in docs["navigation"]):
            raise ValueError("User article is absent from the declared navigation: " + article)
