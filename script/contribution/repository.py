"""Read Git state without changing the index or the worktree."""

import hashlib
import json
import os
from pathlib import Path
import subprocess


def git(root, *args):
    result = subprocess.run(
        ["git", "-C", str(root), *args], capture_output=True, timeout=60, check=True
    )
    return result.stdout.decode("utf-8", errors="surrogateescape")


def safe_path(root, name):
    root = Path(root).resolve()
    relative = Path(name)
    if relative.is_absolute() or ".." in relative.parts or not relative.parts or relative.parts[0] == ".git":
        raise ValueError("Expected a repository-relative path: " + str(name))
    path = root / relative
    if not path.resolve().is_relative_to(root):
        raise ValueError("Path leaves the repository: " + str(name))
    return path


def changed_files(root, base="HEAD", staged=False):
    args = ["diff", "--no-renames", "--name-only", "-z", "--diff-filter=ACDMRTUXB"]
    args += ["--cached"] if staged else [base]
    paths = set(git(root, *args).split("\0")) - {""}
    if not staged:
        paths.update(filter(None, git(root, "ls-files", "--others", "--exclude-standard", "-z").split("\0")))
    return sorted(paths)


def staged_files(root):
    paths = changed_files(root, staged=True)
    unstaged = set(filter(None, git(root, "diff", "--name-only", "-z").split("\0")))
    if unstaged.intersection(paths):
        raise ValueError("Partially staged files: stage the complete files or validate an index snapshot")
    # Other dirty code could change test behavior; never claim that a dirty worktree proves a commit.
    if unstaged:
        raise ValueError("Unstaged tracked changes: validate a clean staged worktree before committing")
    return paths


def snapshot(root):
    """Fingerprint index blobs plus dirty/new contents, including deletions and selected environment."""
    digest = hashlib.sha256()
    digest.update(git(root, "rev-parse", "HEAD").encode())
    digest.update(git(root, "ls-files", "--stage", "-z").encode("utf-8", errors="surrogateescape"))
    dirty = set(filter(None, git(root, "ls-files", "--modified", "--others", "--exclude-standard", "-z").split("\0")))
    for name in sorted(dirty):
        path = safe_path(root, name)
        digest.update(name.encode("utf-8", errors="surrogateescape"))
        digest.update(b"\0")
        if path.is_file():
            digest.update(hashlib.sha256(path.read_bytes()).digest())
        else:
            digest.update(b"<missing>")
    environment = {key: os.environ.get(key) for key in (
        "ADAENGINE_HEADLESS", "ADAENGINE_SKIP_WEBGPU_PLUGINS", "ADAENGINE_SKIP_SWIFTLINT",
        "ADAENGINE_GOLDEN_METAL", "ADAENGINE_GOLDEN_WEBGPU", "ADA_CLOUD_PANELS_DIST",
        "ADAENGINE_WEBGPU_TEST_FILTER", "ADAENGINE_WEBGPU_SCRATCH", "ADAENGINE_SWIFT_CONFIGURATION", "TINT_EXECUTABLE",
    )}
    digest.update(json.dumps(environment, sort_keys=True).encode())
    return digest.hexdigest()


def document_hash(root, name):
    return hashlib.sha256(safe_path(root, name).read_bytes()).hexdigest()
