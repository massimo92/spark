"""Exercise the decision HTTP contract without CUDA or model weights."""
import http.client
import importlib.util
import json
from pathlib import Path
import threading
from types import SimpleNamespace
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "bundles/vllm/clef-flash-nvfp4/serve_systemone.py"
SPEC = importlib.util.spec_from_file_location("spark_clef_server", SOURCE)
server_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(server_module)
MODEL = "alpha-x-ai/clef-flash-NVFP4"


class FakeEngine:
    def __init__(self):
        self.requests = []
        self.entered = threading.Event()
        self.release = threading.Event()
        self.block = False
        self.fail = False

    def systemone(self, request):
        self.requests.append(request)
        self.entered.set()
        if self.block:
            if not self.release.wait(5):
                raise RuntimeError("test engine timed out")
        if self.fail:
            raise RuntimeError("internal model state must not appear in the response")
        answers = {}
        for name, question in request["questions"].items():
            kind = question["type"]
            if kind == "noul":
                answers[name] = {"type": kind, "noul": 0.9}
            elif kind == "choice":
                option = next(iter(question["criteria"]))
                answers[name] = {"type": kind, "choice": option, "probabilities": {option: 1.0}}
            else:
                answers[name] = {"type": kind, "score": 1.0, "probabilities": {"0": 0.0, "1": 1.0}}
        return {"model": MODEL, "answers": answers, "usage": {"input_tokens": 20, "output_tokens": 0}}


class DecisionServerTests(unittest.TestCase):
    def setUp(self):
        self.engine = FakeEngine()
        self.server = server_module.make_server(("127.0.0.1", 0), self.engine, MODEL)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.close)

    def close(self):
        self.engine.release.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(5)

    def request(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection(*self.server.server_address, timeout=5)
        try:
            payload = None if body is None else json.dumps(body).encode()
            conn.request(method, path, payload, headers or {"Content-Type": "application/json"})
            reply = conn.getresponse()
            return reply.status, json.loads(reply.read())
        finally:
            conn.close()

    def body(self):
        return {"model": MODEL, "state": {"phase": "validation", "pending": []}, "questions": {
            "done": {"type": "noul", "instructions": "Is validation complete?"},
            "next": {"type": "choice", "criteria": {"continue": "pending checks", "finish": "all checks passed"}},
            "progress": {"type": "score", "criteria": ["blocked", "complete"]},
        }}

    def test_health_and_model_discovery(self):
        self.assertEqual(self.request("GET", "/health"), (200, {"status": "ready"}))
        status, body = self.request("GET", "/v1/models")
        self.assertEqual(status, 200)
        self.assertEqual(body["data"][0]["id"], MODEL)
        self.assertEqual(body["data"][0]["api"], "systemone")

    def test_all_primitives_preserve_structured_state(self):
        payload = self.body()
        status, response = self.request("POST", "/v1/systemone", payload)
        self.assertEqual(status, 200)
        self.assertEqual(self.engine.requests, [payload])
        self.assertEqual(set(response["answers"]), {"done", "next", "progress"})
        self.assertEqual(response["usage"]["output_tokens"], 0)

    def test_invalid_requests_never_reach_the_engine(self):
        invalid = [[], {**self.body(), "model": "different"}, {**self.body(), "state": None},
                   {**self.body(), "questions": {}}, {**self.body(), "questions": {
                       "q": {"type": "box", "instructions": "find it"}}},
                   {**self.body(), "questions": {"q": {"type": "choice", "criteria": []}}},
                   {**self.body(), "images": ["https://example.invalid/image.png"]},
                   {**self.body(), "videos": ["unsupported"]}, {**self.body(), "stream": True},
                   {**self.body(), "questions": {"q": {"type": [], "criteria": []}}}]
        for payload in invalid:
            with self.subTest(payload=payload):
                self.assertEqual(self.request("POST", "/v1/systemone", payload)[0], 400)
        self.assertEqual(self.engine.requests, [])

    def test_chat_endpoint_is_not_exposed(self):
        self.assertEqual(self.request("POST", "/v1/chat/completions", self.body())[0], 404)

    def test_size_limit_is_checked_before_reading_the_body(self):
        status, _ = self.request("POST", "/v1/systemone", headers={
            "Content-Length": str(server_module.MAX_BODY_BYTES + 1)})
        self.assertEqual(status, 413)
        self.assertEqual(self.engine.requests, [])

    def test_busy_engine_keeps_health_responsive(self):
        self.engine.block = True
        result = []
        worker = threading.Thread(target=lambda: result.append(self.request("POST", "/v1/systemone", self.body())))
        worker.start()
        try:
            self.assertTrue(self.engine.entered.wait(2))
            self.assertEqual(self.request("GET", "/health")[0], 200)
            self.assertEqual(self.request("POST", "/v1/systemone", self.body())[0], 429)
        finally:
            self.engine.release.set()
            worker.join(5)
        self.assertEqual(result[0][0], 200)
        self.assertEqual(len(self.engine.requests), 1)

    def test_engine_failure_is_sanitized_and_lock_released(self):
        self.engine.fail = True
        with self.assertLogs(level="ERROR"):
            status, response = self.request("POST", "/v1/systemone", self.body())
        self.assertEqual(status, 500)
        self.assertNotIn("internal model state", json.dumps(response))
        self.engine.fail = False
        self.assertEqual(self.request("POST", "/v1/systemone", self.body())[0], 200)

    def test_runtime_flags_match_spark_launch_contract(self):
        args = server_module.parser().parse_args([
            MODEL, "--revision", "e676d8e6e14f5ee74830d33fa1fad643d8f53acf",
            "--host", "127.0.0.1", "--port", "8007", "--gpu-memory-utilization", "0.12",
            "--kv-cache-dtype", "auto", "--max-model-len", "4096", "--max-num-seqs", "1",
            "--enforce-eager", "--kv-cache-memory-bytes", "1610612736",
        ])
        self.assertEqual(args.port, 8007)
        self.assertEqual(args.max_model_len, 4096)
        self.assertEqual(args.kv_cache_memory_bytes, 1610612736)

    def test_long_state_is_rejected_without_truncating_evidence(self):
        engine = SimpleNamespace(tokenizer=None, processor=None, max_model_len=8)
        def encoder(tokenizer, record, *, max_length, processor):
            return SimpleNamespace(input_ids=record["tokens"][:max_length])
        with self.assertRaisesRegex(ValueError, "request needs 9 tokens"):
            server_module.encode_complete_record(engine, {"tokens": list(range(9))}, encoder)
        result = server_module.encode_complete_record(engine, {"tokens": list(range(8))}, encoder)
        self.assertEqual(len(result.input_ids), 8)


if __name__ == "__main__":
    unittest.main()
