#!/usr/bin/env python3
"""Package an unsigned device app only after its installation resources pass validation."""
import argparse,hashlib,plistlib,subprocess,sys,zipfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--app',type=Path,required=True);p.add_argument('--output',type=Path,default=ROOT/'dist/ios');a=p.parse_args();app=a.app.resolve()
 subprocess.run([sys.executable,str(ROOT/'scripts/verify-installation.py'),'--platform','ios',str(app)],check=True)
 if (app/'embedded.mobileprovision').exists() or (app/'_CodeSignature').exists():raise SystemExit('Expected unsigned app; export signed distributions with Xcode')
 info=plistlib.loads((app/'Info.plist').read_bytes());version=info['CFBundleShortVersionString']
 if not version or not all(x.isdigit() for x in version.split('.')):raise SystemExit('Invalid numeric version')
 a.output.mkdir(parents=True,exist_ok=True);archive=a.output/f'IPA-Decrypt-iOS-{version}-unsigned.ipa';stage=archive.with_suffix('.ipa.building')
 with zipfile.ZipFile(stage,'w',zipfile.ZIP_DEFLATED) as z:
  for member in sorted(app.rglob('*')):
   if member.is_file():z.write(member,Path('Payload')/app.name/member.relative_to(app))
 with zipfile.ZipFile(stage) as z:
  if z.testzip() is not None:raise SystemExit('IPA ZIP integrity failed')
 stage.replace(archive);(a.output/'SHA256SUMS').write_text(hashlib.sha256(archive.read_bytes()).hexdigest()+'  '+archive.name+'\n');print(archive)
if __name__=='__main__':main()
