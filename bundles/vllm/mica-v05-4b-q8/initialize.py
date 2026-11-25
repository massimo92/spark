"""Download only the pinned Q8 weights and tokenizer through Spark initialization."""
import os
import shutil
from pathlib import Path

from huggingface_hub import snapshot_download

REVISION = "5ea7aafe324defec353494417ba723195c119b59"
FILES = [
    "mica-v0.5-4b-Q8_0.gguf", "config.json", "tokenizer.json",
    "tokenizer_config.json", "chat_template.jinja", "merges.txt", "vocab.json", "NOTICE",
]


def seed_completed_downloads(root):
    """Reuse Hub-verified files at this exact revision after a runtime image change."""
    dest = root / "model"
    metadata_rel = Path(".cache/huggingface/download")
    for ready in root.parent.glob("*/.spark-ready.json"):
        source = ready.parent / "model"
        if source == dest:
            continue
        for name in FILES:
            existing = source / name
            metadata = source / metadata_rel / (name + ".metadata")
            if (dest / name).exists() or not existing.is_file() or existing.is_symlink() or not metadata.is_file():
                continue
            lines = metadata.read_text().splitlines()
            if not lines or lines[0] != REVISION:
                continue
            dest.mkdir(parents=True, exist_ok=True)
            try:
                os.link(existing, dest / name)
            except OSError:
                shutil.copy2(existing, dest / name)
            (dest / metadata_rel).mkdir(parents=True, exist_ok=True)
            shutil.copy2(metadata, dest / metadata_rel / metadata.name)
            print("Reusing pinned cached file: " + name, flush=True)


def main():
    root = Path(os.environ["SPARK_BUNDLE_DIR"])
    seed_completed_downloads(root)
    snapshot_download(
        repo_id="sky7350/Mica-v0.5-4B", revision=REVISION,
        local_dir=root / "model", allow_patterns=FILES, max_workers=2,
    )


if __name__ == "__main__":
    main()
