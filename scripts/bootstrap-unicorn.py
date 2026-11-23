#!/usr/bin/env python3
"""Fetch the pinned Mac Store proof engine at build time, not on users' first login."""
import argparse, hashlib, json, urllib.request, zipfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', type=Path, required=True)
    args = parser.parse_args()
    lock = json.loads((ROOT/'dependencies/unicorn-macos-arm64.lock.json').read_text())
    args.work.mkdir(parents=True, exist_ok=True)
    archive = args.work/'unicorn.whl'
    if not archive.exists():
        temporary = archive.with_suffix('.part')
        with urllib.request.urlopen(lock['url'], timeout=120) as response, temporary.open('wb') as out:
            while chunk := response.read(1024*1024): out.write(chunk)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != lock['sha256']:
            temporary.unlink()
            raise SystemExit('Unicorn archive SHA-256 mismatch')
        temporary.replace(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != lock['sha256']:
        raise SystemExit('Unicorn archive SHA-256 mismatch')
    with zipfile.ZipFile(archive) as wheel:
        if hashlib.sha256(wheel.read(lock['member'])).hexdigest() != lock['library_sha256']:
            raise SystemExit('Unicorn library SHA-256 mismatch')
    print('Verified pinned Unicorn 2.1.4 archive and arm64 library')

if __name__ == '__main__': main()
