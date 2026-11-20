#!/usr/bin/env python3
"""Check actual linked Homebrew USB binaries before relocation/signing."""
import argparse,hashlib,json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def verify(prefix):
 lock=json.loads((ROOT/'dependencies/usb-macos-arm64.lock.json').read_text())
 expected={(x['component'],x['version'],x['member']):x['sha256'] for x in lock['binaries']}
 queue=[prefix/'bin'/x for x in ['idevice_id','ideviceinfo','iproxy']];seen=set();found=set()
 while queue:
  path=queue.pop().resolve()
  if path in seen:continue
  seen.add(path)
  try:parts=path.relative_to(prefix/'Cellar').parts
  except ValueError:raise SystemExit('USB dependency outside pinned Cellar')
  key=(parts[0],parts[1],'/'.join(parts[2:]))
  if key not in expected or hashlib.sha256(path.read_bytes()).hexdigest()!=expected[key]:raise SystemExit('USB lock mismatch: '+path.name)
  found.add(key)
  for line in subprocess.check_output(['otool','-L',str(path)],text=True).splitlines()[1:]:
   dep=line.strip().split(' (')[0]
   if dep.startswith(str(prefix)+'/'):queue.append(Path(dep))
   elif dep.startswith(('/System/','/usr/lib/')):pass
   else:raise SystemExit('Unresolved USB dependency: '+dep)
 if found!=set(expected):raise SystemExit('USB dependency set differs from lock')
 print(f'Verified {len(found)} pinned USB runtime files')
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--prefix',type=Path,default=Path('/opt/homebrew'));a=p.parse_args();verify(a.prefix.resolve())
