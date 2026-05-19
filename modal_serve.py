"""
Modal deployment: Sarvam 30B llama-server (patched llama.cpp, CUDA).

Deploy:   modal deploy modal_serve.py
Endpoint: modal serve modal_serve.py  (ephemeral, for testing)
"""
import modal
import subprocess

app = modal.App("sarvam-llama-server")

MODEL_VOLUME = modal.Volume.from_name("sarvam-model-weights", create_if_missing=True)
MODEL_DIR = "/models"

# Build image: CUDA toolkit + compile patched llama.cpp from source.
# Cannot use the official ghcr.io/ggerganov/llama.cpp image — this build has
# Sarvam-specific patches (--reasoning-budget, --reasoning-format deepseek).
image = (
    modal.Image.from_registry(
        "nvidia/cuda:12.4.1-devel-ubuntu22.04",
        add_python="3.11",
    )
    .apt_install(
        "build-essential",
        "cmake",
        "git",
        "libcurl4-openssl-dev",
        "ca-certificates",
        "ccache",
    )
    .add_local_dir(
        # copy=True required: run_commands (cmake) must execute after this step.
        # Without it Modal defers file injection to container startup, blocking build steps.
        local_path="llama.cpp",
        remote_path="/build/llama.cpp",
        copy=True,
        ignore=[
            ".git",
            "build",
            "**/__pycache__",
            "**/*.pyc",
            "models",
        ],
    )
    .run_commands(
        # -DGGML_CUDA=ON: enable CUDA backend
        # separate build dir keeps source tree clean
        "cmake -B /opt/llama-build -S /build/llama.cpp"
        " -DGGML_CUDA=ON"
        " -DCMAKE_BUILD_TYPE=Release",
        "cmake --build /opt/llama-build -j$(nproc) --target llama-server",
        "cp /opt/llama-build/bin/llama-server /usr/local/bin/llama-server",
    )
)


@app.function(
    image=image,
    gpu="A100-40GB",  # 1555 GB/s bandwidth vs L40S's 864 GB/s — ~1.8x faster at same price
    volumes={MODEL_DIR: MODEL_VOLUME},
    timeout=3600,
    scaledown_window=300,  # keep warm 5 min between promptfoo requests
)
@modal.web_server(port=8080)
def serve():
    # --host 0.0.0.0: Modal proxies external traffic; 127.0.0.1 would block it
    # --mlock removed: all layers offloaded to GPU (--n-gpu-layers 999), no need
    subprocess.run(
        [
            "llama-server",
            "-m", f"{MODEL_DIR}/sarvam-30b-Q4_K_M.gguf-00001-of-00006.gguf",
            "--n-gpu-layers", "999",
            "--ctx-size", "32768",
            "--flash-attn", "on",
            "--batch-size", "512",
            "-t", "8",
            "--host", "0.0.0.0",
            "--port", "8080",
            "--reasoning-budget", "1024",
            "--reasoning-format", "deepseek",
        ],
        check=True,
    )
