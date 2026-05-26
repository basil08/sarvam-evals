#!/bin/bash
# Download a comparison model GGUF and print the server start command.
#
# Usage:
#   bash scripts/setup_model.sh --model <name> [--hf-token TOKEN]
#
# Supported models:
#   qwen3-32b         Qwen/Qwen3-32B-GGUF (Alibaba, China, reasoning)
#   deepseek-r1-32b   bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF (DeepSeek, China, reasoning)
#   gemma3-27b        bartowski/google_gemma-3-27b-it-GGUF (Google, US, non-reasoning)
#
# Downloads Q4_K_M quantization to /workspace/models/<model>/
# Idempotent — skips download if GGUF already present.

set -euo pipefail

MODEL=""
HF_TOKEN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)   MODEL="$2";    shift 2 ;;
    --hf-token) HF_TOKEN="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; echo "Usage: bash setup_model.sh --model <name>"; exit 1 ;;
  esac
done

if [ -z "$MODEL" ]; then
  echo "ERROR: --model required"
  echo "Supported: qwen3-32b, deepseek-r1-32b, gemma3-27b"
  exit 1
fi

# ── Model registry ────────────────────────────────────────────────────────────

case "$MODEL" in
  qwen3-32b)
    HF_REPO="Qwen/Qwen3-32B-GGUF"
    INCLUDE_PATTERN="*Q4_K_M*"
    MODEL_DIR="/workspace/models/qwen3-32b"
    DESCRIPTION="Qwen3-32B (Alibaba, China) — reasoning model"
    IS_REASONING=true
    ;;
  deepseek-r1-32b)
    HF_REPO="bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF"
    INCLUDE_PATTERN="*Q4_K_M*"
    MODEL_DIR="/workspace/models/deepseek-r1-32b"
    DESCRIPTION="DeepSeek-R1-Distill-Qwen-32B (DeepSeek, China) — reasoning model"
    IS_REASONING=true
    ;;
  gemma3-27b)
    HF_REPO="bartowski/google_gemma-3-27b-it-GGUF"
    INCLUDE_PATTERN="*Q4_K_M*"
    MODEL_DIR="/workspace/models/gemma3-27b"
    DESCRIPTION="Gemma-3-27B-IT (Google, US) — non-reasoning baseline"
    IS_REASONING=false
    ;;
  *)
    echo "ERROR: Unknown model '$MODEL'"
    echo "Supported: qwen3-32b, deepseek-r1-32b, gemma3-27b"
    exit 1
    ;;
esac

# ── Bootstrap ─────────────────────────────────────────────────────────────────

LOG="/workspace/setup_${MODEL}.log"
exec > >(while IFS= read -r line; do echo "[$(date '+%H:%M:%S')] $line"; done | tee -a "$LOG") 2>&1

echo "════════════════════════════════════════"
echo "  setup_model.sh — $DESCRIPTION"
echo "  HF repo : $HF_REPO"
echo "  Local   : $MODEL_DIR"
echo "════════════════════════════════════════"

# Ensure hf CLI is on PATH
export PATH="$HOME/.local/bin:$PATH"
if ! command -v hf &>/dev/null; then
  echo "ERROR: HuggingFace CLI (hf) not found. Run setup_runpod.sh first."
  exit 1
fi

# ── Download ──────────────────────────────────────────────────────────────────

# Check if Q4_K_M file is already present
EXISTING=$(find "$MODEL_DIR" -name "*Q4_K_M*.gguf" 2>/dev/null | head -1)
if [ -n "$EXISTING" ]; then
  echo "SKIP: $EXISTING already exists"
  GGUF_FILE="$EXISTING"
else
  echo "Downloading $HF_REPO ($INCLUDE_PATTERN)..."
  echo "This may take 20–40 min depending on file size and bandwidth."
  mkdir -p "$MODEL_DIR"
  if [ -n "$HF_TOKEN" ]; then
    hf download "$HF_REPO" --include "$INCLUDE_PATTERN" --local-dir "$MODEL_DIR" --token "$HF_TOKEN"
  else
    hf download "$HF_REPO" --include "$INCLUDE_PATTERN" --local-dir "$MODEL_DIR"
  fi
  GGUF_FILE=$(find "$MODEL_DIR" -name "*Q4_K_M*.gguf" | head -1)
  if [ -z "$GGUF_FILE" ]; then
    echo "ERROR: No Q4_K_M GGUF found in $MODEL_DIR after download"
    echo "Files present:"
    ls "$MODEL_DIR" || true
    exit 1
  fi
  echo "Downloaded: $GGUF_FILE"
fi

GGUF_SIZE=$(du -sh "$GGUF_FILE" 2>/dev/null | cut -f1)
echo "  File : $GGUF_FILE ($GGUF_SIZE)"

# ── Print server start command ────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════"
echo "  Server start command for $MODEL:"
echo "════════════════════════════════════════"

if [ "$IS_REASONING" = true ]; then
  # Reasoning models: --reasoning-format deepseek extracts <think> tags
  # into reasoning_content field, consistent with Sarvam's output format.
  # Enables reasoning_audit.py to detect CoT leakage across all reasoning models.
  cat <<EOF
/workspace/llama-build/bin/llama-server \\
  -m $GGUF_FILE \\
  --n-gpu-layers 999 \\
  --ctx-size 32768 \\
  --flash-attn on \\
  --batch-size 512 \\
  -t 8 \\
  --host 0.0.0.0 \\
  --port 8080 \\
  --reasoning-format deepseek
  # Note: no --reasoning-budget (Sarvam-specific) and no --mlock (GPU inference)
EOF
else
  # Non-reasoning model: no CoT flags needed
  cat <<EOF
/workspace/llama-build/bin/llama-server \\
  -m $GGUF_FILE \\
  --n-gpu-layers 999 \\
  --ctx-size 32768 \\
  --flash-attn on \\
  --batch-size 512 \\
  -t 8 \\
  --host 0.0.0.0 \\
  --port 8080
  # Non-reasoning model — no CoT flags
EOF
fi

echo ""
echo "Setup complete for $MODEL. Log: $LOG"
