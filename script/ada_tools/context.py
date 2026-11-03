"""Shared process, download and host configuration helpers (standard library only)."""
from collections import deque
import hashlib
import json
import ntpath
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tarfile
import urllib.request
import urllib.parse
import zipfile

ROOT = Path(__file__).resolve().parents[2]
PIN = json.loads((ROOT / "Tools/ada-toolchain.json").read_text(encoding="utf-8"))


class ToolError(RuntimeError):
    """An actionable CLI error, displayed without a Python traceback."""


class Context:
    def __init__(self, args, *, root=ROOT, host=None):
        self.root = Path(root).resolve()
        self.host = host or {"Windows": "windows", "Darwin": "macos", "Linux": "linux"}.get(platform.system())
        if self.host is None:
            raise ToolError("Supported hosts: Windows, macOS and Linux")
        self.arch = {"amd64": "x86_64", "aarch64": "arm64"}.get(platform.machine().lower(), platform.machine().lower())
        self.dry = getattr(args, "dry_run", False)
        self.jobs = getattr(args, "jobs", 2)
        self.cache = self.root / ".build-tools/ada-tool" / (self.host + "-" + self.arch)
        self.env = dict(os.environ)
        self.managed = {}
        self.bins = []
        state = self.cache / "environment.json"
        if state.is_file():
            saved = json.loads(state.read_text(encoding="utf-8"))
            for key, value in saved.get("environment", {}).items():
                self.env.setdefault(key, value)
            for directory in reversed(saved.get("bins", [])):
                if Path(directory).is_dir():
                    self.prepend(directory)
            self.managed.update(saved.get("environment", {}))
        self.swift = getattr(args, "swift", None) or self.env.get("ADA_TOOL_SWIFT", "swift")
        if self.swift != "swift":
            executable = self.which(self.swift)
            if executable:
                # Include swiftc and plugin subprocesses from the selected toolchain.
                self.prepend(Path(executable).parent)

    def which(self, name):
        return shutil.which(str(name), path=self.env.get("PATH", ""))

    def prepend(self, directory, *, persist=True):
        directory = str(directory)
        normalize = ntpath.normcase if self.host == "windows" else lambda value: value
        def key(value):
            return normalize(value.rstrip("\\/"))
        unique, seen = [], set()
        for value in [directory, *self.env.get("PATH", "").split(os.pathsep)]:
            if value and key(value) not in seen:
                unique.append(value)
                seen.add(key(value))
        self.env["PATH"] = os.pathsep.join(unique)
        if persist:
            self.bins = [directory, *[value for value in self.bins if key(value) != key(directory)]]

    def set(self, name, value):
        self.env[name] = str(value)
        self.managed[name] = str(value)

    def save(self):
        if not self.dry:
            self.cache.mkdir(parents=True, exist_ok=True)
            pending = self.cache / "environment.pending"
            pending.write_text(json.dumps({"environment": self.managed, "bins": self.bins}, indent=2) + "\n", encoding="utf-8")
            pending.replace(self.cache / "environment.json")

    def run(self, command, *, cwd=None, capture=False, log=None):
        command = [str(value) for value in command]
        print("+ " + (subprocess.list2cmdline(command) if self.host == "windows" else shlex.join(command)), file=sys.stderr, flush=True)
        if self.dry:
            return ""
        command[0] = self.which(command[0]) or command[0]
        invocation = command
        if os.name == "nt" and Path(command[0]).name.lower() == "cmd.exe":
            # cmd parses its own /c payload; CRT backslash-quote escaping corrupts
            # quoted vcvars paths. The payload comes only from our VS locator.
            invocation = subprocess.list2cmdline(command[:-1]) + " " + command[-1]
        options = dict(cwd=str(cwd or self.root), env=self.env, text=True, encoding="utf-8", errors="replace")
        if log:
            log = Path(log)
            log.parent.mkdir(parents=True, exist_ok=True)
            print("Compiler log: " + str(log), file=sys.stderr, flush=True)
            tail = deque(maxlen=30)
            with log.open("w", encoding="utf-8") as stream:
                with subprocess.Popen(invocation, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=1, **options) as process:
                    try:
                        for line in process.stdout:
                            stream.write(line)
                            tail.append(line)
                            if re.match(r"^(?:\[\d+/\d+\]|Building for|Build complete!|error:)", line):
                                stream.flush()
                                print(line, end="", file=sys.stderr, flush=True)
                        result = subprocess.CompletedProcess(invocation, process.wait(), stdout="")
                    except BaseException:
                        process.kill()
                        process.wait()
                        raise
            print("".join(tail), file=sys.stderr)
        else:
            result = subprocess.run(invocation, stdout=subprocess.PIPE if capture else sys.stderr, **options)
        if result.returncode:
            raise ToolError(f"Command failed ({result.returncode}): {command[0]}" + (f"; see {log}" if log else ""))
        return result.stdout.strip() if capture else ""

    def helper(self, name, *arguments, fallback=None):
        output = self.run([sys.executable, self.root / "script" / name, *arguments], capture=True)
        return output.splitlines()[-1] if output else str(fallback or self.cache / Path(name).stem)

    def powershell(self, script, *arguments):
        return self.run([self.which("pwsh") or "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script, *arguments])

    def run_elevated(self, command):
        """Use Windows' normal UAC prompt for a machine-wide prerequisite update."""
        if self.host != "windows" or self.dry:
            return self.run(command)
        import ctypes
        if ctypes.windll.shell32.IsUserAnAdmin():
            return self.run(command)
        self.env["ADA_TOOL_ADMIN_EXECUTABLE"] = str(command[0])
        self.env["ADA_TOOL_ADMIN_ARGUMENTS"] = subprocess.list2cmdline([str(value) for value in command[1:]])
        print("Windows administrator approval is required to update Visual Studio Build Tools (UAC).", file=sys.stderr, flush=True)
        return self.run([self.which("pwsh") or "powershell.exe", "-NoProfile", "-Command",
                         "$ErrorActionPreference='Stop'; $p=Start-Process -FilePath $env:ADA_TOOL_ADMIN_EXECUTABLE "
                         "-ArgumentList $env:ADA_TOOL_ADMIN_ARGUMENTS -Verb RunAs -WindowStyle Hidden -Wait -PassThru; "
                         "if ($p.ExitCode -eq 3010) { Write-Warning 'Restart Windows to finish updating Visual Studio, then rerun prepare.' }; exit $p.ExitCode"])

    def probe(self, command):
        """Bounded read-only subprocess used by doctor, including in dry-run mode."""
        try:
            command = [str(v) for v in command]
            command[0] = self.which(command[0]) or command[0]
            result = subprocess.run(command, env=self.env, cwd=self.root,
                                    capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=30)
            return result.returncode == 0, (result.stdout + result.stderr).strip()
        except (OSError, subprocess.TimeoutExpired) as error:
            return False, str(error)


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


class DownloadRedirects(urllib.request.HTTPRedirectHandler):
    """Remote downloads may redirect only to another HTTP(S) endpoint."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urllib.parse.urlsplit(newurl).scheme not in ("https", "http"):
            raise ToolError("Unsupported download redirect scheme")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def download(ctx, url, filename, checksum=None):
    if urllib.parse.urlsplit(url).scheme not in ("https", "http", "file"):
        raise ToolError("Unsupported download URL scheme")
    destination = ctx.cache / "downloads" / filename
    print("Download: " + url, file=sys.stderr)
    if ctx.dry:
        return destination
    if destination.is_file() and checksum and sha256(destination) == checksum:
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    pending = destination.with_suffix(destination.suffix + ".partial")
    try:
        opener = urllib.request.build_opener(DownloadRedirects())
        with opener.open(url, timeout=120) as response, pending.open("wb") as stream:
            shutil.copyfileobj(response, stream, 1024 * 1024)
        if checksum and sha256(pending) != checksum:
            raise ToolError("SHA-256 mismatch for " + filename)
        pending.replace(destination)
    finally:
        if pending.exists():
            pending.unlink()
    return destination


def extract_zip(archive, directory):
    """Extract regular files only; reject traversal, links and special files."""
    directory = Path(directory).resolve()
    with zipfile.ZipFile(archive) as bundle:
        for entry in bundle.infolist():
            target = directory / entry.filename
            mode = entry.external_attr >> 16
            if ("\\" in entry.filename or ".." in Path(entry.filename).parts or ":" in entry.filename
                    or not target.resolve().is_relative_to(directory)
                    or stat.S_ISLNK(mode) or (stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR))):
                raise ToolError("Unsafe archive entry: " + entry.filename)
            if entry.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with bundle.open(entry) as source, target.open("wb") as stream:
                    shutil.copyfileobj(source, stream)
                if mode & 0o777:
                    target.chmod(mode & 0o777)


def extract_tar(archive, directory):
    """Portable safe extraction for the official Swiftly/Node archives."""
    directory = Path(directory).resolve()
    with tarfile.open(archive) as bundle:
        for entry in bundle.getmembers():
            target = directory / entry.name
            if not target.resolve().is_relative_to(directory):
                raise ToolError("Unsafe archive entry: " + entry.name)
            if entry.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif entry.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                with bundle.extractfile(entry) as source, target.open("wb") as stream:
                    shutil.copyfileobj(source, stream)
                target.chmod(entry.mode & 0o777)
            elif entry.issym():
                if not (target.parent / entry.linkname).resolve().is_relative_to(directory):
                    raise ToolError("Unsafe archive link: " + entry.name)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.symlink_to(entry.linkname)
            else:
                raise ToolError("Unsupported archive entry: " + entry.name)
