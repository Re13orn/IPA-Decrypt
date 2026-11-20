#!/usr/bin/env python3
"""Import fixed local-only inputs, never fetch or authorize redistribution."""
import argparse,hashlib,json,shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--from',dest='origin',required=True,type=Path)
p.add_argument('--allow-unreviewed-local-only',action='store_true',required=True)
a=p.parse_args()
rows=json.loads((ROOT/'dependencies/external-assets.lock.json').read_text())['assets']
# Validate the entire set before writing anything.
for row in rows:
 src=a.origin/row['path'];dest=ROOT/row['path']
 dest.resolve().relative_to(ROOT)
 if not src.is_file() or hashlib.sha256(src.read_bytes()).hexdigest()!=row['sha256']:
  raise SystemExit('Missing or changed input: '+row['path'])
for row in rows:
 src=a.origin/row['path'];dest=ROOT/row['path'];dest.parent.mkdir(parents=True,exist_ok=True)
 if src.resolve()!=dest.resolve():shutil.copy2(src,dest)
print(f'Imported {len(rows)} fixed inputs for LOCAL validation only; redistribution remains blocked.')
