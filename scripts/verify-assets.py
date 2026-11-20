#!/usr/bin/env python3
"""Verify local native runtime snapshots without transmitting them."""
from pathlib import Path
import hashlib,json,sys
root=Path(__file__).resolve().parents[1]; manifest=json.loads((root/'docs/assets-manifest.json').read_text())
errors=[]
for a in manifest['assets']:
 p=root/a['path']
 if not p.is_file(): errors.append('MISSING '+a['path'])
 elif hashlib.sha256(p.read_bytes()).hexdigest()!=a['sha256']: errors.append('CHANGED '+a['path'])
for e in errors: print(e)
print(f"Checked {len(manifest['assets'])} assets; {len(errors)} differences (hashes establish identity, not licensing).")
sys.exit(bool(errors))
