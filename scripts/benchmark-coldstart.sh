#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="genai"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$SCRIPT_DIR/../manifests"
TIMEOUT=600
CLEANUP=false
SCALE_TO=2

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Benchmark vLLM cold start vs cached scale-out performance.

Deploys the cached variant (1 replica), waits for it to populate the shared
PVC, then scales out. The new pod reads model weights from the warm cache
instead of re-downloading, demonstrating the caching benefit.

Optionally also runs the nocache variant to show that every pod pays the
full download cost without shared storage.

Options:
  --mode MODE       cached, nocache, or both (default: both)
                      cached  - deploy 1 replica, then scale out and compare
                      nocache - same flow but without PVC caching
                      both    - run nocache first, then cached, print comparison
  --scale-to N      Number of replicas to scale to (default: 2)
  --timeout SECS    Max seconds to wait per phase (default: 600)
  --cleanup         Delete deployments after benchmarking
  -h, --help        Show this help
EOF
  exit 0
}

MODE="both"

while [[ $# -gt 0 ]]; do
  case $1 in
    --mode)     MODE="$2"; shift 2 ;;
    --scale-to) SCALE_TO="$2"; shift 2 ;;
    --timeout)  TIMEOUT="$2"; shift 2 ;;
    --cleanup)  CLEANUP=true; shift ;;
    -h|--help)  usage ;;
    *)          echo "Unknown option: $1"; usage ;;
  esac
done

if [[ "$MODE" != "cached" && "$MODE" != "nocache" && "$MODE" != "both" ]]; then
  echo "Error: --mode must be cached, nocache, or both"
  exit 1
fi

get_pod_name() {
  local label=$1
  kubectl get pods -n "$NAMESPACE" -l "app=$label" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

get_ready_pods() {
  local label=$1
  kubectl get pods -n "$NAMESPACE" -l "app=$label" \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | wc -l | tr -d ' '
}

wait_for_n_ready() {
  local label=$1
  local target=$2
  local deadline=$((SECONDS + TIMEOUT))

  echo "  Waiting for $target pod(s) with app=$label to be Ready..."
  while [[ $SECONDS -lt $deadline ]]; do
    local ready
    ready=$(kubectl get pods -n "$NAMESPACE" -l "app=$label" -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c "True" || true)
    ready=${ready:-0}
    if [[ "$ready" -ge "$target" ]]; then
      return 0
    fi
    sleep 5
  done
  echo "  ERROR: Did not reach $target ready pods within ${TIMEOUT}s"
  return 1
}

stream_pod_logs() {
  local pod_name=$1
  local logfile=$2

  kubectl logs -n "$NAMESPACE" "$pod_name" -c vllm-server --follow 2>/dev/null > "$logfile" &
  echo $!
}

wait_for_log_ready() {
  local logfile=$1
  local deadline=$((SECONDS + TIMEOUT))

  while [[ $SECONDS -lt $deadline ]]; do
    if grep -qE "Uvicorn running|Application startup complete|Started server process" "$logfile" 2>/dev/null; then
      return 0
    fi
    sleep 3
  done
  echo "  ERROR: vLLM did not report ready within ${TIMEOUT}s"
  return 1
}

extract_metrics() {
  local logfile=$1

  local model_load
  model_load=$(grep -oiE "loading model weights took [0-9.]+ ?(s|sec|seconds|GB)" "$logfile" 2>/dev/null | head -1 || true)
  if [[ -z "$model_load" ]]; then
    model_load=$(grep -oiE "model.*(load|weight).*[0-9.]+ ?(s|sec|seconds)" "$logfile" 2>/dev/null | head -1 || true)
  fi
  [[ -z "$model_load" ]] && model_load="N/A"

  local compile_time
  compile_time=$(grep -oiE "(compil(ation|ing|e)|torch.compile).*[0-9.]+ ?(s|sec|seconds)" "$logfile" 2>/dev/null | head -1 || true)
  [[ -z "$compile_time" ]] && compile_time="N/A"

  echo "$model_load|$compile_time"
}

find_new_pod() {
  local label=$1
  shift
  local known_pods=("$@")

  local all_pods
  all_pods=$(kubectl get pods -n "$NAMESPACE" -l "app=$label" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

  for pod in $all_pods; do
    local is_known=false
    for known in "${known_pods[@]}"; do
      if [[ "$pod" == "$known" ]]; then
        is_known=true
        break
      fi
    done
    if [[ "$is_known" == "false" ]]; then
      echo "$pod"
      return 0
    fi
  done
  return 1
}

run_benchmark() {
  local variant=$1
  local manifest label

  if [[ "$variant" == "cached" ]]; then
    manifest="$MANIFESTS_DIR/deploymentgpu.yaml"
    label="vllm-server"
  else
    manifest="$MANIFESTS_DIR/deploymentgpu-nocache.yaml"
    label="vllm-server-nocache"
  fi

  local logfile_first="/tmp/benchmark_${variant}_first_pod.txt"
  local logfile_scaleout="/tmp/benchmark_${variant}_scaleout_pod.txt"
  > "$logfile_first"
  > "$logfile_scaleout"

  echo ""
  echo "=========================================="
  echo "  Benchmarking: $variant"
  echo "=========================================="

  # --- Phase 1: First pod (cold start) ---
  echo ""
  echo "--- Phase 1: First pod (cold start) ---"
  echo ""

  echo "  Cleaning up existing deployment..."
  kubectl delete deployment -n "$NAMESPACE" "$label" --ignore-not-found=true > /dev/null 2>&1
  kubectl wait --for=delete pod -n "$NAMESPACE" -l "app=$label" --timeout=60s 2>/dev/null || true
  sleep 3

  echo "  Deploying 1 replica..."
  local first_start=$SECONDS
  kubectl apply -f "$manifest"

  wait_for_n_ready "$label" 1
  local first_pod
  first_pod=$(get_pod_name "$label")
  local log_pid
  log_pid=$(stream_pod_logs "$first_pod" "$logfile_first")
  wait_for_log_ready "$logfile_first"
  kill "$log_pid" 2>/dev/null || true; wait "$log_pid" 2>/dev/null || true
  local first_wall=$(( SECONDS - first_start ))

  local first_metrics
  first_metrics=$(extract_metrics "$logfile_first")
  local first_model_load first_compile
  first_model_load=$(echo "$first_metrics" | cut -d'|' -f1)
  first_compile=$(echo "$first_metrics" | cut -d'|' -f2)

  echo ""
  echo "  First pod results:"
  echo "    Wall-clock time:    ${first_wall}s"
  echo "    Model loading:      $first_model_load"
  echo "    Torch compilation:  $first_compile"

  # --- Phase 2: Scale out (cached start) ---
  echo ""
  echo "--- Phase 2: Scale out to $SCALE_TO replicas ---"
  echo ""

  local known_pods
  known_pods=$(kubectl get pods -n "$NAMESPACE" -l "app=$label" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
  local known_pods_arr=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && known_pods_arr+=("$line")
  done <<< "$known_pods"

  local scaleout_start=$SECONDS
  kubectl scale deployment -n "$NAMESPACE" "$label" --replicas="$SCALE_TO"

  echo "  Waiting for new pod to appear..."
  local new_pod=""
  local deadline=$((SECONDS + TIMEOUT))
  while [[ $SECONDS -lt $deadline ]]; do
    new_pod=$(find_new_pod "$label" "${known_pods_arr[@]}") && break
    sleep 3
  done

  if [[ -z "$new_pod" ]]; then
    echo "  ERROR: New pod did not appear within ${TIMEOUT}s"
    return 1
  fi
  echo "  New pod: $new_pod"

  # Wait for the new pod's container to be running before streaming logs
  deadline=$((SECONDS + TIMEOUT))
  while [[ $SECONDS -lt $deadline ]]; do
    local phase
    phase=$(kubectl get pod -n "$NAMESPACE" "$new_pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "$phase" == "Running" ]]; then
      break
    fi
    sleep 3
  done

  log_pid=$(stream_pod_logs "$new_pod" "$logfile_scaleout")
  wait_for_log_ready "$logfile_scaleout"
  kill "$log_pid" 2>/dev/null || true; wait "$log_pid" 2>/dev/null || true
  local scaleout_wall=$(( SECONDS - scaleout_start ))

  local scaleout_metrics
  scaleout_metrics=$(extract_metrics "$logfile_scaleout")
  local scaleout_model_load scaleout_compile
  scaleout_model_load=$(echo "$scaleout_metrics" | cut -d'|' -f1)
  scaleout_compile=$(echo "$scaleout_metrics" | cut -d'|' -f2)

  echo ""
  echo "  Scale-out pod results:"
  echo "    Wall-clock time:    ${scaleout_wall}s"
  echo "    Model loading:      $scaleout_model_load"
  echo "    Torch compilation:  $scaleout_compile"

  # --- Summary ---
  echo ""
  echo "  ------------------------------------------"
  printf "  %-25s  %-14s  %-14s\n" "[$variant]" "First Pod" "Scale-out Pod"
  printf "  %-25s  %-14s  %-14s\n" "-------------------------" "--------------" "--------------"
  printf "  %-25s  %-14s  %-14s\n" "Wall-clock time" "${first_wall}s" "${scaleout_wall}s"
  printf "  %-25s  %-14s  %-14s\n" "Model loading" "$first_model_load" "$scaleout_model_load"
  printf "  %-25s  %-14s  %-14s\n" "Torch compilation" "$first_compile" "$scaleout_compile"

  if [[ "$first_wall" -gt 0 && "$scaleout_wall" -gt 0 ]]; then
    local speedup
    speedup=$(awk "BEGIN {printf \"%.1fx\", $first_wall / $scaleout_wall}")
    echo ""
    echo "  Scale-out speedup: ${speedup} faster"
  fi
  echo "  ------------------------------------------"

  # Save for cross-variant comparison
  echo "$first_wall" > "/tmp/benchmark_${variant}_first_wall"
  echo "$scaleout_wall" > "/tmp/benchmark_${variant}_scaleout_wall"
  echo "$first_model_load" > "/tmp/benchmark_${variant}_first_model"
  echo "$scaleout_model_load" > "/tmp/benchmark_${variant}_scaleout_model"

  if [[ "$CLEANUP" == "true" ]]; then
    echo ""
    echo "  Cleaning up deployment..."
    kubectl delete -f "$manifest" --ignore-not-found=true > /dev/null 2>&1
  fi
}

print_comparison() {
  echo ""
  echo "================================================================"
  echo "  Cold Start vs Cached Scale-Out: Full Comparison"
  echo "================================================================"
  echo ""

  local cached_first cached_scaleout nocache_first nocache_scaleout
  cached_first=$(cat /tmp/benchmark_cached_first_wall 2>/dev/null || echo "N/A")
  cached_scaleout=$(cat /tmp/benchmark_cached_scaleout_wall 2>/dev/null || echo "N/A")
  nocache_first=$(cat /tmp/benchmark_nocache_first_wall 2>/dev/null || echo "N/A")
  nocache_scaleout=$(cat /tmp/benchmark_nocache_scaleout_wall 2>/dev/null || echo "N/A")

  printf "  %-28s  %-14s  %-14s\n" "" "No Cache" "With Cache"
  printf "  %-28s  %-14s  %-14s\n" "----------------------------" "--------------" "--------------"
  printf "  %-28s  %-14s  %-14s\n" "First pod (cold start)" "${nocache_first}s" "${cached_first}s"
  printf "  %-28s  %-14s  %-14s\n" "Scale-out pod" "${nocache_scaleout}s" "${cached_scaleout}s"
  echo ""

  if [[ "$nocache_scaleout" =~ ^[0-9]+$ && "$cached_scaleout" =~ ^[0-9]+$ && "$cached_scaleout" -gt 0 ]]; then
    local scaleout_speedup
    scaleout_speedup=$(awk "BEGIN {printf \"%.1fx\", $nocache_scaleout / $cached_scaleout}")
    echo "  Cache scale-out advantage: ${scaleout_speedup} faster than nocache scale-out"
  fi

  if [[ "$cached_first" =~ ^[0-9]+$ && "$cached_scaleout" =~ ^[0-9]+$ && "$cached_scaleout" -gt 0 ]]; then
    local cache_speedup
    cache_speedup=$(awk "BEGIN {printf \"%.1fx\", $cached_first / $cached_scaleout}")
    echo "  Cached first -> scale-out:  ${cache_speedup} faster with warm cache"
  fi

  echo ""
  echo "  Full logs saved to:"
  echo "    /tmp/benchmark_cached_first_pod.txt"
  echo "    /tmp/benchmark_cached_scaleout_pod.txt"
  echo "    /tmp/benchmark_nocache_first_pod.txt"
  echo "    /tmp/benchmark_nocache_scaleout_pod.txt"
  echo ""

  rm -f /tmp/benchmark_*_wall /tmp/benchmark_*_model
}

echo "vLLM Cold Start Benchmark"
echo "Namespace:  $NAMESPACE"
echo "Timeout:    ${TIMEOUT}s"
echo "Scale to:   $SCALE_TO replicas"
echo "Mode:       $MODE"

case $MODE in
  cached)
    run_benchmark "cached"
    ;;
  nocache)
    run_benchmark "nocache"
    ;;
  both)
    run_benchmark "nocache"
    run_benchmark "cached"
    print_comparison
    ;;
esac

echo ""
echo "Done."
