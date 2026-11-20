#!/usr/bin/env python3
"""Fetch only hash-pinned Apple Silicon Python inputs into a new work directory."""
import argparse,hashlib,json,platform,subprocess,tarfile,urllib.request
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def fetch(item,dest):
 if not dest.exists():
  temporary=dest.with_suffix(dest.suffix+'.part')
  with urllib.request.urlopen(item['url'],timeout=120) as response,temporary.open('wb') as out:
   while chunk:=response.read(1024*1024):out.write(chunk)
  if hashlib.sha256(temporary.read_bytes()).hexdigest()!=item['sha256']:
   temporary.unlink();raise SystemExit('SHA-256 mismatch: '+dest.name)
  temporary.rename(dest)
 if hashlib.sha256(dest.read_bytes()).hexdigest()!=item['sha256']:raise SystemExit('SHA-256 mismatch: '+dest.name)
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--work',type=Path,required=True);a=p.parse_args()
 if platform.system()!='Darwin' or platform.machine()!='arm64':raise SystemExit('Requires native macOS arm64')
 w=a.work.resolve();w.mkdir(parents=True,exist_ok=True);downloads=w/'downloads';downloads.mkdir(exist_ok=True)
 runtime=json.loads((ROOT/'dependencies/python-runtime.lock.json').read_text());wheels=json.loads((ROOT/'dependencies/python-macos-arm64.lock.json').read_text())['wheels']
 archive=downloads/'cpython.tar.gz';fetch(runtime,archive)
 for item in wheels:fetch(item,downloads/item['filename'])
 if (w/'python').exists() or (w/'packages').exists():raise SystemExit('Output python/packages already exists; use a new work directory')
 with tarfile.open(archive) as tar:tar.extractall(w,filter='data')
 subprocess.run([str(w/'python/bin/python3'),'-I','-m','pip','--isolated','install','--no-index','--no-cache-dir','--require-hashes','--find-links',str(downloads),'--target',str(w/'packages'),'-r',str(ROOT/'dependencies/requirements-macos-arm64.lock')],check=True)
 # -I disables host/user imports; explicitly prepend only our verified install.
 check='import sys;sys.path.insert(0,sys.argv[1]);import cryptography,cffi,pycparser;from cryptography.hazmat.primitives.ciphers import Cipher,algorithms,modes;assert Cipher(algorithms.AES(bytes(16)),modes.ECB()).encryptor().update(bytes(16)).hex()=="66e94bd4ef8a2c3b884cfa59ca342b2e";print(cryptography.__version__,cffi.__version__,pycparser.__version__,"AES passed")'
 subprocess.run([str(w/'python/bin/python3'),'-I','-c',check,str(w/'packages')],check=True)
 print('Python:',w/'python');print('Packages:',w/'packages')
if __name__=='__main__':main()
