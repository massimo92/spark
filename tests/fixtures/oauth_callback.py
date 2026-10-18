#!/usr/bin/env python3
# Based on spark by Massimo Angelini - https://github.com/massimo92/spark
"""Exercise Spark's callback wrapper without a provider account."""
import json
import os
import sys
import types

class Server:
    def server_close(self):
        pass

class Authenticator:
    def _start_callback_server(self, state):
        return Server(), "http://127.0.0.1:" + os.environ.get("FAKE_CALLBACK_PORT", "56121") + "/callback"

    def login(self, no_browser=False):
        assert no_browser
        self._start_callback_server("test-state")
        with open(os.path.join(os.environ["FAKE_AUTH_DIR"], "auth.json"), "w") as auth:
            json.dump({"access_token": "test-only"}, auth)

for name in ("litellm", "litellm.llms", "litellm.llms.xai", "litellm.llms.xai.oauth"):
    sys.modules[name] = types.ModuleType(name)
sys.modules["litellm.llms.xai.oauth"].XAIOAuthAuthenticator = Authenticator
exec(compile(sys.stdin.read(), "callback-wrapper", "exec"))
