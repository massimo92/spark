# spark — Logic Flow

Open in any Mermaid viewer (GitHub renders it, or paste in mermaid.live).

For the current developer module map and source-boundary rules, run `spark architecture`.
The audit and refactor plan live in `docs/architecture.md`.

## Main dispatcher

```mermaid
flowchart LR
    load["at load: detect_platform\nSPARK_OS · SPARK_ARCH · ACCEL · BACKEND"] --> start
    start["spark &lt;cmd&gt;"] --> dispatch{command}
    dispatch -->|run| run["cmd_run\n→ run_backend_vllm | run_backend_ollama"]
    dispatch -->|setup| setup["cmd_setup\nwizard: this machine | remote over SSH"]
    dispatch -->|stop| stop["cmd_stop"]
    dispatch -->|pull| pull["cmd_pull"]
    dispatch -->|list| list["cmd_list"]
    dispatch -->|rm| rm["cmd_rm"]
    dispatch -->|status| status["cmd_status"]
    dispatch -->|logs| logs["cmd_logs"]
    dispatch -->|doctor| doctor["cmd_doctor"]
    dispatch -->|update| update["cmd_update"]
    dispatch -->|gateway| gateway["cmd_gateway"]
    dispatch -->|architecture| arch["cmd_architecture\nmodule map + invariants"]
    dispatch -->|help| help["cmd_help"]
```

`detect_platform` classifies the accelerator (`cuda-unified` / `cuda-discrete` / `metal` / `cpu`)
and selects the backend (`vllm` on NVIDIA, `ollama` otherwise). It runs once at load; everything
below reads `ACCEL`/`BACKEND`.

## spark run (core path)

```mermaid
flowchart TD
    parse["parse flags + model"] --> guard
    guard["validate_model_ref_for_backend\nblock NVFP4-on-Ollama / tag-on-vLLM"] --> fork
    fork{"BACKEND?"}
    fork -->|ollama| ollama["run_backend_ollama\nensure ollama + service\nollama pull → gateway_enable_ollama\nno container/port; Ollama manages memory"]
    fork -->|vllm| validate

    validate["validate inputs\nis_safe_model_ref\nis_port, is_mem_util"]
    validate --> container

    container{"container\nalready running?\n:329"}
    container -->|no| resolve
    container -->|yes| force{"--force?"}
    force -->|yes| stop["docker stop + rm\n:331"] --> resolve
    force -->|no| die1["die: already running"]

    resolve["resolve_model_path :348\ntry 3 HF cache paths"] --> profile

    subgraph profile ["profile_model :194"]
        p_cached{"cached JSON\nprofile?"}
        p_cached -->|yes + no --regen| p_load["load_profile :179\njq → global vars\n+ validate_profile_values"]
        p_cached -->|no or --regen| p_read["read config.json :208"]
        p_read --> p_detect["detect:\n- reasoning_parser (qwen3/deepseek_r1)\n- tool_call_parser (qwen3_coder)\n- max_model_len (128K, capped to model)\n- multimodal (vision_config)\n- weights (sum .safetensors)"]
        p_detect --> p_calc["need = (weights + KV) x 1.08\nKV = 2 x layers x kv_heads x head_dim x bytes x ctx\ngpu_memory_utilization = need / pool\npool = system RAM (unified) or VRAM (discrete GPU)"]
        p_calc --> p_save["validate + save JSON\n~/.config/spark/profiles/"]
    end

    profile --> override["apply CLI overrides + recompute\n--mem, --max-len, --kv-cache-dtype"]
    override --> verify["verify_capacity\nreserved + need <= total - OS reserve\nif not: fit_options → menu (auto/fp8 ctx) or\nsuggest+abort (non-interactive) or show (dry-run)"]
    verify --> port["assign port (auto 8000+)\nname spark-vllm-<slug>"]
    port --> ngc["detect_ngc_image\ndocker images | grep vllm"]
    ngc --> build["build_launch (rebuildable)\nvllm_args: serve, model, --max-num-seqs (5), --enforce-eager (auto)\ndocker_cmd: gpus, network, ipc, ulimits, volume, spark.* labels\n+ --memory = NEED + warmup headroom; --memory-swap higher (load peak spills to swap)"]

    build --> plan["print memory plan\nweights, KV, need, fraction, concurrency, free"]
    plan --> dry{"--dry-run?"}
    dry -->|yes| print["shell_join + print"]
    dry -->|no| exec["docker run -d"]

    exec --> runok{"container started?"}
    runok -->|no| fail["err: docker run failed\nshow last 10 log lines"]
    runok -->|yes| nowait{"--no-wait?"}
    nowait -->|yes| summary
    nowait -->|no| await["await_startup\npoll inspect / curl /v1/models / logs"]

    await --> verdict{"verdict"}
    verdict -->|ready| summary["print container + API URL\nauto-restart gateway"]
    verdict -->|timeout| summary
    verdict -->|exit:mamba:N| lower["lower --max-num-seqs → N\nbuild_launch + retry"]
    verdict -->|exit:oom| bump["--enforce-eager (kill CUDA-graph peak)\nbuild_launch + retry"]
    verdict -->|exit:other| abort["err: failed to start\nshow logs · exit 1"]
    lower --> exec
    bump --> exec

    summary --> tail{"--tail?"}
    tail -->|yes| logs["docker logs -f"]
    tail -->|no| done["done"]
```

`docker run -d` only reports that the container *started* — vLLM can still crash seconds later during
init (e.g. a hybrid/Mamba model whose concurrency exceeds the cache it can allocate). So spark
**supervises**: `await_startup` waits until the API serves, the container exits, or it times out. On a
recoverable exit it adjusts one lever and retries — lower `--max-num-seqs` for cache-block failures
(keeps memory tight), or `--enforce-eager` for a warmup OOM (removes the CUDA-graph capture peak). On
success it caches the measured peak (cgroup `memory.peak`) per model. `--no-wait` skips supervision.

## spark setup (one wizard, one install set)

`spark setup` asks **where** to install, then runs a single shared install set (`run_install_set`)
against the chosen target via the `ctx_*` layer — so a server gets the **same software** whether
configured locally or over SSH. `--check` reports without changing anything; `--yes` auto-confirms.

```mermaid
flowchart TD
    entry["cmd_setup\nparse --check / --yes"] --> wiz["run_setup_wizard"]
    wiz --> q1{"[1] this machine\n[2] another over SSH"}

    q1 -->|1 / empty+--check| local["setup_local\nSETUP_TARGET=local\ndetect_target_platform"]
    q1 -->|2| ask["setup_remote: ask user@host"]

    ask --> q2{"already have\npublic-key access?"}
    q2 -->|yes| openk["open_remote (key)"]
    q2 -->|no| boot["open_remote_bootstrap\nread -rs password → sshpass\n(fallback: interactive)"]
    openk --> det
    boot --> det["detect_target_platform\n(probe OS/accel over SSH)"]

    det --> p1["Phase 1 (client):\nensure_local_tailscale · ensure_local_ssh_key\ndeploy_spark_binary"]
    p1 --> shared

    local --> shared

    subgraph shared ["run_install_set — identical for local & remote (gated on TGT_OS/TGT_BACKEND)"]
        s_apt["apt upgrade (Linux)"] --> s_fork{"backend?"}
        s_fork -->|vllm| s_v["gpu · docker · docker group\nNVIDIA Container Toolkit · NGC login\nvLLM image · uv · HF CLI · nvitop"]
        s_fork -->|ollama| s_o["install Ollama · :11434 service"]
        s_v --> s_jq
        s_o --> s_jq
        s_jq["jq (Linux)"] --> s_gw["gateway: pull LiteLLM\nproviders + start"]
        s_gw --> s_hard["host hardening (Linux+systemd, idempotent):\nswap on + swappiness · earlyoom -m5 -s10 · control-plane OOM-protect (sshd/dbus/tailscaled/logind/resolved)"]
    end

    shared --> branch{"target?"}
    branch -->|local| lsec["step_tailscale\nsetup_local_secure_warn (warn only)\ncmd_doctor"]
    branch -->|remote| rsec["Phase 3 (secure):\nstep_copy_pubkey →\nreopen_remote_keybased (prove key) →\ndisable password SSH → NVIDIA Sync (macOS)"]

    lsec --> summ
    rsec --> summ
    summ["setup_summary:\ncomplete / skipped / incomplete"]
```

Key safety points: in **host** mode spark never disables password SSH automatically (you could
lock yourself out) — it only warns. In **server** mode it disables password auth **only after**
`reopen_remote_keybased` proves the freshly-copied key works; if that reconnect fails it aborts
before touching `sshd_config`.

The gateway always runs in Docker (so reboot-persistence matches Linux), but its networking branches
by OS: on macOS it publishes the port and reaches the host's native Ollama via
`host.docker.internal:11434`; on Linux it shares the host network and uses `localhost`. The YAML uses
the `ollama_chat/*` route.

## Simple commands

```mermaid
flowchart LR
    subgraph model_mgmt ["Model Management"]
        pull["spark pull :445\nvalidate → hf download"]
        list["spark list :457\nls models--* dirs\nshow name, size, age"]
        rm["spark rm :525\nvalidate → confirm → rm -rf"]
    end

    subgraph container_mgmt ["Container Management"]
        stop["spark stop :434\ndocker stop + rm"]
        status["spark status :549\ninspect: model, uptime, port"]
        logs["spark logs :588\ndocker logs [-f]"]
    end

    subgraph gateway_mgmt ["Gateway Management"]
        gw_start["spark gateway start\nload config → generate yaml\n→ docker run litellm"]
        gw_stop["spark gateway stop\ndocker stop + rm"]
        gw_status["spark gateway status\nshow port, providers"]
        gw_logs["spark gateway logs\ndocker logs [-f]"]
    end

    subgraph maintenance ["Maintenance"]
        doctor["spark doctor :603\ncheck: GPU, Docker, docker group,\nNGC auth, HF CLI, vLLM image, models"]
        update["spark update :1108\nask tag → docker manifest inspect\n→ docker pull"]
    end
```
