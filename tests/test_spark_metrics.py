"""Exercise the Spark metrics endpoint against real vLLM and spark status captures."""
import http.client
import http.server
import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests/fixtures/metrics"
SPEC = importlib.util.spec_from_file_location("spark_metrics", ROOT / "src/assets/spark-metrics.py")
metrics = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(metrics)

MTP = (FIXTURES / "vllm-metrics-demo-9b-mtp.txt").read_text()
PLAIN = (FIXTURES / "vllm-metrics-demo-9b.txt").read_text()
STATUS = json.loads((FIXTURES / "spark-status.json").read_text())
# Ports from the status capture: 8003 MTP, 8000 plain, 8002 broken, 8001 System One.
PAGES = {8003: MTP, 8004: MTP, 8000: PLAIN}


class FakeFetch:
    def __init__(self):
        self.ports = []
        self.lock = threading.Lock()

    def __call__(self, port, timeout):
        with self.lock:
            self.ports.append(port)
        assert timeout <= 2
        if port not in PAGES:
            raise ConnectionRefusedError("connection refused")
        return PAGES[port]


def meminfo_file(directory):
    path = Path(directory) / "meminfo"
    path.write_text(
        "MemTotal:       127535616 kB\nMemFree:         1000000 kB\n"
        "MemAvailable:    95551488 kB\nSwapTotal:       16777216 kB\nSwapFree:        15728640 kB\n"
    )
    return str(path)


class ParseTest(unittest.TestCase):
    def test_mtp_capture_yields_acceptance_kv_and_histograms(self):
        result = metrics.summarize(metrics.parse_prometheus(MTP))
        spec = result["spec_decode"]
        self.assertEqual(spec["num_drafts"], 188)
        self.assertEqual(spec["num_draft_tokens"], 376)
        self.assertEqual(spec["num_accepted_tokens"], 195)
        self.assertEqual(spec["accepted_tokens_per_pos"], [118, 77])
        self.assertEqual(spec["acceptance_rate"], round(195 / 376, 4))
        self.assertEqual(spec["mean_acceptance_length"], round(1 + 195 / 188, 4))
        self.assertEqual(result["kv_cache_usage_perc"], 0)
        self.assertEqual(result["num_requests_running"], 0)
        self.assertEqual(result["num_requests_waiting"], 0)
        self.assertEqual(result["cache_config"], {"block_size": 16, "num_gpu_blocks": 72, "cache_dtype": "auto"})
        self.assertEqual(result["prompt_tokens_total"], 48)
        self.assertEqual(result["generation_tokens_total"], 385)
        self.assertEqual(result["prefix_cache_hits_total"], 0)
        self.assertEqual(result["prefix_cache_queries_total"], 48)
        ttft = result["histograms"]["time_to_first_token_seconds"]
        self.assertEqual(ttft["count"], 4)
        self.assertAlmostEqual(ttft["sum"], 1.7208631038665771)
        self.assertEqual(ttft["buckets"][0], {"le": 0.001, "count": 0})
        self.assertEqual(ttft["buckets"][-1], {"le": "+Inf", "count": 4})
        itl = result["histograms"]["inter_token_latency_seconds"]
        self.assertEqual(itl["count"], 188)
        for name in ("request_prefill_time_seconds", "request_decode_time_seconds"):
            self.assertEqual(result["histograms"][name]["count"], 4)
        json.dumps(result, allow_nan=False)

    def test_plain_capture_has_no_spec_decode(self):
        result = metrics.summarize(metrics.parse_prometheus(PLAIN))
        self.assertIsNone(result["spec_decode"])
        self.assertEqual(result["cache_config"]["num_gpu_blocks"], 201)

    def test_label_escapes_and_non_finite_values(self):
        samples = metrics.parse_prometheus('m{a="x\\"y,z",b="1"} +Inf\nbroken line\n')
        self.assertEqual(samples["m"][0][0], {"a": 'x"y,z', "b": "1"})
        self.assertIsNone(metrics._number(samples["m"][0][1]))

    def test_meminfo(self):
        with tempfile.TemporaryDirectory() as directory:
            host = metrics.read_meminfo(meminfo_file(directory))
        self.assertEqual(host, {"mem_total_gb": 121.63, "mem_used_gb": 30.5,
                                "mem_available_gb": 91.12, "swap_used_gb": 1.0})
        self.assertIsNone(metrics.read_meminfo("/nonexistent/meminfo")["mem_total_gb"])


class PayloadTest(unittest.TestCase):
    def test_merges_status_skips_systemone_and_isolates_failures(self):
        fetch = FakeFetch()
        with tempfile.TemporaryDirectory() as directory:
            payload = metrics.build_payload(STATUS, fetch, 2, meminfo_file(directory))
        by_name = {item["instance"]: item for item in payload["instances"]}
        self.assertEqual(sorted(by_name), ["demo-9b", "demo-9b-kv8", "demo-9b-mtp", "demo-9b-mtp-kv8", "mica-v0.5-4b"])
        mtp = by_name["demo-9b-mtp"]
        self.assertEqual(mtp["container"], "spark-vllm-demo-9b-mtp")
        self.assertEqual(mtp["gateway_model"], "vllm/demo-9b-mtp")
        self.assertEqual(mtp["engine_memory"]["kv_tokens"], 27433)
        self.assertEqual(mtp["metrics_port"], 8003)
        self.assertEqual(mtp["vllm"]["spec_decode"]["accepted_tokens_per_pos"], [118, 77])
        self.assertNotIn("error", mtp)
        broken = by_name["demo-9b-kv8"]
        self.assertIsNone(broken["vllm"])
        self.assertIn("connection refused", broken["error"])
        mica = by_name["mica-v0.5-4b"]
        self.assertEqual(mica["api"], "systemone")
        self.assertIsNone(mica["vllm"])
        self.assertIn("systemone", mica["metrics_skipped"])
        self.assertNotIn(8001, fetch.ports)
        self.assertEqual(payload["host"]["mem_total_gb"], 121.63)
        self.assertTrue(payload["generated_at"].endswith("Z"))
        # Only per-instance status fields leave the host: no gateway/provider data.
        self.assertNotIn("gateway", json.dumps(payload).replace("gateway_model", "").replace("gateway_routed", ""))

    def test_rejects_non_local_endpoints(self):
        status = {"models": [{"engine": "vllm", "api": "chat", "instance": "x", "endpoint": "http://10.0.0.1:8000/v1"}]}
        item = metrics.build_payload(status, FakeFetch(), 2, "/nonexistent")["instances"][0]
        self.assertIn("not a local HTTP port", item["error"])

    def test_non_vllm_response_is_an_error(self):
        status = {"models": [{"engine": "vllm", "api": "chat", "instance": "x", "endpoint": "http://localhost:9/v1"}]}
        item = metrics.build_payload(status, lambda port, timeout: "<html>other app</html>", 2, "/nonexistent")
        self.assertIn("no vLLM metrics", item["instances"][0]["error"])

    def test_run_status_accepts_non_zero_exit_with_json(self):
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "spark"
            script.write_text("#!/bin/sh\n[ \"$1 $2\" = 'status --json' ] || exit 9\ncat '%s'\nexit 1\n"
                              % (FIXTURES / "spark-status.json"))
            script.chmod(script.stat().st_mode | stat.S_IXUSR)
            self.assertEqual(len(metrics.run_status(str(script), 5)["models"]), 5)
            script.write_text("#!/bin/sh\necho not-json\n")
            with self.assertRaises(metrics.StatusError):
                metrics.run_status(str(script), 5)


class ServerTest(unittest.TestCase):
    def setUp(self):
        self.calls = 0
        self.tmp = tempfile.TemporaryDirectory()

        def status():
            self.calls += 1
            return STATUS

        self.server = metrics.MetricsServer(("127.0.0.1", 0), "/unused", meminfo=meminfo_file(self.tmp.name),
                                            status_source=status, fetch=FakeFetch())
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.tmp.cleanup()

    def get(self, path, method="GET"):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=5)
        connection.request(method, path)
        response = connection.getresponse()
        body = response.read()
        connection.close()
        return response.status, response.getheader("Content-Type"), body

    def test_binds_loopback(self):
        self.assertEqual(self.server.server_address[0], "127.0.0.1")
        with self.assertRaises(SystemExit):
            metrics.main(["--host", "0.0.0.0", "--port", "0", "--spark", "/bin/true"])

    def test_routes(self):
        code, kind, body = self.get("/spark/metrics")
        self.assertEqual((code, kind), (200, "application/json; charset=utf-8"))
        self.assertEqual(len(json.loads(body)["instances"]), 5)
        # Tailscale Serve may strip the /spark mount; both forms work.
        code, _, body = self.get("/metrics/demo-9b-mtp")
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(body)["instance"]["vllm"]["spec_decode"]["num_drafts"], 188)
        code, _, body = self.get("/spark/metrics/spark-vllm-demo-9b")
        self.assertEqual(json.loads(body)["instance"]["instance"], "demo-9b")
        code, _, body = self.get("/spark/metrics/demo-9b-kv8")
        self.assertEqual(code, 200)
        self.assertIn("error", json.loads(body)["instance"])
        code, _, body = self.get("/spark/metrics/unknown")
        self.assertEqual((code, json.loads(body)["error"]), (404, "unknown instance"))
        code, kind, body = self.get("/spark/metrics/demo-9b-mtp/raw")
        self.assertEqual(code, 200)
        self.assertTrue(kind.startswith("text/plain"))
        self.assertIn(b"vllm:spec_decode_num_drafts_total", body)
        self.assertEqual(self.get("/spark/metrics/mica-v0.5-4b/raw")[0], 404)
        self.assertEqual(self.get("/spark/metrics/demo-9b-kv8/raw")[0], 502)
        self.assertEqual(self.get("/spark/health")[0], 200)
        self.assertEqual(self.get("/spark/other")[0], 404)
        self.assertEqual(self.get("/spark/metrics", method="POST")[0], 501)
        self.assertEqual(self.get("/spark/metrics", method="HEAD")[0], 200)
        # Discovery is fresh on every request; nothing is cached.
        self.assertGreaterEqual(self.calls, 8)

    def test_status_failure_is_503(self):
        def broken():
            raise metrics.StatusError("spark status returned no JSON (exit 1)")

        self.server._status_source = broken
        code, _, body = self.get("/spark/metrics")
        self.assertEqual(code, 503)
        self.assertIn("no JSON", json.loads(body)["error"])

    def test_real_fetch_reads_prometheus_over_http(self):
        class Page(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                data = MTP.encode()
                self.send_response(200 if self.path == "/metrics" else 404)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        page = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
        threading.Thread(target=page.serve_forever, daemon=True).start()
        try:
            text = metrics.fetch_metrics_text(page.server_address[1], 2)
        finally:
            page.shutdown()
            page.server_close()
        self.assertIn("vllm:kv_cache_usage_perc", text)


if __name__ == "__main__":
    os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")
    unittest.main()
