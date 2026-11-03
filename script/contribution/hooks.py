"""Install opt-in Git hooks and compose them with existing hooks, including Git LFS."""

import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

from .repository import git

MARKER = "# adaengine-contribution-hook-v1"


def hooks_directory(root):
    directory = Path(git(root, "rev-parse", "--git-path", "hooks").strip())
    return directory if directory.is_absolute() else Path(root) / directory


def install(root):
    directory = hooks_directory(root)
    common = Path(git(root, "rev-parse", "--git-common-dir").strip())
    common = common.resolve() if common.is_absolute() else (Path(root) / common).resolve()
    if not directory.resolve().is_relative_to(Path(root).resolve()) and not directory.resolve().is_relative_to(common):
        raise ValueError("External/shared custom hooks require explicit manual integration; no files were changed")
    directory.mkdir(parents=True, exist_ok=True)
    # Preflight all hooks before changing any of them.
    for name in ("pre-commit", "pre-push"):
        path = directory / name
        backup = directory / (name + ".ada-original")
        if path.is_symlink() or backup.is_symlink():
            raise ValueError("Cannot install over symlinked hooks: " + name)
        if path.exists() and MARKER not in path.read_text(encoding="utf-8", errors="replace") and backup.exists():
            raise ValueError("Existing hook backup conflict: " + str(backup))
    for name in ("pre-commit", "pre-push"):
        path = directory / name
        if path.exists() and MARKER not in path.read_text(encoding="utf-8", errors="replace"):
            path.rename(directory / (name + ".ada-original"))
        command = shlex.quote(Path(sys.executable).as_posix())
        with path.open("w", encoding="utf-8", newline="\n") as output:
            output.write('#!/bin/sh\n' + MARKER + '\n'
                         'repository=$(git rev-parse --show-toplevel) || exit 2\n'
                         'exec ' + command + ' "$repository/script/check_contribution.py" --root "$repository" hook '
                         + name + ' "$@"\n')
        path.chmod(path.stat().st_mode | 0o111)
    return directory


def original(root, event, arguments, stdin):
    path = hooks_directory(root) / (event + ".ada-original")
    if not path.exists():
        return 0
    if os.name == "nt":
        git_executable = shutil.which("git")
        git_bash = Path(git_executable).resolve().parents[1] / "bin/bash.exe" if git_executable else Path("")
        bash = str(git_bash) if git_bash.is_file() else shutil.which("bash")
        if not bash:
            raise ValueError("Git Bash is required to preserve the original Windows hook")
        command = [bash, path.as_posix(), *arguments]
    else:
        command = [str(path), *arguments]
    return subprocess.run(command, input=stdin, cwd=root, check=False).returncode
