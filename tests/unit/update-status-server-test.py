#!/usr/bin/env python3
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
import unittest

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("status_server", Path(__file__).resolve().parents[2] / "runtime/update/update-status-server.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class StatusTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.job = "upd_" + "a" * 32
        self.token = "b" * 64
        self.stage = self.root / "inbox/staging" / self.job
        self.worker = self.root / "runtime/jobs" / self.job
        self.stage.mkdir(parents=True)
        self.worker.mkdir(parents=True)
        self.grant = {"jobId": self.job, "tokenSha256": hashlib.sha256(self.token.encode()).hexdigest(), "expiresAt": 4102444800}
        (self.stage / "monitor.json").write_text(json.dumps(self.grant))
        self.write_status(self.stage, "DOWNLOADING", 30)

    def write_status(self, folder, phase, percent):
        (folder / "status.json").write_text(json.dumps({"jobId": self.job, "phase": phase, "percent": percent,
            "schemaVersion": 1, "requestedBy": "private-actor", "message": "internal host path", "monitorToken": "must-not-leak"}))

    def test_live_host_updates_without_application_api(self):
        listener = socket.socket(socket.AF_UNIX)
        path = str(self.root / "status.sock")
        listener.bind(path)
        listener.listen(4)
        server = module.Server(listener, str(self.root))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        def request(token, method="GET"):
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(2)
                client.connect(path)
                client.sendall(f"{method} /operator-update-status/{self.job} HTTP/1.1\r\nHost: localhost\r\nAuthorization: UpdateMonitor {token}\r\nConnection: close\r\n\r\n".encode())
                chunks = []
                while chunk := client.recv(8192): chunks.append(chunk)
                return b"".join(chunks).decode()
        try:
            self.assertIn('"phase":"DOWNLOADING"', request(self.token))
            self.write_status(self.worker, "RESTARTING", 92)
            response = request(self.token)
            self.assertIn('"phase":"RESTARTING"', response)
            self.assertNotIn("private-actor", response)
            self.assertNotIn("must-not-leak", response)
            self.write_status(self.worker, "COMPLETED", 100)
            self.assertIn('"percent":100', request(self.token))
            self.assertIn("404", request("c" * 64))
            self.assertIn("405", request(self.token, "POST"))
        finally:
            server.shutdown(); server.server_close(); thread.join()

    def test_expiry_wrong_job_and_no_credentials(self):
        for job, token, now in [(self.job, self.token, 4102444800), ("upd_"+"c"*32, self.token, 0),
                                (self.job, "", 0), ("../"+self.job, self.token, 0)]:
            with self.assertRaises((OSError, ValueError)):
                module.status_for(str(self.root), job, token, now)

    def test_recovery_exposes_only_public_rollback_identity(self):
        self.write_status(self.worker, "RECOVERY_REQUIRED", 94)
        path = self.worker / "status.json"
        status = json.loads(path.read_text())
        rollback = {"jobId": self.job, "fromVersion": "1.0.0-qa.2",
                    "targetVersion": "1.0.0-qa.1", "artifactSha256": "c" * 64}
        status["rollback"] = {**rollback, "internalPath": "/private/package.deb",
                              "monitorToken": "must-not-leak"}
        path.write_text(json.dumps(status))
        result = module.status_for(str(self.root), self.job, self.token)
        self.assertEqual(result["rollback"], rollback)
        self.assertNotIn("must-not-leak", json.dumps(result))

    def test_symlink_and_oversized_status_rejected(self):
        status = self.worker / "status.json"
        status.symlink_to(self.stage / "status.json")
        with self.assertRaises(OSError): module.status_for(str(self.root), self.job, self.token)
        status.unlink()
        status.write_bytes(b" " * 65537)
        with self.assertRaises(ValueError): module.status_for(str(self.root), self.job, self.token)
        status.unlink(); self.worker.rmdir()
        self.worker.symlink_to(self.stage, target_is_directory=True)
        with self.assertRaises(OSError): module.status_for(str(self.root), self.job, self.token)


if __name__ == "__main__": unittest.main()
