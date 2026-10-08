#!/usr/bin/env python3
"""Serve a Web Player bundle and broker short-lived Cloud relay room tickets.

The editor creates the Host room with its signed-in Cloud account. It passes the
one-use Host ticket through this process's environment, never through a file or
the game's URL. Guest joins are forwarded without Cloud account credentials.
"""

import argparse
import json
import os
import re
import threading
import urllib.error
import urllib.parse
import urllib.request
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class PlayerServer(ThreadingHTTPServer):
    def __init__(self, address, directory, api_origin, host_session):
        self.directory = directory
        self.api_origin = api_origin.rstrip("/")
        self.host_session = host_session
        self.session_lock = threading.Lock()
        super().__init__(address, PlayerHandler)


class PlayerHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=args[2].directory, **kwargs)

    def log_message(self, format, *args):
        # Room tickets and join codes must not appear in access logs.
        if self.path.startswith("/ada-multiplayer/"):
            return
        super().log_message(format, *args)

    def do_POST(self):
        if self.path not in ("/ada-multiplayer/sessions", "/ada-multiplayer/join"):
            self.send_error(404)
            return
        expected_origin = f"http://127.0.0.1:{self.server.server_port}"
        origin = self.headers.get("Origin")
        if origin is not None and origin != expected_origin:
            self.respond(403, {"error": "Invalid browser origin."})
            return
        if self.path == "/ada-multiplayer/sessions":
            if self.client_address[0] not in ("127.0.0.1", "::1"):
                self.respond(403, {"error": "Host room is available only on this computer."})
                return
            with self.server.session_lock:
                session = self.server.host_session
                self.server.host_session = None
            if session is None:
                self.respond(503, {"error": "Create a room from the signed-in AdaEditor first."})
            else:
                self.respond(200, session)
            return

        try:
            size = int(self.headers.get("Content-Length", "0"))
            if size < 1 or size > 1024:
                raise ValueError("Invalid join request.")
            body = json.loads(self.rfile.read(size))
            code = body.get("joinCode") if isinstance(body, dict) else None
            if not isinstance(code, str) or not re.fullmatch(r"[A-Z0-9]{8}", code):
                raise ValueError("Enter an eight-character room code.")
            request = urllib.request.Request(
                self.server.api_origin + "/v1/multiplayer/join",
                data=json.dumps({"joinCode": code}).encode(),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(request, timeout=15) as response:
                result = json.load(response)
            self.respond(200, result)
        except ValueError as error:
            self.respond(400, {"error": str(error)})
        except urllib.error.HTTPError as error:
            self.respond(error.code, {"error": "Unable to join this room."})
        except (OSError, json.JSONDecodeError):
            self.respond(502, {"error": "Cloud multiplayer is unavailable."})

    def respond(self, status, value):
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", required=True)
    parser.add_argument("--api-origin", required=True)
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()
    origin = urllib.parse.urlsplit(args.api_origin)
    if origin.scheme != "https" and not (origin.scheme == "http" and origin.hostname in ("127.0.0.1", "localhost")):
        parser.error("Cloud API origin must use HTTPS")
    encoded_session = os.environ.pop("ADA_WEB_HOST_SESSION", "")
    session = json.loads(encoded_session) if encoded_session else None
    if session is not None and not all(session.get(key) for key in ("sessionID", "peerID", "relayURL", "connectionTicket", "joinCode")):
        parser.error("Incomplete Host room session")
    server = PlayerServer(("127.0.0.1", args.port), args.directory, args.api_origin, session)
    print(f"Serving {args.directory} at http://127.0.0.1:{args.port}", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
