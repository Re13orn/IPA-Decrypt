#!/usr/bin/env python3
"""Export clean source only; no publication, Git history or local binary assets."""
from pathlib import Path
import subprocess,sys,zipfile
from source_files import ROOT,files
subprocess.run([sys.executable,str(ROOT/'scripts/check-source.py')],check=True)
out=ROOT/'dist/IPA-Decrypt-source-preparation.zip';out.parent.mkdir(parents=True,exist_ok=True)
with zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED) as z:
 for p in files(): z.write(p,Path('IPA-Decrypt')/p.relative_to(ROOT))
with zipfile.ZipFile(out) as z:
 assert z.testzip() is None
print(out)
print('Source preparation only; excluded resources must be restored/rebuilt; see OPEN_SOURCE_READINESS.md.')
