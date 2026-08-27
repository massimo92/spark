# --- Public model benchmarking (GuideLLM) ---

GUIDELLM_IMAGE_DEFAULT="ghcr.io/vllm-project/guidellm:v0.7.2"
GUIDELLM_DATASET_DEFAULT="garage-bAInd/Open-Platypus"

cmd_benchmark_help() {
  cat <<EOF

  ${BOLD}Usage:${NC} spark benchmark [flags] [-- <GuideLLM args...>]

  Benchmarks a running Spark vLLM model with GuideLLM. One running model is
  selected automatically; with several, Spark asks which one to test.

  ${BOLD}Flags:${NC}
    --model <model>       Select an exact running model non-interactively.
    --profile <profile>   synchronous, throughput, sweep, or a GuideLLM config.
                          Default: sweep.
    --requests <int>      Requests per strategy. Default: 100.
    --duration <seconds>  Seconds per strategy; replaces --requests.
    --output-tokens <int> Force a comparable output length. Default: 256.
    --dataset <HF id>     Public Hugging Face dataset. Default:
                          ${GUIDELLM_DATASET_DEFAULT}
    --data <config>       Raw GuideLLM data config; replaces --dataset.
    --thinking <mode>     on, off, or auto. Default: off.
    --output-dir <path>   Results directory. Default: Spark data directory.
    --image <image>       GuideLLM image. Default: ${GUIDELLM_IMAGE_DEFAULT}
    --dry-run             Print the resolved Docker command only.
    -h, --help            Show this help.

  Arguments after -- pass unchanged to GuideLLM. GuideLLM validates them.
  Results are saved as JSON, CSV, HTML, plus a Spark metadata manifest.

  ${BOLD}Examples:${NC}
    spark benchmark
    spark benchmark --model google/gemma-3-27b-it --profile synchronous
    spark benchmark --duration 30 -- --metrics kind=generative,sample_size=0

EOF
}

benchmark_select_model() {
  local requested="$1" name model port rest choice i
  local -a models=() ports=() names=()

  while IFS=$'\t' read -r name model port rest; do
    [[ -n "$name" && -n "$model" ]] || continue
    is_safe_model_ref "$model" || continue
    is_port "$port" || continue
    names+=("$name"); models+=("$model"); ports+=("$port")
  done < <(list_managed_containers)

  [[ ${#models[@]} -gt 0 ]] || die "No running Spark vLLM models found" \
    "Start one first: spark run <model>"

  if [[ -n "$requested" ]]; then
    for i in "${!models[@]}"; do
      if [[ "${models[$i]}" == "$requested" ]]; then
        BENCHMARK_MODEL="${models[$i]}"
        BENCHMARK_PORT="${ports[$i]}"
        BENCHMARK_CONTAINER="${names[$i]}"
        return 0
      fi
    done
    die "Model '${requested}' is not running" "Run 'spark status' to see active models."
  fi

  if [[ ${#models[@]} -eq 1 ]]; then
    BENCHMARK_MODEL="${models[0]}"
    BENCHMARK_PORT="${ports[0]}"
    BENCHMARK_CONTAINER="${names[0]}"
    return 0
  fi

  is_interactive || die "Several models are running; choose one with --model" \
    "Run 'spark status' to see active models."
  printf '\n  Running models:\n'
  for i in "${!models[@]}"; do
    printf '    %d) %s  (port %s)\n' "$((i + 1))" "${models[$i]}" "${ports[$i]}"
  done
  printf '  Model to benchmark: '
  IFS= read -r choice
  [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le ${#models[@]} ]] \
    || die "Choose a model number from the list"
  i=$((choice - 1))
  BENCHMARK_MODEL="${models[$i]}"
  BENCHMARK_PORT="${ports[$i]}"
  BENCHMARK_CONTAINER="${names[$i]}"
}

benchmark_profile_config() {
  case "$1" in
    synchronous|throughput) printf 'kind=%s\n' "$1" ;;
    sweep) printf 'kind=sweep,sweep_size=5\n' ;;
    kind=*) printf '%s\n' "$1" ;;
    *) die "Invalid --profile value: $1" \
      "Use synchronous, throughput, sweep, or a GuideLLM kind=... config." ;;
  esac
}

benchmark_print_command() {
  local arg
  printf '  '
  for arg in "$@"; do printf '%q ' "$arg"; done
  printf '\n'
}

cmd_benchmark() {
  local requested_model="" profile="sweep" requests=100 duration="" output_tokens=256
  local dataset="$GUIDELLM_DATASET_DEFAULT" data_config="" thinking="off"
  local output_dir="" image="${SPARK_GUIDELLM_IMAGE:-$GUIDELLM_IMAGE_DEFAULT}" dry_run=0 passthrough=0
  local -a guidellm_extra=()

  while [[ $# -gt 0 ]]; do
    if [[ "$passthrough" == "1" ]]; then
      guidellm_extra+=("$1")
      shift
      continue
    fi
    case "$1" in
      --) passthrough=1; shift ;;
      --model) [[ $# -ge 2 ]] || die "Missing value for --model"; requested_model="$2"; shift 2 ;;
      --profile) [[ $# -ge 2 ]] || die "Missing value for --profile"; profile="$2"; shift 2 ;;
      --requests) [[ $# -ge 2 ]] || die "Missing value for --requests"; requests="$2"; shift 2 ;;
      --duration) [[ $# -ge 2 ]] || die "Missing value for --duration"; duration="$2"; shift 2 ;;
      --output-tokens) [[ $# -ge 2 ]] || die "Missing value for --output-tokens"; output_tokens="$2"; shift 2 ;;
      --dataset) [[ $# -ge 2 ]] || die "Missing value for --dataset"; dataset="$2"; shift 2 ;;
      --data) [[ $# -ge 2 ]] || die "Missing value for --data"; data_config="$2"; shift 2 ;;
      --thinking) [[ $# -ge 2 ]] || die "Missing value for --thinking"; thinking="$2"; shift 2 ;;
      --output-dir) [[ $# -ge 2 ]] || die "Missing value for --output-dir"; output_dir="$2"; shift 2 ;;
      --image) [[ $# -ge 2 ]] || die "Missing value for --image"; image="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      -h|--help) cmd_benchmark_help; return 0 ;;
      *) die "Unknown benchmark argument: $1" \
        "Use -- before raw GuideLLM arguments: spark benchmark -- $1" ;;
    esac
  done

  [[ "$BACKEND" == "vllm" ]] || die "Benchmark currently requires Spark's vLLM backend"
  command -v docker >/dev/null 2>&1 || die "Docker is required for GuideLLM"
  command -v jq >/dev/null 2>&1 || die "jq is required for benchmark metadata"
  is_positive_int "$requests" || die "Invalid --requests value: $requests"
  [[ -z "$duration" ]] || is_positive_int "$duration" || die "Invalid --duration value: $duration"
  is_positive_int "$output_tokens" || die "Invalid --output-tokens value: $output_tokens"
  [[ "$thinking" =~ ^(on|off|auto)$ ]] || die "Invalid --thinking value: $thinking" "Expected: on, off, or auto."
  is_safe_container_image_ref "$image" || die "Unsafe GuideLLM image reference: $image"
  [[ -n "$data_config" || "$dataset" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
    || die "Invalid Hugging Face dataset: $dataset" "Use --data for a raw GuideLLM data config."
  [[ "$output_dir" != *$'\n'* && "$output_dir" != *:* ]] || die "Invalid --output-dir path"

  local profile_config constraint_config backend_config target_host target timestamp slug manifest
  local host_output_dir container_output_dir="/results"
  local -a docker_args guidellm_args
  profile_config=$(benchmark_profile_config "$profile")
  benchmark_select_model "$requested_model"

  target_host="127.0.0.1"
  docker_args=(docker run --rm)
  if [[ "$SPARK_OS" == "Linux" ]]; then
    docker_args+=(--network host)
  else
    target_host="host.docker.internal"
  fi
  target="http://${target_host}:${BENCHMARK_PORT}"

  timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
  slug=$(slugify_model "$BENCHMARK_MODEL")
  output_dir="${output_dir:-${SPARK_DATA_DIR}/benchmarks/${timestamp}-${slug}}"
  if [[ "$output_dir" == /* ]]; then
    host_output_dir="$output_dir"
  else
    host_output_dir="${PWD}/${output_dir}"
  fi

  if [[ -n "$data_config" ]]; then
    :
  else
    data_config="kind=huggingface,source=${dataset}"
  fi
  if [[ -n "$duration" ]]; then
    constraint_config="kind=max_duration,seconds=${duration}"
  else
    constraint_config="kind=max_requests,count=${requests}"
  fi

  if [[ "$thinking" == "auto" ]]; then
    backend_config=$(jq -cn --arg target "$target" --arg model "$BENCHMARK_MODEL" \
      --argjson output_tokens "$output_tokens" \
      '{kind:"openai_http",target:$target,model:$model,request_format:"/v1/chat/completions",
        extras:{body:{max_completion_tokens:$output_tokens,ignore_eos:true}}}')
  else
    local thinking_json=false
    [[ "$thinking" == "on" ]] && thinking_json=true
    backend_config=$(jq -cn --arg target "$target" --arg model "$BENCHMARK_MODEL" \
      --argjson thinking "$thinking_json" --argjson output_tokens "$output_tokens" \
      '{kind:"openai_http",target:$target,model:$model,request_format:"/v1/chat/completions",
        extras:{body:{max_completion_tokens:$output_tokens,ignore_eos:true,
          chat_template_kwargs:{enable_thinking:$thinking}}}}')
  fi

  docker_args+=(--ipc host --user "$(id -u):$(id -g)" -e "HOME=/tmp/guidellm" \
    -e "HF_HOME=/cache/huggingface" \
    -v "${HF_CACHE_DIR}:/cache/huggingface" -v "${host_output_dir}:${container_output_dir}" \
    "$image" run)
  guidellm_args=(--backend "$backend_config" --data "$data_config" \
    --profile "$profile_config" --constraint "$constraint_config" \
    --seed "kind=static,value=42" --metrics "kind=generative,sample_size=100" \
    --output "kind=json,path=/results/benchmark.json" \
    --output "kind=csv,path=/results/benchmark.csv" \
    --output "kind=html,path=/results/benchmark.html")
  if [[ ${#guidellm_extra[@]} -gt 0 ]]; then
    guidellm_args+=("${guidellm_extra[@]}")
  fi

  printf '\n  Benchmark target: %s (%s, port %s)\n' "$BENCHMARK_MODEL" "$BENCHMARK_CONTAINER" "$BENCHMARK_PORT"
  printf '  Dataset:         %s\n' "$data_config"
  printf '  Profile:         %s\n' "$profile_config"
  printf '  Thinking:        %s\n' "$thinking"
  printf '  Output tokens:   %s\n' "$output_tokens"
  printf '  Results:         %s\n\n' "$host_output_dir"
  if [[ "$dry_run" == "1" ]]; then
    benchmark_print_command "${docker_args[@]}" "${guidellm_args[@]}"
    return 0
  fi

  curl -fsS --max-time 5 "http://127.0.0.1:${BENCHMARK_PORT}/v1/models" >/dev/null 2>&1 \
    || die "Model API is not ready on port ${BENCHMARK_PORT}"
  ensure_hf_cache_writable
  mkdir -p "$host_output_dir" || die "Could not create benchmark results directory"
  chmod 700 "$host_output_dir" 2>/dev/null || true
  local result_file
  for result_file in spark.json benchmark.json benchmark.csv benchmark.html; do
    [[ ! -e "${host_output_dir}/${result_file}" ]] \
      || die "Benchmark output already exists: ${host_output_dir}/${result_file}" \
        "Choose another directory with --output-dir."
  done

  manifest="${host_output_dir}/spark.json"
  jq -n --arg timestamp "$timestamp" --arg model "$BENCHMARK_MODEL" --arg container "$BENCHMARK_CONTAINER" \
    --argjson port "$BENCHMARK_PORT" --arg image "$image" --arg dataset "$data_config" \
    --arg profile "$profile_config" --arg constraint "$constraint_config" --arg thinking "$thinking" \
    --argjson output_tokens "$output_tokens" \
    '{timestamp:$timestamp,model:$model,container:$container,port:$port,image:$image,
      data:$dataset,profile:$profile,constraint:$constraint,thinking:$thinking,
      output_tokens:$output_tokens,seed:42}' > "$manifest"

  if ! docker image inspect "$image" >/dev/null 2>&1; then
    info "Pulling GuideLLM ${image}..."
    docker pull "$image" || die "Could not pull GuideLLM image: $image"
  fi
  info "Running GuideLLM..."
  "${docker_args[@]}" "${guidellm_args[@]}" \
    || die "GuideLLM benchmark failed" "Partial results remain in ${host_output_dir}."
  info "Benchmark complete: ${host_output_dir}"
}
