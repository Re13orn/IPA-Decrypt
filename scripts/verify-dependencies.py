#!/usr/bin/env python3
"""Verify pinned source snapshots, archives and lock metadata, without network."""
import hashlib,json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def tree_digest(directory, excluded=()):
 rows=[]
 for p in sorted(directory.rglob('*')):
  rel=p.relative_to(directory).as_posix()
  if any(part in {'.git','__pycache__','.build'} for part in p.parts) or p.name=='.DS_Store' or p.suffix=='.pyc' or any(rel==x or rel.startswith(x+"/") for x in excluded):continue
  if p.is_file():rows.append(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+rel+'\n')
 return hashlib.sha256(''.join(rows).encode()).hexdigest(),len(rows)
def verify():
 data=json.loads((ROOT/'dependencies/sources.lock.json').read_text())
 errors=[]
 for item in data['sources']:
  path=ROOT/item['path']
  digest,count=tree_digest(path,item.get('excluded',[]))
  if digest!=item['tree_sha256'] or count!=item['files']:errors.append(item['name'])
 for item in data['files']:
  path=ROOT/item['path']
  if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest()!=item['sha256']:errors.append(item['path'])
 if errors:raise SystemExit('Dependency verification failed: '+', '.join(errors))
 print(f"Verified {len(data['sources'])} source trees and {len(data['files'])} pinned archives/lock inputs")
if __name__=='__main__':verify()
