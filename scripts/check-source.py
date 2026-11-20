#!/usr/bin/env python3
"""Check export candidates without printing secret values; not a license audit."""
import hashlib, json, re, sys
from source_files import ROOT, files
# Match personal artifacts and credential material, not protocol field names.
patterns=[('private-key',re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----')),
 ('personal-account',re.compile(rb'(?i)[a-z0-9_.+%-]{1,64}@(?:proton\.me|slowmist\.io|gmail\.com)')),
 ('developer-path',re.compile(rb'/Users/apple/(?:Downloads|workspace|Documents)/')),
 ('signing-profile',re.compile(rb'(?i)<key>DeveloperCertifica[t]es</key>'))]
errors=[]; count=0
fixtures={x['path']:x['sha256'] for x in json.loads((ROOT/'docs/fixture-manifest.json').read_text())['fixtures']}
for p in files():
    count+=1; data=p.read_bytes(); rel=str(p.relative_to(ROOT))
    for name,pattern in patterns:
        if name=='personal-account' and p.name in {'THANKS','AUTHORS','LICENSE'}: continue
        if pattern.search(data): errors.append((name,rel))
    if p.suffix=='.ipa' or p.name=='credential.bin':
        # Synthetic key used in the pre-existing fixture; reject replacement by real data.
        digest=hashlib.sha256(data).hexdigest()
        if digest!=fixtures.get(rel): errors.append(('changed-or-unlisted-fixture',rel))
for name,path in errors: print(f'FAIL {name}: {path}')
if errors: sys.exit(1)
print(f'PASS: {count} source/export files; no configured private-data patterns found')
print('This is a bounded scan, not proof of secret absence or redistribution rights.')
