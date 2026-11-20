#!/usr/bin/env python3
"""Cache-isolated source reconstruction on this Mac; never claims another machine."""
import argparse,json,os,platform,shutil,subprocess,sys,tempfile,time
from pathlib import Path
from source_files import ROOT,files
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work',type=Path)
p.add_argument('--ios',action='store_true',help='Also rebuild both iOS native slices and unsigned device app')
p.add_argument('--device-helpers',action='store_true',help='Build extractor device helpers from source; requires ldid')
p.add_argument('--external-assets',type=Path)
p.add_argument('--allow-unreviewed-local-only',action='store_true')
a=p.parse_args()
w=(a.work or Path(tempfile.mkdtemp(prefix='ipa-release-clean-'))).resolve()
w.mkdir(parents=True,exist_ok=True)
if any(w.iterdir()):raise SystemExit('Work directory must be empty')
repo=w/'source';repo.mkdir();logs=w/'logs';logs.mkdir();cache=w/'cache';cache.mkdir()
report={'scope':'isolated source rebuild on existing Mac; not a fresh OS/VM','system':platform.platform(),'source_binaries_before_import':0,'steps':[],'unreviewed_assets_imported':bool(a.external_assets),'result':'running'}
def save():(w/'report.json').write_text(json.dumps(report,indent=2)+'\n')
for src in files():
 dst=repo/src.relative_to(ROOT);dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dst)
if list(repo.rglob('*.a')) or list(repo.rglob('*.xcframework')):raise SystemExit('Generated library leaked into clean input')
if a.external_assets:
 if not a.allow_unreviewed_local_only:raise SystemExit('Explicit --allow-unreviewed-local-only required')
 subprocess.run([sys.executable,str(repo/'scripts/import-local-assets.py'),'--from',str(a.external_assets.resolve()),'--allow-unreviewed-local-only'],check=True)
else:raise SystemExit('Full native rebuild needs explicit local-only external inputs; see readiness report')
# Deliberately do not replace HOME. Tool-specific caches/config are redirected.
env=dict(os.environ)
for name in ['GOROOT','GOFLAGS','CPATH','C_INCLUDE_PATH','CPLUS_INCLUDE_PATH','LIBRARY_PATH','CMAKE_PREFIX_PATH','PYTHONPATH','DYLD_LIBRARY_PATH','DYLD_FRAMEWORK_PATH']:
 env.pop(name,None)
env.update(GOENV='off',GOTOOLCHAIN='go1.26.5',GOPATH=str(cache/'gopath'),GOMODCACHE=str(cache/'gomod'),GOCACHE=str(cache/'gobuild'),GOFLAGS='-mod=readonly',GOPROXY='https://proxy.golang.org,direct',GOSUMDB='sum.golang.org',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_TERMINAL_PROMPT='0',CLANG_MODULE_CACHE_PATH=str(cache/'clang'),SWIFT_MODULECACHE_PATH=str(cache/'swift'),PYTHONDONTWRITEBYTECODE='1')
policy=w/'deny-origin.sb'
policy.write_text('(version 1)\n(allow default)\n(deny file-read* (subpath '+json.dumps(str(ROOT.parent))+'))\n(deny file-read* (subpath '+json.dumps(str(Path.home()/'Library/Application Support/IPADecryptMac'))+'))\n')
def run(name,args,outer_sandbox=True):
 start=time.monotonic();step={'name':name,'status':'running','outer_sandbox':outer_sandbox};report['steps'].append(step);save();print(name,flush=True)
 with (logs/(name+'.log')).open('w') as out:
  command=(['/usr/bin/sandbox-exec','-f',str(policy)] if outer_sandbox else [])+list(map(str,args))
  proc=subprocess.run(command,cwd=repo,env=env,stdout=out,stderr=subprocess.STDOUT)
 step.update(status='passed' if proc.returncode==0 else 'failed',exit_code=proc.returncode,seconds=round(time.monotonic()-start,2));save()
 if proc.returncode:raise RuntimeError(name+' failed; inspect its log')
try:
 run('verify-source-locks',[sys.executable,repo/'scripts/verify-dependencies.py'])
 run('native-macos',[sys.executable,repo/'apps/macos/Tools/build-core.py','--work',w/'native-macos'])
 run('swift-macos',['swift','build','-c','release','--package-path',repo/'apps/macos','--scratch-path',w/'swift-macos','--cache-path',cache/'spm','--config-path',cache/'spm-config','--security-path',cache/'spm-security','--disable-sandbox'])
 if a.device_helpers:
  run('device-helpers',['make','-C',repo/'apps/macos/Resources/Extractor/credential-retrieval','-j4'])
 run('release-input-tests',[sys.executable,'-m','unittest','discover','-s',repo/'tests','-p','test_release_inputs.py'])
 run('offline-tests',['bash',repo/'scripts/test.sh'])
 if a.ios:
  run('native-ios',[sys.executable,repo/'scripts/build-native-ios.py','--work',w/'native-ios'])
  # Xcode's manifest evaluator applies its own sandbox; nested sandbox-exec is rejected.
  report['xcode_isolation']='Fresh derived data/package caches; Xcode-managed manifest sandbox, no outer deny-origin policy'
  run('xcode-ios',['xcodebuild','-project',repo/'apps/ios/IPALab.xcodeproj','-scheme','IPALab','-sdk','iphoneos','-configuration','Release','-derivedDataPath',w/'xcode-ios','-clonedSourcePackagesDirPath',cache/'xcode-packages','-packageCachePath',cache/'xcode-package-cache','-disablePackageRepositoryCache','CODE_SIGNING_ALLOWED=NO','build'],outer_sandbox=False)
 report['result']='passed-macos-ios-and-tests' if a.ios else 'passed-native-macos-and-tests'
except Exception as error:
 report['result']='failed';report['failure']=str(error);save();print(error,file=sys.stderr);print(w);sys.exit(1)
save();print(w)
