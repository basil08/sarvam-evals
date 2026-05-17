

## run conversation CLI

./build/bin/llama-cli \
  -m ./sarvam-30b-gguf/sarvam-30b-Q4_K_M.gguf-00001-of-00006.gguf \
  --n-gpu-layers 999 \
  --ctx-size 8192 \
  --flash-attn on \
  --mlock \
  --batch-size 512 \
  -t 8 \
  --temp 0.8 \
  --top-p 0.95 \
  -n 2048 \
  -p "You are a helpful assistant." \
  --conversation


## run server for notebook

./build/bin/llama-server \
  -m ./sarvam-30b-gguf/sarvam-30b-Q4_K_M.gguf-00001-of-00006.gguf \
  --n-gpu-layers 999 \
  --ctx-size 8192 \
  --flash-attn on \
  --mlock \
  --batch-size 512 \
  -t 8 \
  --host 127.0.0.1 \
  --port 8080
