#!/usr/bin/env python3
# Based on spark by Massimo Angelini - https://github.com/massimo92/spark
"""Deterministic HTTP double of native LiteLLM key management; stores hashes only."""
import hashlib
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit, parse_qs

root = Path(sys.argv[1])
state_path = root / "database.json"
state_path.write_text(json.dumps({"keys": {}, "users": {}}))


class Gateway(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, body, code=200):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def auth(self, admin=False):
        if not (root / "running").exists():
            self.reply({"error": "stopped"}, 503)
            return False
        token = self.headers.get("Authorization", "").removeprefix("Bearer ")
        busy = root / "invalid-busy"
        if token == "sk-invalid" and busy.exists():
            busy.unlink()
            self.reply({"error": "database restarting"}, 500)
            return False
        if not token and (root / "accept-anonymous").exists():
            return True
        if token == (root / "admin").read_text().strip():
            return True
        if not admin and hashlib.sha256(token.encode()).hexdigest() in self.state["keys"]:
            return True
        self.reply({"error": "forbidden"}, 403)
        return False

    def do_GET(self):
        self.state = json.loads(state_path.read_text())
        url = urlsplit(self.path)
        if not self.auth(admin=not url.path.startswith("/v1/")):
            return
        if url.path == "/user/info":
            user = parse_qs(url.query)["user_id"][0]
            if user not in self.state["users"]:
                self.reply({"error": "not found"}, 404)
            else:
                self.reply({"user_info": self.state["users"][user]})
        elif url.path == "/key/list":
            self.reply({"keys": list(self.state["keys"])})
        else:
            self.reply({"data": [{"id": "vllm/Test/Alpha"}]})

    def do_POST(self):
        self.state = json.loads(state_path.read_text())
        if not self.auth(admin=not self.path.startswith("/v1/")):
            return
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/user/new":
            assert body["user_role"] == "internal_user" and not body["auto_create_key"]
            self.state["users"][body["user_id"]] = body
            response = body
        elif self.path == "/key/generate":
            assert body["allowed_routes"] == ["llm_api_routes"]
            key = body.pop("key")
            self.state["keys"][hashlib.sha256(key.encode()).hexdigest()] = body
            response = {"key": key}
        elif self.path == "/key/regenerate":
            self.reply({"error": "regeneration requires an Enterprise license"}, 403)
            return
        elif self.path == "/key/delete":
            for key in body["keys"]:
                self.state["keys"].pop(key, None)
            response = {"deleted_keys": body["keys"]}
        elif self.path.startswith("/v1/"):
            response = {"choices": [{"message": {"content": "OK"}}]}
        else:
            self.reply({"error": "not found"}, 404)
            return
        state_path.write_text(json.dumps(self.state))
        fail = root / "fail-after-commit"
        if fail.exists() and self.path == "/key/delete":
            fail.unlink()
            self.reply({"error": "ambiguous commit"}, 500)
        else:
            self.reply(response)


server = ThreadingHTTPServer(("127.0.0.1", 0), Gateway)
(root / "port").write_text(str(server.server_address[1]))
server.serve_forever()
