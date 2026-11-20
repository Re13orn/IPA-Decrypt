#!/usr/bin/env python3
"""Check the pinned upstream runtime without executing it or contacting Apple."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1] / "App" / "NativeStoreRuntime"
manifest = json.loads((root / "PROVENANCE.json").read_text())
for name, expected in manifest["sha256"].items():
    if Path(name).name != name:
        raise SystemExit("Invalid resource name")
    actual = hashlib.sha256((root / name).read_bytes()).hexdigest()
    if actual != expected:
        raise SystemExit(f"Runtime checksum mismatch: {name}")
print(f"Verified {len(manifest['sha256'])} pinned runtime resources")
