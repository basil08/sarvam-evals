#!/bin/bash
# One-time Runpod setup for Sarvam 30B red team evals.
#
# Usage:
#   bash scripts/setup_runpod.sh [OPTIONS]
#
# Options:
#   --cuda-arch ARCH   CUDA compute capability to build for (default: 89)
#                        89  — RTX 4090 / RTX 5090 (avoids sm_120 MXFP4 ptxas bug)
#                        80  — A100
#                        90  — H100
#                        120 — RTX 5090 native (only if CUDA toolkit >= 12.8)
#   --hf-token TOKEN   HuggingFace access token (required if model repo is gated)
#
# What this installs:
#   1. System build deps (cmake, gcc, curl, ccache)
#   2. Patched llama.cpp (sumitchatterjee13/llama.cpp @ add-sarvam-moe) → llama-server binary
#   3. HuggingFace CLI → Sarvam 30B GGUF weights (~18.8 GB, sarvamai/sarvam-30b-gguf)
#   4. Node.js 22.22.0 (nvm) + promptfoo 0.121.11
#   5. Python requests (for compare_judges.py / reasoning_audit.py)
#
# Idempotent: each step checks whether it's already done before running.
# Re-running after a partial failure is safe.
#
# After this script completes, start the server with:
#   bash /workspace/sarvam-evals/scripts/start_server_runpod.sh

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────

CUDA_ARCH="89"
HF_TOKEN=""

NODE_VERSION="22.22.0"
PROMPTFOO_VERSION="0.121.11"
LLAMA_REPO="https://github.com/sumitchatterjee13/llama.cpp.git"
LLAMA_BRANCH="add-sarvam-moe"
HF_MODEL="sarvamai/sarvam-30b-gguf"

LLAMA_SRC="/workspace/llama.cpp"
LLAMA_BUILD="/workspace/llama-build"
MODEL_DIR="/workspace/models/sarvam-30b-gguf"

# ── Arg parsing ───────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cuda-arch)
      CUDA_ARCH="$2"; shift 2 ;;
    --hf-token)
      HF_TOKEN="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: bash setup_runpod.sh [--cuda-arch ARCH] [--hf-token TOKEN]"
      exit 1 ;;
  esac
done

# ── Logging ───────────────────────────────────────────────────────────────────

LOG="/workspace/setup_runpod.log"
mkdir -p /workspace
exec > >(while IFS= read -r line; do echo "[$(date '+%H:%M:%S')] $line"; done | tee -a "$LOG") 2>&1

step() { echo ""; echo "━━━ $* ━━━"; }
ok()   { echo "  ✓ $*"; }
skip() { echo "  – $* (already done, skipping)"; }

echo "════════════════════════════════════════════"
echo "  Runpod setup — $(date)"
echo "  CUDA arch target : sm_$CUDA_ARCH"
echo "  HF token         : ${HF_TOKEN:+set}${HF_TOKEN:-not set}"
echo "════════════════════════════════════════════"

# ── Step 1: System deps ───────────────────────────────────────────────────────

step "1/5 System dependencies"
apt-get update -qq
apt-get install -y -qq \
  cmake \
  build-essential \
  git \
  curl \
  libcurl4-openssl-dev \
  ca-certificates \
  ccache
ok "apt packages installed"

# libcuda.so.1 stub — needed for link-time CUDA symbol resolution.
# Only the symlink; do NOT add stubs dir to ldconfig (breaks runtime NVIDIA driver).
if [ ! -f /usr/local/cuda/lib64/stubs/libcuda.so.1 ]; then
  ln -sf /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/stubs/libcuda.so.1
  ok "libcuda.so.1 stub created"
else
  skip "libcuda.so.1 stub"
fi

# ── Step 2: Build llama-server ────────────────────────────────────────────────

step "2/5 llama.cpp (patched, $LLAMA_BRANCH branch)"

if [ ! -d "$LLAMA_SRC/.git" ]; then
  echo "Cloning $LLAMA_REPO..."
  git clone --branch "$LLAMA_BRANCH" --depth 1 "$LLAMA_REPO" "$LLAMA_SRC"
  ok "Cloned $LLAMA_REPO @ $LLAMA_BRANCH"
else
  skip "llama.cpp source ($LLAMA_SRC already exists)"
fi

# Verify we're on the right branch
ACTUAL_BRANCH=$(git -C "$LLAMA_SRC" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
if [ "$ACTUAL_BRANCH" != "$LLAMA_BRANCH" ]; then
  echo "WARNING: $LLAMA_SRC is on branch '$ACTUAL_BRANCH', expected '$LLAMA_BRANCH'"
fi

if [ ! -f "$LLAMA_BUILD/bin/llama-server" ]; then
  echo "Configuring cmake (CUDA arch = sm_$CUDA_ARCH)..."
  mkdir -p "$LLAMA_BUILD"
  cmake -B "$LLAMA_BUILD" -S "$LLAMA_SRC" \
    -DGGML_CUDA=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" \
    -DCMAKE_EXE_LINKER_FLAGS="-L/usr/local/cuda/lib64/stubs"

  echo "Building llama-server ($(nproc) cores)..."
  cmake --build "$LLAMA_BUILD" -j"$(nproc)" --target llama-server
  ok "llama-server built → $LLAMA_BUILD/bin/llama-server"
else
  skip "llama-server binary ($LLAMA_BUILD/bin/llama-server already exists)"
fi

# Sanity check
"$LLAMA_BUILD/bin/llama-server" --version 2>&1 | head -1 || true

# ── Step 3: Model weights ─────────────────────────────────────────────────────

step "3/5 Model weights (sarvamai/sarvam-30b-gguf, ~18.8 GB)"

# HuggingFace CLI
if ! command -v hf &>/dev/null; then
  echo "Installing HuggingFace CLI..."
  curl -LsSf https://hf.co/cli/install.sh | bash
  # Add to PATH for the rest of this script
  export PATH="$HOME/.local/bin:$PATH"
  ok "HuggingFace CLI installed"
else
  skip "HuggingFace CLI ($(hf --version 2>/dev/null || echo 'hf found'))"
  export PATH="$HOME/.local/bin:$PATH"
fi

# Download model (hf download resumes interrupted transfers automatically)
FIRST_SHARD="$MODEL_DIR/sarvam-30b-Q4_K_M.gguf-00001-of-00006.gguf"
if [ -f "$FIRST_SHARD" ]; then
  skip "Model weights ($FIRST_SHARD exists)"
else
  echo "Downloading $HF_MODEL → $MODEL_DIR"
  echo "This will take 20–40 min depending on bandwidth."
  mkdir -p "$MODEL_DIR"
  if [ -n "$HF_TOKEN" ]; then
    hf download "$HF_MODEL" --local-dir "$MODEL_DIR" --token "$HF_TOKEN"
  else
    hf download "$HF_MODEL" --local-dir "$MODEL_DIR"
  fi
  ok "Model weights downloaded"
fi

# Verify all 6 shards present
SHARD_COUNT=$(ls "$MODEL_DIR"/*.gguf 2>/dev/null | wc -l)
if [ "$SHARD_COUNT" -lt 6 ]; then
  echo "WARNING: only $SHARD_COUNT GGUF shard(s) found in $MODEL_DIR — expected 6"
else
  ok "All $SHARD_COUNT GGUF shards present"
fi

# ── Step 4: Node.js + promptfoo ───────────────────────────────────────────────

step "4/5 Node.js $NODE_VERSION + promptfoo $PROMPTFOO_VERSION"

export NVM_DIR="$HOME/.nvm"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  echo "Installing nvm..."
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  ok "nvm installed"
fi
# shellcheck source=/dev/null
source "$NVM_DIR/nvm.sh"

if ! node --version 2>/dev/null | grep -q "$NODE_VERSION"; then
  echo "Installing Node.js $NODE_VERSION..."
  nvm install "$NODE_VERSION"
  nvm alias default "$NODE_VERSION"
  ok "Node.js $(node --version) installed"
else
  skip "Node.js $NODE_VERSION"
fi

if ! promptfoo --version 2>/dev/null | grep -q "$PROMPTFOO_VERSION"; then
  echo "Installing promptfoo $PROMPTFOO_VERSION..."
  npm install -g "promptfoo@$PROMPTFOO_VERSION"
  ok "promptfoo $(promptfoo --version) installed"
else
  skip "promptfoo $PROMPTFOO_VERSION"
fi

# ── Step 5: Python deps ───────────────────────────────────────────────────────

step "5/5 Python dependencies"
if python3 -c "import requests" &>/dev/null; then
  skip "requests already importable"
else
  pip install requests -q
  ok "requests installed"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════"
echo "  Setup complete: $(date)"
echo "════════════════════════════════════════════"
echo ""
echo "  llama-server : $LLAMA_BUILD/bin/llama-server"
echo "  Model        : $MODEL_DIR"
echo "  Node.js      : $(node --version 2>/dev/null)"
echo "  promptfoo    : $(promptfoo --version 2>/dev/null)"
echo "  Log          : $LOG"
echo ""
echo "Next steps:"
echo ""
echo "  1. Copy your sarvam-evals configs + scripts to /workspace/sarvam-evals/"
echo "     (rsync from Mac — see WORKLOG 2026-05-25)"
echo ""
echo "  2. Start the server:"
echo "     $LLAMA_BUILD/bin/llama-server \\"
echo "       -m $MODEL_DIR/sarvam-30b-Q4_K_M.gguf-00001-of-00006.gguf \\"
echo "       --n-gpu-layers 999 --ctx-size 32768 --flash-attn on \\"
echo "       --batch-size 512 -t 8 --host 0.0.0.0 --port 8080 \\"
echo "       --reasoning-budget 1024 --reasoning-format deepseek"
echo ""
echo "  3. Run Phase 2 evals:"
echo "     tmux new-session -d -s phase2 \\"
echo "       'cd /workspace/sarvam-evals && bash scripts/run_phase2.sh'"
