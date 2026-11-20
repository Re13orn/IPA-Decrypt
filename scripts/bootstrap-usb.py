#!/usr/bin/env python3
"""Build the pinned USB runtime for macOS 15 arm64, without changing Homebrew."""
import argparse, hashlib, json, os, subprocess, tarfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', type=Path, required=True)
    args = parser.parse_args()
    work = args.work.resolve(); work.mkdir(parents=True, exist_ok=True)
    prefix = work / 'prefix'; prefix.mkdir(exist_ok=True)
    lock_path = ROOT / 'dependencies/usb-macos-arm64.lock.json'
    lock = json.loads(lock_path.read_text())
    components = {item['name']: item for item in lock['components']}
    env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET='15.0', CFLAGS='-O2 -arch arm64 -mmacosx-version-min=15.0', CXXFLAGS='-O2 -arch arm64 -mmacosx-version-min=15.0', LDFLAGS=f'-arch arm64 -mmacosx-version-min=15.0 -L{prefix}/lib', CPPFLAGS=f'-I{prefix}/include', PKG_CONFIG_PATH=str(prefix / 'lib/pkgconfig'))
    def run(*cmd, cwd):
        subprocess.run([str(x) for x in cmd], cwd=cwd, env=env, check=True)
    for name in ['openssl@3', 'libplist', 'libimobiledevice-glue', 'libusbmuxd', 'libimobiledevice']:
        item = components[name]; archive = work / item['source_url'].rsplit('/', 1)[-1]
        if not archive.exists():
            run('curl', '-fL', '--retry', '3', '-o', archive, item['source_url'], cwd=work)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != item['source_sha256']:
            raise SystemExit('Source checksum mismatch: ' + name)
        with tarfile.open(archive) as source:
            source.extractall(work / 'source', filter='data')
        dirname = ('openssl-' if name == 'openssl@3' else name + '-') + item['version']
        directory = work / 'source' / dirname
        if name == 'openssl@3':
            run('./Configure', 'darwin64-arm64-cc', 'shared', 'no-tests', f'--prefix={prefix}', f'--openssldir={prefix}/ssl', cwd=directory)
            run('make', '-j6', cwd=directory); run('make', 'install_sw', cwd=directory)
        else:
            flags = ['--disable-static']
            if name in ['libplist', 'libimobiledevice']: flags += ['--without-cython']
            run('./configure', f'--prefix={prefix}', *flags, cwd=directory)
            run('make', '-j6', cwd=directory); run('make', 'install', cwd=directory)
    binaries = []
    for item in lock['binaries']:
        member = item['member']; file = prefix / member
        binaries.append({'member': member, 'sha256': hashlib.sha256(file.read_bytes()).hexdigest()})
    receipt = {'schema': 1, 'minimum_os': '15.0', 'source_lock_sha256': hashlib.sha256(lock_path.read_bytes()).hexdigest(), 'binaries': binaries}
    (prefix / 'build-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(prefix)
if __name__ == '__main__': main()
