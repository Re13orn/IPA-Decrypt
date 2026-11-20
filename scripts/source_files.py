"""One policy for auditing and exporting public source; no symlink traversal."""
from pathlib import Path
import os
import json
ROOT = Path(__file__).resolve().parents[1]
SKIP_DIRS = {'.git', '.build', '.build-work', 'dist', '__pycache__', 'xcuserdata', 'DerivedData', 'PythonPackages'}
BINARY_SUFFIXES = {'.a', '.dylib', '.so', '.wasm', '.ios', '.dmg', '.app', '.p12', '.pfx', '.pem', '.key', '.mobileprovision', '.provisionprofile', '.pyc', '.log'}
EXTERNAL = {item["path"] for item in json.loads((ROOT/"dependencies/external-assets.lock.json").read_text())["assets"]}
def files():
    for current, directories, names in os.walk(ROOT, followlinks=False):
        base=Path(current)
        directories[:]=sorted(d for d in directories if d not in SKIP_DIRS and not d.endswith(('.xcframework','.app'))
                              and not (base.name=='credential-retrieval' and d=='build'))
        for directory in directories:
            if (base/directory).is_symlink():
                raise ValueError(f'Symlinks forbidden in public source: {(base/directory).relative_to(ROOT)}')
        for name in sorted(names):
            p=base/name; rel=p.relative_to(ROOT)
            if str(rel) in EXTERNAL or str(rel)=='apps/macos/Vendor/unfairplay': continue
            if p.is_symlink(): raise ValueError(f'Symlinks forbidden in public source: {rel}')
            if not p.is_file() or p.name=='.DS_Store': continue
            if p.suffix in {'.p12', '.pfx', '.pem', '.key', '.mobileprovision', '.provisionprofile'}:
                raise ValueError(f'Signing/private key file: {rel}')
            if p.suffix in BINARY_SUFFIXES: continue
            if p.name.startswith('.env') and p.name!='.env.example': continue
            if p.name in {'accounts.json','credentials.json'}: raise ValueError(f'Private data: {rel}')
            if p.name=='credential.bin' and '/Tools/Tests/Fixtures/' not in '/'+str(rel):
                raise ValueError(f'Non-fixture credential: {rel}')
            if p.suffix=='.ipa' and '/Tools/Tests/Fixtures/' not in '/'+str(rel):
                raise ValueError(f'Non-fixture IPA: {rel}')
            yield p
