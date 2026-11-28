#!/usr/bin/env python3
"""Check a complete app's runtime resources and Mach-O dependencies, without Apple login."""
import argparse,hashlib,json,os,plistlib,re,stat,subprocess,tempfile,zipfile
from pathlib import Path
MAGIC={b'\xcf\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca',b'\xca\xfe\xba\xbf'}
class InvalidBundle(Exception):pass
def require(ok,reason):
 if not ok:raise InvalidBundle(reason)
def expand(value,binary,executable):
 return value.replace('@loader_path',str(binary.parent)).replace('@executable_path',str(executable.parent))
def inspect(app,platform,*,proof_lock=None):
 app=app.resolve();require(app.is_dir(),'App directory missing')
 contents=app/'Contents' if platform=='macos' else app
 info=plistlib.loads((contents/'Info.plist').read_bytes());main=contents/('MacOS' if platform=='macos' else '')/info['CFBundleExecutable']
 resources=contents/'Resources' if platform=='macos' else contents
 require(main.is_file(),'Main executable missing')
 require(os.access(main,os.X_OK),'Main executable is not executable')
 with main.open('rb') as f:require(f.read(4) in MAGIC,'Main executable is not Mach-O')
 if platform=='ios':require('iPhoneOS' in info.get('CFBundleSupportedPlatforms',[]),'Distribution requires device app, not Simulator app')
 runtime=resources/'NativeStoreRuntime';manifest=json.loads((runtime/'PROVENANCE.json').read_text())
 for name,digest in manifest['sha256'].items():
  require(Path(name).name==name,'Invalid runtime manifest member')
  require((runtime/name).is_file(),'Missing runtime: '+name)
  require(hashlib.sha256((runtime/name).read_bytes()).hexdigest()==digest,'Changed runtime: '+name)
 for name in ['index.html','ipalab.mjs']:require((runtime/name).is_file(),'Missing runtime entry: '+name)
 require(bool(plistlib.loads((resources/'Storefronts.plist').read_bytes())),'Storefront list empty')
 private={'accounts-v2.json','credentials-v2.json','accounts.json','credentials.json','jobs.json','processing-queue.json','passwords.json','beta.session','ipatool-state','ipatool-hardware'}
 for path in app.rglob('*'):
  require(path.name not in private,'User state included in app: '+path.name)
  if path.is_symlink():require(path.resolve().is_relative_to(app),'Symlink escapes bundle: '+path.name)
 if platform=='macos':
  proof=proof_lock if proof_lock is not None else json.loads((Path(__file__).resolve().parents[1]/'dependencies/unicorn-macos-arm64.lock.json').read_text())
  wheel=resources/'StoreRuntime/unicorn.whl'
  require(wheel.is_file(),'Missing Store proof engine archive')
  require(hashlib.sha256(wheel.read_bytes()).hexdigest()==proof['sha256'],'Changed Store proof engine archive')
  with zipfile.ZipFile(wheel) as archive:
   require(hashlib.sha256(archive.read(proof['member'])).hexdigest()==proof['library_sha256'],'Changed Store proof engine library')
 required=[]
 if platform=='macos':
  required=['Python/bin/python3','Extractor/host.py','Extractor/license_plan.py','Extractor/askpass','bin/idevice_id','bin/ideviceinfo','bin/iproxy','bin/unfairplay']
  required+=['Extractor/bundle/'+name for name in ['credential.ios','driver.ios','trigger.ios','arcade-capture.ios','static-key-table.bin','core4-word-table.bin']]
 for name in required:
  require((resources/name).is_file(),'Missing helper: '+name)
  if name.startswith('bin/') or name=='Python/bin/python3' or name.endswith('.ios'):require(os.access(resources/name,os.X_OK),'Helper is not executable: '+name)
 helpers=0;binaries=0
 minimum=info.get('LSMinimumSystemVersion' if platform=='macos' else 'MinimumOSVersion')
 require(bool(minimum),'Minimum OS version missing')
 def version(value):return tuple(int(x) for x in value.split('.'))+(0,)*(3-len(value.split('.')))
 for binary in app.rglob('*'):
  if not binary.is_file() or binary.is_symlink():continue
  with binary.open('rb') as f:magic=f.read(4)
  if magic not in MAGIC:continue
  if platform=='macos' and binary.suffix=='.ios':helpers+=1;continue
  binaries+=1
  arch=subprocess.check_output(['lipo','-archs',str(binary)],text=True).split()
  require('arm64' in arch,'arm64 slice missing: '+binary.name)
  load=subprocess.check_output(['otool','-l',str(binary)],text=True)
  targets=re.findall(r'cmd LC_BUILD_VERSION\n\s+cmdsize \d+\n\s+platform (\d+)',load)
  require(all(x==('1' if platform=='macos' else '2') for x in targets),'Wrong binary platform: '+binary.name)
  minima=re.findall(r'^\s+minos\s+(\d+(?:\.\d+)+)',load,re.M)
  minima+=re.findall(r'cmd LC_VERSION_MIN_\w+\n\s+cmdsize \d+\n\s+version (\d+(?:\.\d+)+)',load)
  require(all(version(x)<=version(minimum) for x in minima),'Binary requires newer OS than app declares: '+binary.name)
  identity=re.findall(r'cmd LC_ID_DYLIB\n\s+cmdsize \d+\n\s+name (.+?) \(offset',load)
  rpaths=re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.+?) \(offset',load)
  for line in subprocess.check_output(['otool','-L',str(binary)],text=True).splitlines()[1:]:
   dep=line.strip().split(' (')[0]
   if dep in identity:continue
   if dep.startswith(('/System/Library/','/usr/lib/')):continue
   if dep.startswith('@rpath/'):
    options=[expand(x,binary,main)+'/'+dep[len('@rpath/'):] for x in rpaths]
    # Embedded libraries can inherit the executable's runpaths.
    if not options:
     mload=subprocess.check_output(['otool','-l',str(main)],text=True)
     options=[expand(x,main,main)+'/'+dep[len('@rpath/'):] for x in re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.+?) \(offset',mload)]
   elif dep.startswith(('@loader_path/','@executable_path/')):options=[expand(dep,binary,main)]
   else:raise InvalidBundle('External dependency in '+binary.name+': '+dep)
   valid=False
   for value in options:
    if value.startswith('/usr/lib/') or value.startswith('/System/Library/'):valid=True;break
    path=Path(value).resolve()
    if path.is_relative_to(app) and path.is_file():valid=True;break
   require(valid,'Unresolved bundled dependency in '+binary.name+': '+dep)
 return {'platform':platform,'version':info.get('CFBundleShortVersionString'),'minimum_os':minimum,'runtime_hashes_verified':len(manifest['sha256']),'mach_o_checked':binaries,'device_helpers_excluded_from_host_link_check':helpers,'result':'passed-structural-installation-check','scope':'Bundle resource/dependency checks, not independent hardware or account acceptance'}
def extract_ipa(archive,directory):
 for item in archive.infolist():
  path=Path(item.filename)
  require(not path.is_absolute() and '..' not in path.parts,'Unsafe IPA member')
  require(not stat.S_ISLNK(item.external_attr >> 16),'IPA symlink member unsupported')
 archive.extractall(directory)
 # zipfile.extractall does not restore Unix permission bits; inspect the actual
 # archived executable mode instead of its temporary default 0644 extraction.
 for item in archive.infolist():
  path=Path(directory)/item.filename;mode=(item.external_attr >> 16)&0o777
  if path.is_file() and mode:path.chmod(mode)
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--platform',choices=['macos','ios'],required=True);p.add_argument('artifact',type=Path);p.add_argument('--report',type=Path);a=p.parse_args()
 try:
  if a.artifact.suffix=='.ipa':
   require(a.platform=='ios','IPA requires --platform ios')
   with tempfile.TemporaryDirectory(prefix='ipa-inspection-') as temporary:
    with zipfile.ZipFile(a.artifact) as z:
     extract_ipa(z,temporary)
    apps=list((Path(temporary)/'Payload').glob('*.app'));require(len(apps)==1,'Expected one main Payload app');report=inspect(apps[0],a.platform)
  else:report=inspect(a.artifact,a.platform)
 except (InvalidBundle,FileNotFoundError,KeyError,ValueError) as error:raise SystemExit('FAIL: '+str(error))
 if a.report:a.report.parent.mkdir(parents=True,exist_ok=True);a.report.write_text(json.dumps(report,indent=2)+'\n')
 print(json.dumps(report,ensure_ascii=False))
if __name__=='__main__':main()
