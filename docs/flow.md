# spark — Logic Flow

Open in any Mermaid viewer (GitHub renders it, or paste in mermaid.live).

## Main dispatcher

```mermaid
flowchart LR
    start["spark &lt;cmd&gt;"] --> dispatch{command}
    dispatch -->|run| run["cmd_run :301"]
    dispatch -->|setup| setup["cmd_setup :695"]
    dispatch -->|stop| stop["cmd_stop :434"]
    dispatch -->|pull| pull["cmd_pull :445"]
    dispatch -->|list| list["cmd_list :457"]
    dispatch -->|rm| rm["cmd_rm :525"]
    dispatch -->|status| status["cmd_status :549"]
    dispatch -->|logs| logs["cmd_logs :588"]
    dispatch -->|doctor| doctor["cmd_doctor :603"]
    dispatch -->|update| update["cmd_update :1108"]
    dispatch -->|gateway| gateway["cmd_gateway"]
    dispatch -->|help| help["cmd_help"]
```

## spark run (core path)

```mermaid
flowchart TD
    parse["parse flags + model :305"] --> validate

    validate["validate inputs :322\nis_safe_model_ref\nis_port, is_mem_util"]
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
        p_read --> p_detect["detect:\n- reasoning_parser (qwen3/deepseek_r1)\n- tool_call_parser (qwen25)\n- max_position_embeddings\n- multimodal (vision_config)\n- model_size (sum .safetensors)"]
        p_detect --> p_calc["calc gpu_memory_utilization\n(size + 2GB + kv_cache) / 128GB\nclamp 0.50 - 0.95"]
        p_calc --> p_save["validate + save JSON\n~/.config/spark/profiles/"]
    end

    profile --> override["apply CLI overrides\n--mem, --max-len, --no-reasoning\n:358"]
    override --> ngc["detect_ngc_image :365\ndocker images | grep vllm"]
    ngc --> build["build arrays :370\nvllm_args: serve, model, flags\ndocker_cmd: gpus, network, ipc, ulimits, volume"]

    build --> dry{"--dry-run?"}
    dry -->|yes| print["shell_join + print\n:399"]
    dry -->|no| exec["docker run :420"]

    exec --> check{"exit 0?"}
    check -->|no| fail["err: docker run failed\nshow last 10 log lines\n:410"]
    check -->|yes| summary["print summary :427\nmodel, type, context,\nmemory, API URL"]

    summary --> tail{"--tail?"}
    tail -->|yes| logs["docker logs -f"]
    tail -->|no| done["done"]
```

## spark setup (wizard)

```mermaid
flowchart TD
    entry["cmd_setup :695\nparse --yes, --check"] --> run_setup

    run_setup["run_setup :735"] --> phase0

    phase0["Phase 0: Connect\nask DGX IP + username"] --> input{"IP provided?"}

    input -->|empty + --check| local_only["skip remote\nhas_remote=0"]
    input -->|empty, no --check| die["die: address required"]
    input -->|provided| ssh["open_remote :124\nSSH ControlMaster\nControlPersist=600"]

    ssh --> ssh_ok{"connected?"}
    ssh_ok -->|no| die2["die: cannot connect"]
    ssh_ok -->|yes| phase1

    local_only --> phase1

    phase1["Phase 1: Client Setup :774"]
    phase1 --> ts_local{"Tailscale\nlocal?"}
    ts_local -->|installed| ts_ok["OK"]
    ts_local -->|missing + not check| ts_install["macOS: manual step\nLinux: curl install.sh"]
    ts_local -->|missing + check| ts_fail["setup_fail"]

    ts_ok --> sshkey
    ts_install --> sshkey
    ts_fail --> sshkey

    sshkey{"SSH key\nexists?"}
    sshkey -->|yes| key_ok["OK"]
    sshkey -->|no + not check| keygen["ssh-keygen ed25519"]
    sshkey -->|no + check| key_fail["setup_fail"]

    key_ok --> has_r
    keygen --> has_r
    key_fail --> has_r

    has_r{"has_remote?"}
    has_r -->|no| summ
    has_r -->|yes| phase2

    phase2["Phase 2: DGX Remote :823"]
    phase2 --> gpu["remote nvidia-smi"]
    gpu --> apt["remote apt upgrade"]
    apt --> snap["remove firmware-updater"]
    snap --> uv["remote install uv"]
    uv --> nvitop["remote install nvitop"]
    nvitop --> jq["remote install jq"]
    jq --> ts_dgx["remote Tailscale\n+ manual_step auth"]
    ts_dgx --> docker["remote docker group"]
    docker --> ngc_login["NGC API key\nremote docker login"]
    ngc_login --> hf["remote HF CLI"]
    hf --> vllm["remote docker pull\nvLLM container"]

    vllm --> phase3["Phase 3: Secure Connection :983"]
    phase3 --> copykey["copy local pubkey\n→ remote authorized_keys"]
    copykey --> disable_pw["disable password SSH\nsed sshd_config + restart sshd"]
    disable_pw --> sync["NVIDIA Sync\n(macOS only)"]
    sync --> close["close_remote"]

    close --> summ

    summ{"failures?"}
    summ -->|yes| incomplete["Setup incomplete:\nN issues found"]
    summ -->|no + skips| skipped["Skipped steps:\nlist"]
    summ -->|all green| complete["Setup complete!\nssh user@host"]
```

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
