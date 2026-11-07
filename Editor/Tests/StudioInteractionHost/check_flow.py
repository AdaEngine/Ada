"""Run the workbench flow through both CLI and AdaMCP stdio."""
import json
import select
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def send(process, message):
    data = json.dumps({"jsonrpc": "2.0", **message}).encode()
    process.stdin.write(f"Content-Length: {len(data)}\r\n\r\n".encode() + data)
    process.stdin.flush()


def receive(process, request_id, timeout=45):
    deadline = time.monotonic() + timeout
    pending = bytearray()
    while time.monotonic() < deadline:
        ready, _, _ = select.select([process.stdout], [], [], deadline - time.monotonic())
        if not ready:
            break
        chunk = process.stdout.read(8192)
        if not chunk:
            raise RuntimeError("AdaMCP closed its output before returning a response.")
        pending.extend(chunk)
        while b"\r\n\r\n" in pending:
            header, body = pending.split(b"\r\n\r\n", 1)
            length = int(header.removeprefix(b"Content-Length: "))
            if len(body) < length:
                break
            response = json.loads(body[:length])
            pending = body[length:]
            if response.get("id") == request_id:
                if "error" in response:
                    raise RuntimeError(response["error"])
                return response["result"]
    raise TimeoutError(f"Missing AdaMCP response for request {request_id}.")


def run_mcp(executable, source):
    with subprocess.Popen(
        [executable, "--stdio"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0
    ) as process:
        try:
            send(process, {
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-03-26",
                    "capabilities": {},
                    "clientInfo": {"name": "studio-flow-check", "version": "1"},
                },
            })
            receive(process, 1)
            send(process, {"method": "notifications/initialized"})
            send(process, {
                "id": 2,
                "method": "tools/call",
                "params": {"name": "editor.ui.run_flow", "arguments": {"source": source}},
            })
            result = receive(process, 2)
            process.stdin.close()
            if process.wait(timeout=5) != 0:
                raise RuntimeError("AdaMCP host failed while shutting down after input closed.")
            return json.loads(result["content"][0]["text"])
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()


def main():
    executable = sys.argv[1]
    flow = Path(__file__).parent / "Fixtures" / "workbench.yaml"
    cli = subprocess.run([executable, str(flow)], capture_output=True, text=True, timeout=60, check=False)
    if cli.returncode:
        raise RuntimeError(f"CLI failed ({cli.returncode}):\n{cli.stdout}\n{cli.stderr}")
    cli_report = json.loads(cli.stdout)
    mcp_report = run_mcp(executable, flow.read_text(encoding="utf-8"))
    for report in (cli_report, mcp_report):
        if report["status"] != "passed" or report["completedSteps"] != 14:
            raise AssertionError(f"Workbench flow failed: {report}")
    with tempfile.TemporaryDirectory(prefix="ada-flow-check-") as directory:
        negative = Path(directory) / "wrong-transform.yaml"
        negative.write_text(
            flow.read_text(encoding="utf-8").replace("[0.4, 0, 0]", "[100, 0, 0]"),
            encoding="utf-8",
        )
        failed = subprocess.run(
            [executable, str(negative)], capture_output=True, text=True, timeout=60, check=False
        )
        report = json.loads(failed.stdout)
        if failed.returncode != 1 or report["failedStep"] != 4 or report["command"] != "assertScene":
            raise AssertionError(f"Wrong transform did not fail step four: {report}")
    print("Passed the same 14-step flow through CLI and AdaMCP. Wrong transform failed step four.")


if __name__ == "__main__":
    main()
