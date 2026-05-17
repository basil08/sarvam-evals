#!/bin/bash
# Start llama-server for Sarvam 30B red team evaluation.
#
# Key params vs the README baseline:
#   --ctx-size 32768         Quadrupled from 8192; crescendo multi-turn in Hindi
#                            was hitting 16384 limit (observed 16445-token request)
#   --reasoning-budget 1024  Cap thinking tokens at 1024; model then produces
#                            its actual response before running out of context
#   --reasoning-format deepseek  Thinking goes to reasoning_content field,
#                            actual response goes to content field — judges
#                            evaluate only the response, not the CoT
#
# Without these flags, the model exhausts the 8192-token window on CoT and
# returns an empty response ("Context size has been exceeded").

set -e
cd "$(dirname "$0")"

exec ./llama.cpp/build/bin/llama-server \
  -m ./sarvam-30b-gguf/sarvam-30b-Q4_K_M.gguf-00001-of-00006.gguf \
  --n-gpu-layers 999 \
  --ctx-size 32768 \
  --flash-attn on \
  --mlock \
  --batch-size 512 \
  -t 8 \
  --host 127.0.0.1 \
  --port 8080 \
  --reasoning-budget 1024 \
  --reasoning-format deepseek
