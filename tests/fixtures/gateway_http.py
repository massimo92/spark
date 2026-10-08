#!/usr/bin/env python3
# Based on spark by Massimo Angelini - https://github.com/massimo92/spark
"""HTTP fixture for Spark's authorization transport; real LiteLLM has its own test."""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


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

    def authorized(self):
        with open(sys.argv[1]) as env:
            key = next(line.rstrip().split("=", 1)[1] for line in env if line.startswith("LITELLM_MASTER_KEY="))
        if self.headers.get("Authorization") == "Bearer " + key:
            return True
        self.reply({"error": "unauthorized"}, 401)
        return False

    def do_GET(self):
        if self.authorized():
            self.reply({"data": [{"id": "vllm/Test/Alpha"}]})

    def do_POST(self):
        if not self.authorized():
            return
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if request["model"] != "vllm/Test/Alpha":
            self.reply({"error": "unknown model"}, 404)
            return
        self.reply({"choices": [{"message": {"role": "assistant", "content": "OK"}}]})


server = ThreadingHTTPServer(("127.0.0.1", 0), Gateway)
with open(sys.argv[2], "w") as port_file:
    port_file.write(str(server.server_address[1]))
server.serve_forever()
