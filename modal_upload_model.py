"""
One-time script: upload Sarvam 30B GGUF shards to Modal Volume.

Run once before first deploy:
    python modal_upload_model.py

~18.8 GB total, takes ~10-20 min depending on upload speed.
"""
import modal
from pathlib import Path

VOLUME_NAME = "sarvam-model-weights"
MODEL_DIR = Path("sarvam-30b-gguf")

volume = modal.Volume.from_name(VOLUME_NAME, create_if_missing=True)

shards = sorted(MODEL_DIR.glob("*.gguf*"))
if not shards:
    raise FileNotFoundError(f"No GGUF files found in {MODEL_DIR.resolve()}")

total_gb = sum(s.stat().st_size for s in shards) / 1e9
print(f"Uploading {len(shards)} shards ({total_gb:.1f} GB) to volume '{VOLUME_NAME}'...\n")

with volume.batch_upload() as batch:
    for shard in shards:
        size_gb = shard.stat().st_size / 1e9
        print(f"  queuing {shard.name} ({size_gb:.1f} GB)")
        batch.put_file(str(shard), shard.name)

print("\nVerifying volume contents:")
for entry in volume.listdir("/"):
    print(f"  {entry.path}")

print(f"\nDone. Deploy with: modal deploy modal_serve.py")
