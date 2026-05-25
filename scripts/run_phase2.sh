#!/bin/bash
# Phase 2 overnight eval runner — Runpod
#
# Runs all 6 waves sequentially against llama-server on localhost:8080.
# promptfoo and python3 both run on the pod (no Mac required).
#
# Usage (from /workspace/sarvam-evals):
#   bash scripts/run_phase2.sh
#   bash scripts/run_phase2.sh 2>&1 | tee output/phase2_run.log   # explicit log
#
# Each wave is skipped if its output JSON already exists — safe to re-run
# after a partial failure without re-running completed waves.
#
# Before running:
#   - llama-server must be running on localhost:8080
#   - .env must contain ANTHROPIC_API_KEY=...
#   - pip install requests (for compare_judges.py)
#   - nvm use 22.22.0 && npm install -g promptfoo@0.121.11

set -uo pipefail   # -u: catch undefined vars, pipefail: pipes fail on error
                   # intentionally NO -e: wave failures are logged, not fatal

# ── Config ────────────────────────────────────────────────────────────────────

WORKDIR="/workspace/sarvam-evals"
PYTHON="python3"
LOG="$WORKDIR/output/phase2_run.log"

# ── Bootstrap ─────────────────────────────────────────────────────────────────

cd "$WORKDIR"
mkdir -p output

# Timestamp every line going to the log
exec > >(while IFS= read -r line; do echo "[$(date '+%H:%M:%S')] $line"; done | tee -a "$LOG") 2>&1

echo "========================================"
echo "Phase 2 eval starting: $(date)"
echo "========================================"

# API key
export ANTHROPIC_API_KEY
ANTHROPIC_API_KEY=$(grep ANTHROPIC_API_KEY .env | cut -d= -f2)
if [ -z "$ANTHROPIC_API_KEY" ]; then
  echo "ERROR: ANTHROPIC_API_KEY not found in .env — aborting"
  exit 1
fi
echo "ANTHROPIC_API_KEY loaded."

# Node.js (nvm)
export NVM_DIR="$HOME/.nvm"
# shellcheck source=/dev/null
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
nvm use 22.22.0 2>/dev/null && echo "Node $(node --version)" || echo "WARN: nvm use failed — using system node $(node --version 2>/dev/null || echo 'not found')"

# Python deps
$PYTHON -c "import requests" 2>/dev/null || { echo "Installing requests..."; pip install requests -q; }

# Server check
echo "Checking llama-server..."
if ! curl -sf http://localhost:8080/v1/models > /dev/null; then
  echo "ERROR: llama-server not responding on :8080 — aborting"
  exit 1
fi
echo "Server OK."

# ── Helpers ───────────────────────────────────────────────────────────────────

WAVES_OK=()
WAVES_FAILED=()

run_wave() {
  local name="$1"
  local config="$2"
  local output="$3"

  echo ""
  echo "════════════════════════════════════════"
  echo "  $name — start: $(date '+%H:%M:%S')"
  echo "════════════════════════════════════════"

  # --- promptfoo eval (skip if output already exists) ---
  if [ -f "$output" ]; then
    echo "SKIP: $output already exists — jumping to compare_judges"
  else
    echo "Running: promptfoo redteam run --config $config --output $output"
    if promptfoo redteam run --config "$config" --output "$output"; then
      echo "$name eval done."
    else
      echo "ERROR: $name eval failed (exit $?) — skipping compare_judges for this wave"
      WAVES_FAILED+=("$name (eval)")
      return
    fi
  fi

  # --- compare_judges.py ---
  local disagree="${output%.json}_disagreements.md"
  echo "Running compare_judges.py → $disagree"
  if $PYTHON scripts/compare_judges.py --input "$output" --output "$disagree"; then
    echo "$name compare_judges done."
  else
    echo "WARN: compare_judges.py failed for $name (exit $?) — continuing"
    WAVES_FAILED+=("$name (compare_judges)")
  fi

  WAVES_OK+=("$name")
  echo "$name complete: $(date '+%H:%M:%S')"
}

# ── Waves ─────────────────────────────────────────────────────────────────────

# Wave A — English Phase 1 re-run (jailbreak:meta removed, clean baseline)
run_wave \
  "Wave A — English re-run" \
  "promptfooconfig.yaml" \
  "output/english_results_v2.json"

# Wave B — Bias & India-specific (race, gender, hate)
run_wave \
  "Wave B — Bias" \
  "promptfooconfig.bias.yaml" \
  "output/bias_results.json"

# Wave C — Expanded harm + dataset coverage (cybercrime, sexual-content, harmbench, beavertails)
run_wave \
  "Wave C — Expanded Harm" \
  "promptfooconfig.phase2-harm.yaml" \
  "output/phase2_harm_results.json"

# Wave D — Indic language expansion (Tamil, Telugu, Bengali)
run_wave \
  "Wave D — Indic Languages" \
  "promptfooconfig.indic.yaml" \
  "output/indic_results.json"

# Wave E — Agentic tool-use (shell-injection, sql-injection, ssrf, bola, bfla, etc.)
run_wave \
  "Wave E — Agentic" \
  "promptfooconfig.agentic.yaml" \
  "output/agentic_results.json"

# Wave F — Reasoning chain leakage audit (no eval, post-processes existing outputs)
echo ""
echo "════════════════════════════════════════"
echo "  Wave F — Reasoning Chain Audit"
echo "════════════════════════════════════════"

# Collect all result JSONs that exist
AUDIT_INPUTS=()
for f in \
  output/hindi_results.json \
  output/english_results_v2.json \
  output/bias_results.json \
  output/phase2_harm_results.json \
  output/indic_results.json \
  output/agentic_results.json; do
  [ -f "$f" ] && AUDIT_INPUTS+=(--input "$f")
done

if [ ${#AUDIT_INPUTS[@]} -eq 0 ]; then
  echo "WARN: no result files found for reasoning audit — skipping Wave F"
  WAVES_FAILED+=("Wave F (no inputs)")
else
  echo "Auditing: ${AUDIT_INPUTS[*]}"
  if $PYTHON scripts/reasoning_audit.py \
      "${AUDIT_INPUTS[@]}" \
      --output output/reasoning_audit.md; then
    echo "Wave F complete."
    WAVES_OK+=("Wave F — Reasoning Audit")
  else
    echo "WARN: reasoning_audit.py failed (exit $?)"
    WAVES_FAILED+=("Wave F (reasoning_audit)")
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "========================================"
echo "Phase 2 complete: $(date)"
echo "========================================"

echo ""
echo "Waves OK  (${#WAVES_OK[@]}): ${WAVES_OK[*]:-none}"
echo "Waves ERR (${#WAVES_FAILED[@]}): ${WAVES_FAILED[*]:-none}"

echo ""
echo "Results:"
ls -lh output/*.json output/*.md 2>/dev/null | awk '{print $5, $9}'

echo ""
echo "Next steps:"
echo "  promptfoo redteam report"
echo "  rsync output/ back to Mac before stopping pod"
