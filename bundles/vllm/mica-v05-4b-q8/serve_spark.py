"""Spark lifecycle adapter around the pinned official Mica decision runtime."""
import argparse
import json
import logging
import threading
import time
from http.server import ThreadingHTTPServer
from pathlib import Path

MODEL = "sky7350/Mica-v0.5-4B"
MAX_BODY_BYTES = 8 * 1024 * 1024


def parser():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("model_path")
    ap.add_argument("--port", type=int, default=8001)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--max-model-len", type=int, default=32768)
    ap.add_argument("--max-num-seqs", type=int, default=1)
    ap.add_argument("--gpu-memory-utilization", type=float, default=0.10)
    ap.add_argument("--kv-cache-dtype", choices=["auto"], default="auto")
    ap.add_argument("--enforce-eager", action="store_true")
    return ap


def make_server(address, engine):
    from mica import server
    lock = threading.Lock()

    class Handler(server.Handler):
        def do_GET(self):
            if self.path.rstrip("/") == "/v1/models":
                return self._send(200, {"object": "list", "data": [
                    {"id": MODEL, "object": "model", "owned_by": "spark", "api": "systemone"}
                ]})
            return super().do_GET()

        def do_POST(self):
            if self.path.rstrip("/") != "/v1/systemone":
                return self._send(404, {"error": {"message": "use /v1/systemone"}})
            try:
                size = int(self.headers.get("Content-Length", "0"))
                if not 0 < size <= MAX_BODY_BYTES:
                    return self._send(413, {"error": {"message": "maximum body size is 8 MiB"}})
                self.connection.settimeout(30)
                body = json.loads(self.rfile.read(size))
                if not isinstance(body, dict) or body.get("model") != MODEL:
                    raise ValueError("model must match the served model id")
                questions = body.get("questions")
                if not isinstance(questions, dict) or not 1 <= len(questions) <= 16:
                    raise ValueError("questions must contain 1 to 16 named questions")
            except (ValueError, UnicodeError, RecursionError) as exc:
                return self._send(400, {"error": {"message": str(exc)}})
            if not lock.acquire(blocking=False):
                return self._send(429, {"error": {"message": "decision engine busy; retry later"}})
            try:
                started = time.monotonic()
                result = engine(body)
                result["latency_ms"] = round((time.monotonic() - started) * 1000, 1)
                self._send(200, result)
            except (ValueError, RecursionError) as exc:
                self._send(400, {"error": {"message": str(exc)}})
            except Exception:
                logging.exception("Mica inference failed")
                self._send(500, {"error": {"message": "decision inference failed"}})
            finally:
                lock.release()

    return ThreadingHTTPServer(address, Handler)


def main():
    args = parser().parse_args()
    if not 1 <= args.max_model_len <= 32768 or not 1 <= args.max_num_seqs <= 4:
        raise SystemExit("Mica supports context up to 32768 and 1 to 4 question sequences")
    from transformers import AutoTokenizer
    from mica import server
    from mica.direct_backend import DirectJudge

    model_path = Path(args.model_path)
    server.MODEL_NAME = MODEL
    server.JUDGE = DirectJudge.from_calibration(
        model_path / "mica-v0.5-4b-Q8_0.gguf",
        AutoTokenizer.from_pretrained(model_path, local_files_only=True),
        "/opt/mica/calibration.json",
        runtime_dir="/opt/mica/runtime", n_ctx=args.max_model_len,
        n_seq_max=args.max_num_seqs, max_length=args.max_model_len,
        n_gpu_layers=-1, n_threads=4, n_ubatch=512,
        state_cache=True, long_input=True,
    )
    if "CUDA" not in server.JUDGE.lib.backends:
        raise SystemExit("CUDA backend is required; CPU fallback is disabled")
    print(json.dumps({"ready": True, "model": MODEL, "context": args.max_model_len,
                      "question_sequences": args.max_num_seqs, "http_concurrency": 1,
                      "backends": server.JUDGE.lib.backends,
                      "long_input": server.JUDGE.long_input}), flush=True)
    make_server((args.host, args.port), server.answer).serve_forever()


if __name__ == "__main__":
    main()
