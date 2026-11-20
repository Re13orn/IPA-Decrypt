#!/usr/bin/env python3
"""Check release preparation inputs; report maintainer decision separately from audit observations."""
import argparse,json,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--macos-app',type=Path)
    parser.add_argument('--ios-ipa',type=Path)
    args=parser.parse_args()
    for script in ['verify-dependencies.py','check-source.py']:
        subprocess.run([sys.executable,str(ROOT/'scripts'/script)],check=True)
    data=json.loads((ROOT/'dependencies/release-review.json').read_text())
    if data.get('schema')!=2 or data.get('maintainer_decision',{}).get('status')!='proceed-with-release-preparation':
        raise SystemExit('Release preparation decision is missing or unsupported')
    for platform,artifact in [('macos',args.macos_app),('ios',args.ios_ipa)]:
        if artifact:
            subprocess.run([sys.executable,str(ROOT/'scripts/verify-installation.py'),'--platform',platform,str(artifact)],check=True)
    if not args.macos_app and not args.ios_ipa:
        print('No installation artifacts supplied: binary portability is not checked by this invocation.')
    print('PASS: technical source/dependency checks; maintainer decision recorded to proceed with release preparation.')
    pending=[row for row in data['review_items'] if row['status']!='independently-cleared']
    print(f'Independent review: {len(pending)} recorded observations remain; see dependencies/release-review.json.')
    print('This check does not upload files or grant/change third-party licenses.')
if __name__=='__main__':main()
