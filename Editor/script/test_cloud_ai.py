#!/usr/bin/env python3
"""Exercise Studio's public AI client against disposable local AIService + Billing.

Build the service's AIService/Billing executables and the Editor test bundle first.
No production accounts, provider keys, purchases, or app QA hooks are used.
"""
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid

EDITOR = Path(__file__).resolve().parents[1]
SERVICE = Path(os.getenv("ADA_AI_SERVICE_ROOT", str(EDITOR.parent.parent / "adaengine-service")))
BUILD = Path(os.getenv("AI_TEST_BUILD_PATH", "/tmp/ada-ai-cloud-build"))
PG = Path(os.getenv("PG_BIN", "/opt/homebrew/opt/postgresql@17/bin"))
REDIS = Path(os.getenv("REDIS_BIN", "/opt/homebrew/opt/redis/bin"))


def port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def call(base, path, token, body=None):
    headers = {"Content-Type": "application/json", "Authorization": "Bearer " + token}
    request = urllib.request.Request(base + path, data=json.dumps(body).encode() if body is not None else None, headers=headers)
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.loads(response.read())


def ready(base, process):
    for _ in range(120):
        if process.poll() is not None:
            raise RuntimeError("Local service exited before readiness")
        try:
            with urllib.request.urlopen(base + "/health/ready", timeout=1):
                return
        except (urllib.error.URLError, TimeoutError):
            time.sleep(0.1)
    raise RuntimeError("Local service readiness timed out")


def jwt(owner, sid, secret):
    def encode(value):
        return base64.urlsafe_b64encode(json.dumps(value, separators=(",", ":")).encode()).decode().rstrip("=")
    payload = encode({"alg": "HS256", "typ": "JWT"}) + "." + encode({
        "sub": owner, "sid": sid, "exp": time.time() + 3600, "iss": "adaengine-cloud", "aud": "adaengine-api",
    })
    signature = base64.urlsafe_b64encode(hmac.new(secret.encode(), payload.encode(), hashlib.sha256).digest()).decode().rstrip("=")
    return payload + "." + signature


def main():
    processes = []
    logs = []
    with tempfile.TemporaryDirectory(prefix="ada-studio-ai-") as directory:
        work = Path(directory)
        pg_port, redis_port, ai_port, billing_port = [port() for _ in range(4)]

        def launch(name, argv, env=None):
            log = (work / (name + ".log")).open("w")
            logs.append(log)
            process = subprocess.Popen(argv, cwd=SERVICE, env=env, stdout=log, stderr=subprocess.STDOUT)
            processes.append(process)
            return process

        try:
            subprocess.run([str(PG / "initdb"), "-D", str(work / "postgres"), "-A", "trust", "--no-locale"], check=True, stdout=subprocess.DEVNULL)
            launch("postgres", [str(PG / "postgres"), "-D", str(work / "postgres"), "-h", "127.0.0.1", "-p", str(pg_port), "-k", str(work)])
            for _ in range(100):
                if subprocess.run([str(PG / "pg_isready"), "-h", "127.0.0.1", "-p", str(pg_port)], stdout=subprocess.DEVNULL).returncode == 0:
                    break
                time.sleep(0.1)
            sql = [str(PG / "psql"), "-h", "127.0.0.1", "-p", str(pg_port), "-d", "postgres", "-Atc"]
            user = subprocess.check_output(sql + ["SELECT current_user"], text=True).strip()
            for database in ["studio_ai", "studio_billing"]:
                subprocess.run(sql + ["CREATE DATABASE " + database], check=True, stdout=subprocess.DEVNULL)
            access, internal, worker, projection, redis_secret = [secrets.token_hex(32) for _ in range(5)]
            launch("redis", [str(REDIS / "redis-server"), "--bind", "127.0.0.1", "--port", str(redis_port), "--dir", str(work), "--save", "", "--appendonly", "no", "--requirepass", redis_secret])
            cli = [str(REDIS / "redis-cli"), "-h", "127.0.0.1", "-p", str(redis_port)]
            redis_env = dict(os.environ, REDISCLI_AUTH=redis_secret)
            for _ in range(60):
                if subprocess.run(cli + ["PING"], env=redis_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
                    break
                time.sleep(0.1)
            owner, sid = str(uuid.uuid4()), str(uuid.uuid4())
            subprocess.run(cli + ["SET", "session:" + sid, owner], env=redis_env, stdout=subprocess.DEVNULL, check=True)
            token = jwt(owner, sid, access)
            ai_base, billing_base = f"http://127.0.0.1:{ai_port}", f"http://127.0.0.1:{billing_port}"
            runtime = dict(os.environ, DEPLOYMENT_ENV="development", BIND_ADDRESS="127.0.0.1", ACCESS_TOKEN_SECRET=access, INTERNAL_SECRET=internal,
                           REDIS_URL=f"redis://:{redis_secret}@127.0.0.1:{redis_port}", KAFKA_BROKERS=f"127.0.0.1:{port()}",
                           BILLING_URL=billing_base, AI_URL=ai_base, AI_ENABLED="true", AI_CAPABILITIES="mesh",
                           AI_ALLOWED_COUNTRIES="RU", CLOUD_ROLLOUT_MODE="regional", CLOUD_DEV_COUNTRY="RU",
                           BILLING_SANDBOX="true", AI_WORKER_SECRET=worker, AI_BILLING_SECRET=projection, APPLE_AI_PRODUCT_PLANS="{}")
            billing = launch("billing", [str(BUILD / "debug/Billing")], dict(runtime, PORT=str(billing_port), DATABASE_URL=f"postgres://{user}@127.0.0.1:{pg_port}/studio_billing?sslmode=disable"))
            ai = launch("ai", [str(BUILD / "debug/AIService")], dict(runtime, PORT=str(ai_port), DATABASE_URL=f"postgres://{user}@127.0.0.1:{pg_port}/studio_ai?sslmode=disable"))
            ready(billing_base, billing)
            ready(ai_base, ai)
            now = time.time()
            call(billing_base, "/internal/billing/sandbox", internal, {
                "accountId": owner, "transactionId": "studio-test", "signedAt": now, "periodStart": now - 10,
                "expiresAt": now + 86400, "amountMinor": 100, "currency": "RUB", "revoked": False, "aiPlan": "pro",
            })
            session_file = work / "session.json"
            session_file.write_text(json.dumps({"server": ai_base, "accountID": owner, "accessToken": token}))
            session_file.chmod(0o600)
            env = dict(os.environ, ADA_EDITOR_AI_TEST_SESSION=str(session_file))
            scratch = os.getenv("ADA_EDITOR_AI_TEST_BUILD_PATH", "/tmp/adaeditor-ai-credits-build")
            subprocess.run(["swift", "test", "--package-path", str(EDITOR), "--scratch-path", scratch, "--skip-build", "--filter", "EditorCloudAILiveTests"], env=env, check=True)
        finally:
            for process in reversed(processes):
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=8)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
            for log in logs:
                log.close()


if __name__ == "__main__":
    main()
