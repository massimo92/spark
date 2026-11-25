#!/usr/bin/env python3
"""Spark metrics endpoint: a read-only JSON view of Spark-managed vLLM instances.

It binds to loopback only; `spark metrics start` publishes it on the tailnet with
Tailscale Serve. Every request rediscovers instances with `spark status --json`
and reads each instance's vLLM Prometheus /metrics with a short timeout.
"""
import argparse
import concurrent.futures
import datetime
import http.server
import json
import math
import re
import subprocess
import sys
import threading
import urllib.parse
import urllib.request

SCHEMA = 1
LOOPBACK_HOSTS = ("localhost", "127.0.0.1")
# Only these `spark status --json` fields are copied; nothing else leaves the host.
STATUS_FIELDS = (
    "instance", "name", "model", "container", "config", "engine", "api", "state",
    "endpoint", "gateway_model", "gateway_routed", "reserved_gb", "live_gb",
    "peak_gb", "engine_memory",
)
COUNTERS = (
    "prompt_tokens_total", "generation_tokens_total", "prefix_cache_hits_total",
    "prefix_cache_queries_total", "num_preemptions_total",
)
HISTOGRAMS = (
    "time_to_first_token_seconds", "inter_token_latency_seconds",
    "request_prefill_time_seconds", "request_decode_time_seconds",
    "e2e_request_latency_seconds",
)
MAX_METRICS_BYTES = 8 * 1024 * 1024

_SAMPLE = re.compile(r'^([A-Za-z_:][A-Za-z0-9_:]*)(?:\{(.*)\})?\s+(\S+)(?:\s+-?\d+)?\s*$')
_LABEL = re.compile(r'\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"((?:[^"\\]|\\.)*)"\s*(?:,|$)')
_UNESCAPE = {"n": "\n", "\\": "\\", '"': '"'}


def _number(value):
    """JSON has no NaN/Inf; emit null and keep integers integral."""
    if value is None or math.isnan(value) or math.isinf(value):
        return None
    return int(value) if float(value).is_integer() else value


def parse_labels(text):
    labels, pos = {}, 0
    while pos < len(text):
        match = _LABEL.match(text, pos)
        if not match:
            raise ValueError("bad labels: " + text)
        value = re.sub(r"\\(.)", lambda m: _UNESCAPE.get(m.group(1), m.group(1)), match.group(2))
        labels[match.group(1)] = value
        pos = match.end()
    return labels


def parse_prometheus(text):
    """Return {metric name: [(labels, value), ...]} from Prometheus text format."""
    samples = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = _SAMPLE.match(line)
        if not match:
            continue
        try:
            labels = parse_labels(match.group(2) or "")
            value = float(match.group(3))
        except ValueError:
            continue
        samples.setdefault(match.group(1), []).append((labels, value))
    return samples


def _total(samples, name):
    series = samples.get(name)
    return None if not series else sum(value for _, value in series)


def _maximum(samples, name):
    series = samples.get(name)
    return None if not series else max(value for _, value in series)


def _histogram(samples, base):
    count = _total(samples, "vllm:" + base + "_count")
    if count is None:
        return None
    buckets = {}
    for labels, value in samples.get("vllm:" + base + "_bucket", []):
        bound = labels.get("le")
        if bound is not None:
            buckets[bound] = buckets.get(bound, 0.0) + value

    def order(bound):
        try:
            return float(bound)
        except ValueError:
            return math.inf

    return {
        "sum": _number(_total(samples, "vllm:" + base + "_sum")),
        "count": _number(count),
        "buckets": [
            {"le": bound if math.isinf(order(bound)) else _number(order(bound)), "count": _number(buckets[bound])}
            for bound in sorted(buckets, key=order)
        ],
    }


def _label_value(value):
    if value in (None, "None", ""):
        return None
    try:
        return int(value)
    except ValueError:
        return value


def _spec_decode(samples):
    drafts = _total(samples, "vllm:spec_decode_num_drafts_total")
    if drafts is None:
        return None
    draft_tokens = _total(samples, "vllm:spec_decode_num_draft_tokens_total")
    accepted = _total(samples, "vllm:spec_decode_num_accepted_tokens_total")
    per_pos = {}
    for labels, value in samples.get("vllm:spec_decode_num_accepted_tokens_per_pos_total", []):
        try:
            position = int(labels.get("position", ""))
        except ValueError:
            continue
        per_pos[position] = per_pos.get(position, 0.0) + value
    accepted_per_pos = [_number(per_pos[p]) for p in sorted(per_pos)]
    return {
        "num_drafts": _number(drafts),
        "num_draft_tokens": _number(draft_tokens),
        "num_accepted_tokens": _number(accepted),
        "accepted_tokens_per_pos": accepted_per_pos,
        # Derived: accepted / proposed draft tokens, and tokens emitted per decode step.
        "acceptance_rate": round(accepted / draft_tokens, 4) if draft_tokens and accepted is not None else None,
        "mean_acceptance_length": round(1 + accepted / drafts, 4) if drafts and accepted is not None else None,
        "acceptance_rate_per_pos": [round(per_pos[p] / drafts, 4) for p in sorted(per_pos)] if drafts else [],
    }


def summarize(samples):
    """Reduce vLLM Prometheus samples to the fields Spark publishes."""
    kv_usage = _maximum(samples, "vllm:kv_cache_usage_perc")
    if kv_usage is None:
        kv_usage = _maximum(samples, "vllm:gpu_cache_usage_perc")
    cache = None
    info = samples.get("vllm:cache_config_info")
    if info:
        labels = info[0][0]
        cache = {key: _label_value(labels.get(key)) for key in ("block_size", "num_gpu_blocks", "cache_dtype")}
    result = {
        "kv_cache_usage_perc": _number(kv_usage),
        "num_requests_running": _number(_total(samples, "vllm:num_requests_running")),
        "num_requests_waiting": _number(_total(samples, "vllm:num_requests_waiting")),
        "cache_config": cache,
    }
    for name in COUNTERS:
        result[name] = _number(_total(samples, "vllm:" + name))
    result["spec_decode"] = _spec_decode(samples)
    result["histograms"] = {name: _histogram(samples, name) for name in HISTOGRAMS}
    return result


def read_meminfo(path):
    values = {}
    try:
        with open(path, encoding="ascii") as handle:
            for line in handle:
                key, _, rest = line.partition(":")
                parts = rest.split()
                if parts and parts[0].isdigit():
                    values[key] = int(parts[0])
    except OSError:
        pass

    def gib(kib):
        return None if kib is None else round(kib / 1048576, 2)

    total, available = values.get("MemTotal"), values.get("MemAvailable")
    swap_total, swap_free = values.get("SwapTotal"), values.get("SwapFree")
    return {
        "mem_total_gb": gib(total),
        "mem_used_gb": gib(total - available) if total is not None and available is not None else None,
        "mem_available_gb": gib(available),
        "swap_used_gb": gib(swap_total - swap_free) if swap_total is not None and swap_free is not None else None,
    }


def instance_id(model):
    return model.get("instance") or model.get("container") or model.get("name") or ""


def endpoint_port(endpoint):
    parts = urllib.parse.urlsplit(endpoint or "")
    if parts.scheme != "http" or parts.hostname not in LOOPBACK_HOSTS or not parts.port:
        raise ValueError("endpoint is not a local HTTP port: " + str(endpoint))
    return parts.port


def vllm_instances(status):
    return [m for m in status.get("models") or [] if isinstance(m, dict) and m.get("engine") == "vllm"]


_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def fetch_metrics_text(port, timeout):
    with _OPENER.open("http://127.0.0.1:%d/metrics" % port, timeout=timeout) as response:
        body = response.read(MAX_METRICS_BYTES + 1)
    if len(body) > MAX_METRICS_BYTES:
        raise ValueError("metrics response too large")
    return body.decode("utf-8", "replace")


def describe(model, fetch, timeout):
    """One instance: status fields, plus parsed vLLM metrics or an error."""
    item = {key: model.get(key) for key in STATUS_FIELDS}
    item["instance"] = instance_id(model)
    item["vllm"] = None
    if model.get("api", "chat") != "chat":
        item["metrics_skipped"] = "api %s does not expose vLLM metrics" % model.get("api")
        return item
    try:
        item["metrics_port"] = endpoint_port(model.get("endpoint"))
        samples = parse_prometheus(fetch(item["metrics_port"], timeout))
        if not any(name.startswith("vllm:") for name in samples):
            raise ValueError("response has no vLLM metrics")
        item["vllm"] = summarize(samples)
    except Exception as error:  # one broken instance must not fail the response
        item["error"] = "%s: %s" % (type(error).__name__, error)
    return item


def build_payload(status, fetch, timeout, meminfo, only=None):
    models = vllm_instances(status)
    if only is not None:
        models = [m for m in models if only in (instance_id(m), m.get("container"))]
    workers = max(1, min(8, len(models)))
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        instances = list(pool.map(lambda m: describe(m, fetch, timeout), models))
    return {
        "schema": SCHEMA,
        "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
        "host": read_meminfo(meminfo),
        "instances": instances,
    }


class StatusError(Exception):
    pass


def run_status(spark, timeout):
    try:
        done = subprocess.run(
            [spark, "status", "--json"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, timeout=timeout, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise StatusError("spark status failed: %s" % type(error).__name__)
    # A non-zero exit only means "not fully operational"; the JSON is still valid.
    try:
        status = json.loads(done.stdout.decode("utf-8", "replace"))
    except ValueError:
        raise StatusError("spark status returned no JSON (exit %d)" % done.returncode)
    if not isinstance(status, dict):
        raise StatusError("spark status returned unexpected JSON")
    return status


class MetricsServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, spark, timeout=2.0, status_timeout=60.0, meminfo="/proc/meminfo",
                 status_source=None, fetch=fetch_metrics_text):
        super().__init__(address, Handler)
        self.timeout_seconds = timeout
        self.meminfo = meminfo
        self.fetch = fetch
        self._status_lock = threading.Lock()
        self._status_source = status_source or (lambda: run_status(spark, status_timeout))

    def status(self):
        # Serialize discovery: concurrent polls must not fan out `spark status` runs.
        with self._status_lock:
            return self._status_source()


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "spark-metrics"
    sys_version = ""

    def log_message(self, *_args):
        pass

    def _send(self, code, body, content_type="application/json"):
        data = body if isinstance(body, bytes) else (json.dumps(body, indent=None) + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path.rstrip("/")
        # Tailscale Serve mounts this at /spark; accept the path with or without it.
        if path == "/spark" or path.startswith("/spark/"):
            path = path[len("/spark"):]
        parts = [urllib.parse.unquote(p) for p in path.split("/") if p]
        if parts == ["health"]:
            return self._send(200, {"ok": True, "schema": SCHEMA})
        if not parts or parts[0] != "metrics" or len(parts) > 3 or (len(parts) == 3 and parts[2] != "raw"):
            return self._send(404, {"error": "not found", "routes": [
                "/spark/metrics", "/spark/metrics/<instance>", "/spark/metrics/<instance>/raw", "/spark/health"]})
        try:
            status = self.server.status()
        except StatusError as error:
            return self._send(503, {"error": str(error)})
        server = self.server
        if len(parts) == 1:
            return self._send(200, build_payload(status, server.fetch, server.timeout_seconds, server.meminfo))
        name = parts[1]
        if not any(name in (instance_id(m), m.get("container")) for m in vllm_instances(status)):
            return self._send(404, {"error": "unknown instance", "instance": name})
        if len(parts) == 2:
            payload = build_payload(status, server.fetch, server.timeout_seconds, server.meminfo, only=name)
            instance = payload.pop("instances")[0]
            payload["instance"] = instance
            return self._send(200, payload)
        model = next(m for m in vllm_instances(status) if name in (instance_id(m), m.get("container")))
        if model.get("api", "chat") != "chat":
            return self._send(404, {"error": "api %s does not expose vLLM metrics" % model.get("api"), "instance": name})
        try:
            text = server.fetch(endpoint_port(model.get("endpoint")), server.timeout_seconds)
        except Exception as error:
            return self._send(502, {"error": "%s: %s" % (type(error).__name__, error), "instance": name})
        return self._send(200, text.encode(), "text/plain; version=0.0.4")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8791)
    parser.add_argument("--spark", required=True, help="absolute path of the spark CLI")
    parser.add_argument("--timeout", type=float, default=2.0, help="per-instance /metrics timeout")
    parser.add_argument("--meminfo", default="/proc/meminfo")
    args = parser.parse_args(argv)
    if args.host != "127.0.0.1":
        parser.error("--host must be 127.0.0.1; Tailscale Serve publishes it on the tailnet")
    if not 0 < args.timeout <= 2:
        parser.error("--timeout must be in (0, 2] seconds")
    server = MetricsServer((args.host, args.port), args.spark, timeout=args.timeout, meminfo=args.meminfo)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
