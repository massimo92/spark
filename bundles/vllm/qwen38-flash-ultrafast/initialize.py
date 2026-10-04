#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Based on spark by Massimo Angelini - https://github.com/massimo92/spark
"""Image-owned preparation of the pinned UltraFast T80 model and PLE table."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

from huggingface_hub import HfApi, snapshot_download

ROOT = Path(os.environ["SPARK_BUNDLE_DIR"])
BASE_ID = "Saren/Qwen3.8-Flash-Next-W4A16-AutoRound-hybrid"
BASE_REV = "8b82f0b7abe3d1150a7827d298c75e86267636ae"
PLE_ID = "Saren/Qwen3.8-Flash-Next-ple-table-fp8"
PLE_REV = "50511b0a41aa1d34b8beb7e5d4bb06a0b650dc14"
BUILDER = "/opt/spark/model-build/build_int4side_model_dir.py"


def download(repo, revision, destination):
    info = HfApi().model_info(repo, revision=revision, files_metadata=True)
    missing = sum(
        max(0, (file.size or 0) - ((destination / file.rfilename).stat().st_size
            if (destination / file.rfilename).is_file() else 0))
        for file in info.siblings
    )
    free = shutil.disk_usage(ROOT).free
    if free < missing + 6 * 1024**3:
        raise RuntimeError(f"Download needs {missing / 1024**3:.1f} GiB plus 6 GiB scratch; {free / 1024**3:.1f} GiB free")
    print(f"Downloading {repo} @ {revision} ({missing / 1024**3:.1f} GiB remaining)", flush=True)
    snapshot_download(repo, revision=revision, local_dir=destination, max_workers=4)


def verify_hash(path, expected):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(8 * 1024**2), b""):
            digest.update(chunk)
    if digest.hexdigest() != expected:
        raise RuntimeError(f"Pinned source hash mismatch: {path}")


def main():
    source, ple = ROOT / "source", ROOT / "ple-table"
    output, staging = ROOT / "model", ROOT / ".model-staging"
    download(BASE_ID, BASE_REV, source)
    download(PLE_ID, PLE_REV, ple)
    verify_hash(source / "model.safetensors.index.json", "4da5d411d90f4b2d89d4e13fdf201516f6f877cb70a06aec3c1d4fd61509571f")
    verify_hash(source / "model_extra_tensors.safetensors", "e9e4786a8ef584c9cb112b0a2ce7063cb72db8e002694888d2a36d440edad83d")
    if not output.exists():
        # Only this initializer's unpublished staging directory is discarded.
        if staging.exists():
            shutil.rmtree(staging)
        subprocess.run([sys.executable, BUILDER, "--tier", "drafter-dense", "--group-size", "32",
                        "--model-dir", str(source), "--out-dir", str(staging)], check=True)
        verify(source, staging)
        staging.rename(output)
    else:
        verify(source, output)
    report = {"model": BASE_ID, "revision": BASE_REV, "ple_revision": PLE_REV,
              "model_path": "model", "key": os.environ["SPARK_BUNDLE_KEY"]}
    (ROOT / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print("UltraFast checkpoint and PLE table verified", flush=True)


def verify(source, output):
    subprocess.run([sys.executable, BUILDER, "--tier", "drafter-dense", "--group-size", "32",
                    "--verify-only", "--model-dir", str(source), "--out-dir", str(output)], check=True)
    report = json.loads((output / "dense-mtp-build-report.json").read_text())
    assert report["tier"] == "drafter-dense" and report["int4_tier"] == ""
    assert report["mtp_tier"] == "drafter-dense" and report["group_size"] == 32
    assert len(report["mtp_modules"]) == 9 and not report["modules"]
    assert report["mtp_totals"]["degenerate_groups"] == 0
    assert not any(file.is_symlink() for file in output.iterdir())


if __name__ == "__main__":
    main()
