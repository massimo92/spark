#!/usr/bin/env python3
"""Inspect a Hugging Face model and print stable JSON for spark."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any


FILES = [
    "config.json",
    "generation_config.json",
    "tokenizer_config.json",
    "chat_template.jinja",
    "hf_quant_config.json",
]


def load_json(path: Path | None) -> dict[str, Any]:
    if not path or not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as fh:
        data = json.load(fh)
    return data if isinstance(data, dict) else {}


def text_lower(value: Any) -> str:
    return str(value or "").lower()


def first_value(data: dict[str, Any], *keys: str) -> Any:
    for key in keys:
        if key in data and data[key] not in (None, ""):
            return data[key]
    return None


def nested_config(config: dict[str, Any]) -> dict[str, Any]:
    text_config = config.get("text_config")
    return text_config if isinstance(text_config, dict) else config


def recursive_has_key(data: Any, pattern: re.Pattern[str]) -> bool:
    if isinstance(data, dict):
        return any(pattern.search(str(k)) or recursive_has_key(v, pattern) for k, v in data.items())
    if isinstance(data, list):
        return any(recursive_has_key(v, pattern) for v in data)
    return False


def parse_int_token(raw: str) -> int | None:
    value = raw.strip().lower().replace(",", "").replace("_", "")
    mult = 1
    if value.endswith("k"):
        mult = 1000
        value = value[:-1]
    elif value.endswith("m"):
        mult = 1000000
        value = value[:-1]
    try:
        return int(float(value) * mult)
    except ValueError:
        return None


def config_context(config: dict[str, Any]) -> int | None:
    base = nested_config(config)
    for key in ("max_position_embeddings", "max_sequence_length", "seq_length", "n_positions"):
        value = base.get(key)
        if isinstance(value, int) and value > 0:
            return value
        if isinstance(value, str):
            parsed = parse_int_token(value)
            if parsed and parsed > 0:
                return parsed
    return None


def extract_command(card_text: str) -> str:
    lines = card_text.splitlines()
    for idx, line in enumerate(lines):
        if "vllm serve" not in line and "python -m vllm" not in line:
            continue
        chunk = [line.strip().rstrip("\\").strip()]
        for cont in lines[idx + 1 : idx + 20]:
            stripped = cont.strip().rstrip("\\").strip()
            if not stripped:
                break
            if stripped.startswith("--") or cont.startswith((" ", "\t")):
                chunk.append(stripped)
                continue
            break
        return " ".join(chunk)
    return ""


def extract_card_context(card_text: str, command: str) -> int | None:
    match = re.search(r"--max-model-len\s+([0-9][0-9,_.]*[kKmM]?)", command)
    if match:
        parsed = parse_int_token(match.group(1))
        if parsed:
            return parsed

    patterns = [
        r"(?:context|ctx|sequence length|max(?:imum)?(?: model)? len|max_model_len|max-model-len)[^\n]{0,80}?([0-9][0-9,_.]*[kKmM]?)",
        r"([0-9][0-9,_.]*[kKmM]?)\s*(?:tokens?|ctx)[^\n]{0,50}(?:context|window|length)",
    ]
    for pattern in patterns:
        for match in re.finditer(pattern, card_text, re.IGNORECASE):
            parsed = parse_int_token(match.group(1))
            if parsed and parsed >= 4096:
                return parsed
    return None


def quantization(config: dict[str, Any], hf_quant: dict[str, Any], tags: list[str], model_id: str) -> str:
    side_raw = text_lower(json.dumps({"hf_quant": hf_quant, "tags": tags, "model_id": model_id}, sort_keys=True))
    qconf = config.get("quantization_config")
    if isinstance(qconf, dict):
        q = first_value(qconf, "quant_method", "quant_algo", "quantization", "bits")
        if q is not None:
            raw = text_lower(q)
            # Some NVIDIA HF repos expose the container format as "compressed-tensors" in
            # config.json while the concrete hardware quantization (nvfp4/fp8) is in tags/card.
            if "compressed" in raw:
                for key in ("nvfp4", "fp8", "fp4", "int4", "int8"):
                    if key in side_raw:
                        return key
            if "nvfp4" in raw:
                return "nvfp4"
            if "fp8" in raw:
                return "fp8"
            if "fp4" in raw:
                return "fp4"
            if "int4" in raw or raw == "4":
                return "int4"
            if "int8" in raw or raw == "8":
                return "int8"
            return raw
    for key in ("nvfp4", "fp8", "fp4", "int4", "int8", "gguf"):
        if key in side_raw:
            return key
    dtype = text_lower(config.get("torch_dtype"))
    return dtype


def model_family(model_id: str, config: dict[str, Any]) -> str:
    raw = f"{config.get('model_type', '')} {model_id}".lower()
    for family in ("qwen", "deepseek", "llama", "gemma", "mistral", "mixtral", "intern", "phi"):
        if family in raw:
            return "qwen" if family == "qwen" else family
    return text_lower(config.get("model_type"))


def has_moe(config: dict[str, Any], archs: list[str]) -> bool:
    base = nested_config(config)
    expert_keys = ("num_experts", "num_experts_per_tok", "n_routed_experts", "num_local_experts")
    return any(k in base for k in expert_keys) or any(re.search(r"moe|mixture", a, re.I) for a in archs)


def is_multimodal(config: dict[str, Any], archs: list[str], tags: list[str]) -> bool:
    if "vision_config" in config or "visual" in config:
        return True
    raw = " ".join(archs + tags).lower()
    return any(token in raw for token in ("vl", "vision", "multimodal", "image"))


def supports_tools(card_text: str, tokenizer_config: dict[str, Any], tags: list[str]) -> bool:
    raw = f"{card_text}\n{json.dumps(tokenizer_config, sort_keys=True)}\n{' '.join(tags)}".lower()
    return any(token in raw for token in ("tool calling", "tool-call", "function calling", "tools", "<tool_call>"))


def recommended_runtime(card_text: str, tags: list[str], command: str) -> str:
    raw = f"{card_text}\n{' '.join(tags)}\n{command}".lower()
    if "vllm serve" in raw or " vllm" in raw or "vllm" in tags:
        return "vllm"
    if "sglang" in raw:
        return "sglang"
    if "llama.cpp" in raw or "gguf" in raw:
        return "llama.cpp"
    return ""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-id", "--model", dest="model_id", required=True)
    parser.add_argument("--revision", default=None)
    parser.add_argument("--local-path", default="")
    parser.add_argument("--local-files-only", action="store_true")
    args = parser.parse_args()

    injected = os.environ.get("SPARK_HF_MODEL_INSPECT_JSON")
    if injected:
        parsed = json.loads(injected)
        print(json.dumps(parsed, sort_keys=True))
        return 0

    local_path = Path(args.local_path).expanduser() if args.local_path else None

    try:
        from huggingface_hub import ModelCard, hf_hub_download, model_info
    except Exception as exc:  # pragma: no cover - exercised by shell tests without the dependency.
        ModelCard = hf_hub_download = model_info = None  # type: ignore[assignment]
        import_error = exc
    else:
        import_error = None

    info = None
    info_error = ""
    if model_info is not None:
        try:
            info = model_info(args.model_id, revision=args.revision, files_metadata=False)
        except Exception as exc:
            info_error = str(exc)

    paths: dict[str, Path] = {}
    for name in FILES:
        local_file = local_path / name if local_path else None
        if local_file and local_file.exists():
            paths[name] = local_file
            continue
        if hf_hub_download is None:
            continue
        try:
            downloaded = hf_hub_download(
                repo_id=args.model_id,
                filename=name,
                revision=args.revision,
                local_files_only=args.local_files_only,
            )
            paths[name] = Path(downloaded)
        except Exception:
            pass

    if "config.json" not in paths:
        if import_error is not None:
            print(f"huggingface_hub is required: {import_error}", file=sys.stderr)
        elif info_error:
            print(f"could not inspect {args.model_id}: {info_error}", file=sys.stderr)
        else:
            print(f"config.json not found for {args.model_id}", file=sys.stderr)
        return 1

    card_text = ""
    card_license = ""
    if ModelCard is not None:
        try:
            card = ModelCard.load(args.model_id, revision=args.revision)
            card_text = str(card)
            card_license = str(getattr(getattr(card, "data", None), "license", "") or "")
        except Exception:
            card_text = ""

    config = load_json(paths.get("config.json"))
    generation_config = load_json(paths.get("generation_config.json"))
    tokenizer_config = load_json(paths.get("tokenizer_config.json"))
    hf_quant = load_json(paths.get("hf_quant_config.json"))
    archs = config.get("architectures") if isinstance(config.get("architectures"), list) else []
    archs = [str(a) for a in archs]
    tags = [str(t) for t in (getattr(info, "tags", None) or [])]
    siblings = [str(getattr(s, "rfilename", "")) for s in (getattr(info, "siblings", None) or []) if getattr(s, "rfilename", "")]
    if local_path and local_path.exists():
        siblings.extend(p.name for p in local_path.iterdir())

    command = extract_command(card_text)
    card_ctx = extract_card_context(card_text, command)
    cfg_ctx = config_context(config)
    family = model_family(args.model_id, config)
    quant = quantization(config, hf_quant, tags, args.model_id)
    moe = has_moe(config, archs)
    multimodal = is_multimodal(config, archs, tags)
    raw_for_mtp = f"{card_text}\n{' '.join(tags)}\n{' '.join(siblings)}\n{json.dumps(config, sort_keys=True)}".lower()
    has_mtp = "mtp" in raw_for_mtp or recursive_has_key(config, re.compile("mtp", re.I))
    has_reasoning = family in ("qwen", "deepseek") or "reasoning" in f"{card_text} {' '.join(tags)}".lower()
    tools = supports_tools(card_text, tokenizer_config, tags)
    kv_fp8_recommended = "--kv-cache-dtype fp8" in command.lower() or "kv cache fp8" in card_text.lower()

    if not card_license:
        card_data = getattr(info, "card_data", None)
        license_value = getattr(card_data, "license", "") if card_data else ""
        card_license = str(license_value or "")

    output = {
        "model_id": args.model_id,
        "revision": args.revision or str(getattr(info, "sha", "") or ""),
        "tags": tags,
        "sources": {
            "model_info": info is not None,
            "model_card": bool(card_text),
            "files": sorted(paths.keys()),
        },
        "card": {
            "license": card_license,
            "recommended_runtime": recommended_runtime(card_text, tags, command),
            "recommended_command": command,
            "long_context": bool((card_ctx or cfg_ctx or 0) >= 65536),
            "recommended_context": card_ctx,
            "config_context": cfg_ctx,
            "kv_cache_fp8_recommended": kv_fp8_recommended,
        },
        "features": {
            "family": family,
            "architecture": "moe" if moe else "dense",
            "quantization": quant,
            "has_mtp": has_mtp,
            "has_reasoning": has_reasoning,
            "supports_tools": tools,
            "is_multimodal": multimodal,
            "is_moe": moe,
            "is_nvfp4": quant == "nvfp4",
            "is_fp8": quant == "fp8",
            "is_gguf": quant == "gguf" or "gguf" in " ".join(tags).lower(),
        },
        "raw": {
            "model_type": config.get("model_type", ""),
            "architectures": archs,
            "quantization_config": config.get("quantization_config", {}),
            "hf_quant_config": hf_quant,
            "generation_config": generation_config,
            "num_experts": nested_config(config).get("num_experts"),
            "num_experts_per_tok": nested_config(config).get("num_experts_per_tok"),
            "n_routed_experts": nested_config(config).get("n_routed_experts"),
        },
    }
    print(json.dumps(output, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
