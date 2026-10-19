"""Small HTTP adapter for the pinned Clef pooling runtime; no chat generation."""
from __future__ import annotations

import argparse
import base64
import binascii
import io
import json
import logging
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

MAX_BODY_BYTES = 8 * 1024 * 1024
MAX_QUESTIONS = 128


def validate_request(body: Any, model: str) -> dict[str, Any]:
    if not isinstance(body, dict) or body.get("model") != model:
        raise ValueError("model must match the served model id")
    if not isinstance(body.get("state"), (str, dict, list)):
        raise ValueError("state must be text, an object, or an array")
    if body.get("stream"):
        raise ValueError("System One decisions do not support streaming")
    questions = body.get("questions")
    if not isinstance(questions, dict) or not 1 <= len(questions) <= MAX_QUESTIONS:
        raise ValueError("questions must contain 1 to 128 named questions")
    for name, question in questions.items():
        if not name or not isinstance(question, dict):
            raise ValueError("every question must be a named object")
        kind, criteria = question.get("type"), question.get("criteria")
        if not isinstance(kind, str) or kind not in {"noul", "choice", "score"}:
            raise ValueError(f"{name}: type must be noul, choice, or score")
        if "instructions" in question and not isinstance(question["instructions"], str):
            raise ValueError(f"{name}: instructions must be text")
        if kind == "choice" and (not isinstance(criteria, dict) or not 1 <= len(criteria) <= 255):
            raise ValueError(f"{name}: choice requires 1 to 255 criteria")
        if kind == "score" and (not isinstance(criteria, list) or not 1 <= len(criteria) <= 10):
            raise ValueError(f"{name}: score requires 1 to 10 criteria")
        if kind == "noul" and not (question.get("instructions") or criteria):
            raise ValueError(f"{name}: noul requires instructions or criteria")
        if kind == "noul" and criteria is not None and not isinstance(criteria, dict):
            raise ValueError(f"{name}: noul criteria must be an object")
    if body.get("videos") or body.get("assets"):
        raise ValueError("videos and TypeSafe image assets are not supported by this endpoint")
    return body


def decode_images(body: dict[str, Any]) -> dict[str, Any]:
    images = body.get("images", [])
    if not isinstance(images, list) or len(images) > 1:
        raise ValueError("images must be an array with at most one image data URL")
    if not images:
        return body
    for value in images:
        if not isinstance(value, str) or ";base64," not in value:
            raise ValueError("images must be base64 PNG/JPEG/WebP data URLs")
        header, data = value.split(",", 1)
        if header not in {"data:image/png;base64", "data:image/jpeg;base64", "data:image/webp;base64"}:
            raise ValueError("unsupported image data URL")
    from PIL import Image, UnidentifiedImageError

    decoded = []
    for value in images:
        data = value.split(",", 1)[1]
        try:
            with Image.open(io.BytesIO(base64.b64decode(data, validate=True))) as image:
                if image.width * image.height > 16_000_000:
                    raise ValueError("image exceeds 16 million pixels")
                decoded.append(image.convert("RGB"))
        except (binascii.Error, UnidentifiedImageError, OSError, Image.DecompressionBombError) as exc:
            raise ValueError("invalid image data") from exc
    return {**body, "images": decoded}


def make_server(address: tuple[str, int], engine: Any, model: str) -> ThreadingHTTPServer:
    inference_lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format: str, *args: Any) -> None:
            logging.info(format, *args)

        def respond(self, status: int, body: dict[str, Any]) -> None:
            data = json.dumps(body, allow_nan=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self) -> None:
            if self.path == "/health":
                self.respond(200, {"status": "ready"})
            elif self.path == "/v1/models":
                self.respond(200, {"object": "list", "data": [
                    {"id": model, "object": "model", "owned_by": "spark", "api": "systemone"}
                ]})
            else:
                self.respond(404, {"error": {"message": "unknown endpoint"}})

        def do_POST(self) -> None:
            if self.path != "/v1/systemone":
                self.respond(404, {"error": {"message": "use /v1/systemone"}})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= MAX_BODY_BYTES:
                    self.respond(413, {"error": {"message": "request must be between 1 byte and 8 MiB"}})
                    return
                self.connection.settimeout(30)
                request = validate_request(json.loads(self.rfile.read(length)), model)
                request = decode_images(request)
            except (ValueError, UnicodeError) as exc:
                self.respond(400, {"error": {"message": str(exc)}})
                return
            if not inference_lock.acquire(blocking=False):
                self.respond(429, {"error": {"message": "decision engine busy; retry later"}})
                return
            try:
                self.respond(200, engine.systemone(request))
            except ValueError as exc:
                self.respond(400, {"error": {"message": str(exc)}})
            except Exception:
                logging.exception("Clef decision failed")
                self.respond(500, {"error": {"message": "decision inference failed"}})
            finally:
                inference_lock.release()

    return ThreadingHTTPServer(address, Handler)


def encode_complete_record(engine: Any, record: dict[str, Any], encoder: Any) -> Any:
    # Upstream encode_record silently truncates the state to max_length. A
    # decision about incomplete evidence is unsafe even when its schema fits.
    encoded = encoder(engine.tokenizer, record, max_length=sys.maxsize, processor=engine.processor)
    if len(encoded.input_ids) > engine.max_model_len:
        raise ValueError(f"request needs {len(encoded.input_ids)} tokens; maximum is {engine.max_model_len}")
    return encoded


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("model")
    result.add_argument("--revision", required=True)
    result.add_argument("--host", default="127.0.0.1")
    result.add_argument("--port", type=int, default=8000)
    result.add_argument("--max-model-len", type=int, default=8192)
    result.add_argument("--max-num-seqs", type=int, default=1)
    result.add_argument("--max-num-batched-tokens", type=int, default=8192)
    result.add_argument("--gpu-memory-utilization", type=float, default=0.12)
    result.add_argument("--kv-cache-memory-bytes", type=int, default=1610612736)
    result.add_argument("--kv-cache-dtype", choices=["auto", "bfloat16", "fp8"], default="auto")
    result.add_argument("--enforce-eager", action="store_true")
    result.add_argument("--trust-remote-code", action="store_true")
    result.add_argument("--limit-mm-per-prompt", type=json.loads, default={"image": 1, "video": 0})
    return result


def load_engine(args: argparse.Namespace) -> Any:
    from huggingface_hub import snapshot_download

    path = str(Path(args.model).resolve()) if Path(args.model).is_dir() else snapshot_download(
        args.model, revision=args.revision, local_files_only=True
    )
    # Both Python modules are part of the immutable HF snapshot downloaded by Spark.
    os.environ["CLEF_MODEL_PATH"] = path
    sys.path.insert(0, path)
    from clef_vllm import ClefVLLM
    from joint_schema_model import encode_record

    class BoundedClef(ClefVLLM):
        def encode(self, record: dict[str, Any]) -> Any:
            return encode_complete_record(self, record, encode_record)

    return BoundedClef(
        path, max_model_len=args.max_model_len,
        gpu_memory_utilization=args.gpu_memory_utilization,
        kv_cache_gib=args.kv_cache_memory_bytes / 2**30,
        max_images=args.limit_mm_per_prompt.get("image", 1), max_videos=0,
        max_num_seqs=args.max_num_seqs, max_num_batched_tokens=args.max_num_batched_tokens,
        kv_cache_dtype=args.kv_cache_dtype, enforce_eager=args.enforce_eager,
    )


def main() -> None:
    args = parser().parse_args()
    if (args.max_model_len < 1 or args.max_num_seqs < 1 or args.kv_cache_memory_bytes < 1
            or not 0 < args.gpu_memory_utilization <= 1):
        raise SystemExit("context, concurrency, KV bytes and memory fraction must be positive")
    logging.basicConfig(level=logging.INFO)
    engine = load_engine(args)
    # Bind only after weights and the joint head are ready.
    server = make_server((args.host, args.port), engine, args.model)
    logging.info("System One ready: %s on %s:%s", args.model, args.host, args.port)
    server.serve_forever()


if __name__ == "__main__":
    main()
