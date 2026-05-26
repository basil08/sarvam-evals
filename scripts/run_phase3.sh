#!/bin/bash
# Phase 3 overnight runner — Comparative Safety Study
#
# Runs all 3 comparison models (Qwen3-32B, DeepSeek-R1-32B, Gemma-3-27B) sequentially.
# For each model:
#   1. Download GGUF (skip if already present)
#   2. Start llama-server
#   3. Run Phase 1 mirror eval (same plugins/strategies as Sarvam)
#   4. Run industry standard benchmarks (harmbench, donotanswer, xstest)
#   5. Run Indic custom benchmark
#   6. Run compare_judges.py on all results
#   7. Stop server
# After all models:
#   8. Run multi-model reasoning_audit.py (CoT leakage cross-comparison)
#   9. Print summary
#
# Usage (from /workspace/sarvam-evals, in tmux):
#   tmux new-session -d -s phase3 'cd /workspace/sarvam-evals && bash scripts/run_phase3.sh'
#
# To skip a model (already done), its output JSON must exist.
# Safe to re-run — all steps check for existing outputs.
#
# Prerequisites:
#   - setup_runpod.sh completed (llama-server binary, HF CLI, Node.js, promptfoo)
#   - .env contains ANTHROPIC_API_KEY
#   - sarvam-evals configs + scripts synced from Mac

set -uo pipefail

WORKDIR="/workspace/sarvam-evals"
PYTHON="python3"
LOG="$WORKDIR/output/phase3_run.log"
LLAMA_SERVER="/workspace/llama-build/bin/llama-server"
SERVER_PID=""

cd "$WORKDIR"
mkdir -p output

exec > >(while IFS= read -r line; do echo "[$(date '+%H:%M:%S')] $line"; done | tee -a "$LOG") 2>&1

echo "════════════════════════════════════════════"
echo "  Phase 3 Comparative Study — $(date)"
echo "════════════════════════════════════════════"

# ── Bootstrap ─────────────────────────────────────────────────────────────────

export ANTHROPIC_API_KEY
ANTHROPIC_API_KEY=$(grep ANTHROPIC_API_KEY .env | cut -d= -f2)
[ -z "$ANTHROPIC_API_KEY" ] && { echo "ERROR: ANTHROPIC_API_KEY not in .env"; exit 1; }

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
nvm use 22.22.0 2>/dev/null || true
export PATH="$HOME/.local/bin:$PATH"   # HF CLI

$PYTHON -c "import requests" 2>/dev/null || pip install requests -q

# ── Helpers ───────────────────────────────────────────────────────────────────

MODELS_OK=()
MODELS_FAILED=()

wait_for_server() {
  echo "Waiting for server on :8080..."
  for i in $(seq 1 60); do
    if curl -sf http://localhost:8080/v1/models > /dev/null 2>&1; then
      echo "Server ready (${i}×2s elapsed)"
      return 0
    fi
    sleep 2
  done
  echo "ERROR: Server did not become ready after 120s"
  return 1
}

start_server() {
  local model_file="$1"
  local reasoning="$2"   # "true" or "false"

  echo "Starting llama-server for $model_file..."

  local cmd=(
    "$LLAMA_SERVER"
    -m "$model_file"
    --n-gpu-layers 999
    --ctx-size 32768
    --flash-attn on
    --batch-size 512
    -t 8
    --host 0.0.0.0
    --port 8080
  )
  if [ "$reasoning" = "true" ]; then
    cmd+=(--reasoning-format deepseek)
    # Note: no --reasoning-budget (Sarvam-specific patch only)
  fi

  "${cmd[@]}" &
  SERVER_PID=$!
  echo "Server PID: $SERVER_PID"
  wait_for_server
}

stop_server() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "Stopping server (PID $SERVER_PID)..."
    kill "$SERVER_PID"
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
    sleep 3
  fi
}

run_eval() {
  local name="$1"; local config="$2"; local output="$3"
  if [ -f "$output" ]; then
    echo "SKIP: $output exists"
    return 0
  fi
  echo "Running: promptfoo redteam run --config $config --output $output"
  if promptfoo redteam run --config "$config" --output "$output"; then
    echo "Done: $output"
  else
    echo "WARN: eval failed for $name (exit $?)"
    return 1
  fi
}

run_judges() {
  local input="$1"
  local output="${input%.json}_disagreements.md"
  [ -f "$output" ] && { echo "SKIP: $output exists"; return 0; }
  echo "Running compare_judges.py → $output"
  $PYTHON scripts/compare_judges.py --input "$input" --output "$output" || \
    echo "WARN: compare_judges failed for $input"
}

patch_target_label() {
  # Patch the target label in benchmarks/indic-bench configs at runtime.
  # promptfoo uses the label in its report — we want it to reflect which model ran.
  local config="$1"; local label="$2"; local tmpfile="${config%.yaml}_${label}.yaml"
  sed "s/Current model (set by run_phase3.sh)/$label/g" "$config" > "$tmpfile"
  echo "$tmpfile"
}

run_model() {
  local slug="$1"         # e.g. qwen3-32b
  local label="$2"        # e.g. "Qwen3-32B Q4_K_M"
  local model_dir="$3"    # e.g. /workspace/models/qwen3-32b
  local quant="$4"        # e.g. Q4_K_M or Q5_K_M
  local reasoning="$5"    # true / false
  local phase1_config="$6"

  echo ""
  echo "════════════════════════════════════════════"
  echo "  Model: $label"
  echo "  Start: $(date '+%H:%M:%S')"
  echo "════════════════════════════════════════════"

  # Find GGUF
  local gguf
  gguf=$(find "$model_dir" -name "*${quant}*.gguf" 2>/dev/null | head -1)
  if [ -z "$gguf" ]; then
    echo "Downloading $slug..."
    bash scripts/setup_model.sh --model "$slug" || {
      echo "ERROR: Could not download $slug — skipping"
      MODELS_FAILED+=("$slug (download)")
      return
    }
    gguf=$(find "$model_dir" -name "*${quant}*.gguf" | head -1)
  fi
  echo "GGUF: $gguf"

  start_server "$gguf" "$reasoning"

  local out_prefix="output/${slug}"

  # Phase 1 mirror eval
  run_eval "$label phase1" "$phase1_config" "${out_prefix}_results.json"
  run_judges "${out_prefix}_results.json"

  # Industry benchmarks
  local bench_config
  bench_config=$(patch_target_label "promptfooconfig.benchmarks.yaml" "$label")
  run_eval "$label benchmarks" "$bench_config" "${out_prefix}_benchmarks.json"
  run_judges "${out_prefix}_benchmarks.json"
  rm -f "$bench_config"

  # Indic benchmark
  local indic_config
  indic_config=$(patch_target_label "promptfooconfig.indic-bench.yaml" "$label")
  run_eval "$label indic-bench" "$indic_config" "${out_prefix}_indic.json"
  run_judges "${out_prefix}_indic.json"
  rm -f "$indic_config"

  stop_server

  MODELS_OK+=("$slug")
  echo "$label done: $(date '+%H:%M:%S')"
}

# Trap to ensure server is killed on script exit
trap 'stop_server' EXIT INT TERM

# ── Run each comparison model ─────────────────────────────────────────────────

run_model \
  "qwen3-32b" \
  "Qwen3-32B Q4_K_M" \
  "/workspace/models/qwen3-32b" \
  "Q4_K_M" \
  "true" \
  "promptfooconfig.qwen3.yaml"

run_model \
  "deepseek-r1-32b" \
  "DeepSeek-R1-Distill-Qwen-32B Q4_K_M" \
  "/workspace/models/deepseek-r1-32b" \
  "Q4_K_M" \
  "true" \
  "promptfooconfig.deepseek-r1.yaml"

run_model \
  "gemma3-27b" \
  "Gemma-3-27B-IT Q5_K_M" \
  "/workspace/models/gemma3-27b" \
  "Q5_K_M" \
  "false" \
  "promptfooconfig.gemma3.yaml"

# ── Multi-model reasoning audit ───────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════"
echo "  Multi-model CoT Leakage Audit"
echo "════════════════════════════════════════════"

AUDIT_INPUTS=()
for f in \
  output/hindi_results.json \
  output/english_results_v2.json \
  output/qwen3-32b_results.json \
  output/deepseek-r1-32b_results.json \
  output/gemma3-27b_results.json; do
  [ -f "$f" ] && AUDIT_INPUTS+=(--input "$f")
done

if [ ${#AUDIT_INPUTS[@]} -gt 0 ]; then
  $PYTHON scripts/reasoning_audit.py \
    "${AUDIT_INPUTS[@]}" \
    --output output/phase3_reasoning_audit.md \
    --compare-models || echo "WARN: reasoning_audit failed"
else
  echo "WARN: no result files found for reasoning audit"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════"
echo "  Phase 3 complete: $(date)"
echo "════════════════════════════════════════════"
echo ""
echo "Models OK  (${#MODELS_OK[@]}): ${MODELS_OK[*]:-none}"
echo "Models ERR (${#MODELS_FAILED[@]}): ${MODELS_FAILED[*]:-none}"
echo ""
echo "Results:"
ls -lh output/*.json output/*.md 2>/dev/null | awk '{print $5, $9}'
echo ""
echo "Next:"
echo "  promptfoo redteam report"
echo "  rsync output/ back to Mac before stopping pod"
