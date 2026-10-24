#!/usr/bin/env python3
"""Read-only, socket-activated update progress. No Docker, database or API dependency."""
import hashlib
import hmac
import json
import os
import re
import socket
import socketserver
import stat
import time
from http.server import BaseHTTPRequestHandler

JOB = re.compile(r"upd_[0-9a-f]{32}")
TOKEN = re.compile(r"[0-9a-f]{64}")
STATE = "/run/myscoutee-update-reader"
PUBLIC_FIELDS = ("schemaVersion", "jobId", "phase", "percent", "updatedAt",
                 "requestedAt", "currentVersion", "targetVersion", "channel", "artifactSha256")


def read_json(root, *parts):
    """Refuse symlinks in every component, and bound regular-file reads."""
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        with os.fdopen(fd, "rb") as source:
            info = os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > 65536:
                raise ValueError("invalid status file")
            value = json.loads(source.read(65537))
            if not isinstance(value, dict):
                raise ValueError("invalid status document")
            return value
    finally:
        os.close(directory)


def status_for(root, job, token, now=None):
    if not JOB.fullmatch(job) or not TOKEN.fullmatch(token):
        raise PermissionError()
    grant = read_json(root, "inbox", "staging", job, "monitor.json")
    digest = hashlib.sha256(token.encode("ascii")).hexdigest()
    if (grant.get("jobId") != job or grant.get("expiresAt", 0) <= (time.time() if now is None else now)
            or not hmac.compare_digest(str(grant.get("tokenSha256", "")), digest)):
        raise PermissionError()
    try:
        status = read_json(root, "runtime", "jobs", job, "status.json")
    except FileNotFoundError:
        status = read_json(root, "inbox", "staging", job, "status.json")
    if status.get("jobId") != job:
        raise ValueError("job mismatch")
    result = {key: status.get(key) for key in PUBLIC_FIELDS}
    point = status.get("rollback")
    result["rollback"] = ({key: point.get(key) for key in
        ("jobId", "fromVersion", "targetVersion", "artifactSha256")} if isinstance(point, dict) else None)
    return result


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        self.request.settimeout(5)
        super().setup()

    def log_message(self, *_):
        # Never log credentials, paths supplied by clients or status payloads.
        pass

    def reply(self, code, data):
        body = json.dumps(data, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def do_GET(self):
        match = re.fullmatch(r"/operator-update-status/(upd_[0-9a-f]{32})", self.path)
        auth = self.headers.get("Authorization", "")
        if not match or not auth.startswith("UpdateMonitor "):
            return self.reply(404, {"error": "unavailable"})
        try:
            data = status_for(self.server.state_root, match[1], auth[len("UpdateMonitor "):])
        except (OSError, ValueError, TypeError):
            return self.reply(404, {"error": "unavailable"})
        self.reply(200, data)

    def do_POST(self):
        self.reply(405, {"error": "read-only"})

    do_PUT = do_DELETE = do_PATCH = do_POST


class Server(socketserver.UnixStreamServer):
    # Small sequential responses and a bounded socket timeout avoid unbounded threads.
    def __init__(self, listener, state_root=STATE):
        super().__init__("", Handler, bind_and_activate=False)
        self.socket.close()
        self.socket = listener
        self.server_address = listener.getsockname()
        self.state_root = state_root


if __name__ == "__main__":
    if int(os.environ.get("LISTEN_PID", "0")) != os.getpid() or os.environ.get("LISTEN_FDS") != "1":
        raise SystemExit("Exactly one systemd socket is required")
    with Server(socket.socket(fileno=3)) as server:
        server.serve_forever(poll_interval=0.5)
