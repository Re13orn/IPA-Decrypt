"""Package the native Apple Silicon executable and its relocatable helpers."""
from pathlib import Path
import os
import plistlib
import shutil
import subprocess

BASE = Path(__file__).resolve().parents[1]
ROOT = BASE.parents[1]
WORK = Path(os.environ.get('IPA_MAC_BUILD_WORK', str(ROOT / '.build-work')))
OUTPUT = Path(os.environ.get('IPA_MAC_OUTPUT', str(ROOT / 'dist/macos')))
subprocess.run(['python3', str(ROOT / 'scripts/verify-dependencies.py')], check=True)
USB_PREFIX = Path(os.environ.get('IPA_USB_PREFIX', str(ROOT / '.build-work/usb-runtime/prefix'))).resolve()
subprocess.run(['python3', str(ROOT / 'scripts/verify-usb-runtime.py'), '--prefix', str(USB_PREFIX)], check=True)
OUTPUT.mkdir(parents=True, exist_ok=True)
APP = OUTPUT / 'IPA 解密.app'
# Build into a unique staging bundle before replacing our previous build.
STAGE = OUTPUT / 'IPA 解密.building.app'
if STAGE.exists(): shutil.rmtree(STAGE)
contents = STAGE / 'Contents'; resources = contents / 'Resources'; frameworks = contents / 'Frameworks'; macos = contents / 'MacOS'
macos.mkdir(parents=True); frameworks.mkdir(); shutil.copytree(BASE / 'Resources', resources, ignore=shutil.ignore_patterns('__pycache__', '*.pyc', '.DS_Store', 'build', '.build'))
shutil.copy2(Path(os.environ.get('IPA_MAC_EXECUTABLE', str(BASE / '.build/release/IPADecryptMac'))), macos / 'IPADecryptMac')
python = Path(os.environ.get('IPA_PYTHON_HOME', str(WORK / 'mac-ipa/python/cpython-3.12.14-macos-aarch64-none')))
if not (python / 'bin/python3').exists():
    raise SystemExit('Missing standalone Python; see docs/BUILDING.md or set IPA_PYTHON_HOME')
shutil.copytree(python, resources / 'Python', symlinks=True, ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
# Strip pip/tooling from the shipped interpreter; runtime imports stay local.
for entry in (resources / 'Python/lib/python3.12/site-packages').glob('*'):
    if entry.is_dir(): shutil.rmtree(entry)
    else: entry.unlink()
packages = Path(os.environ.get('IPA_PYTHON_PACKAGES', str(BASE / 'Resources/PythonPackages')))
for entry in packages.iterdir():
    target = resources / 'Python/lib/python3.12/site-packages' / entry.name
    if entry.is_dir(): shutil.copytree(entry, target)
    else: shutil.copy2(entry, target)
shutil.rmtree(resources / 'PythonPackages', ignore_errors=True)
# Keep source notices with every local bundle; this does not clear release blockers.
shutil.copytree(ROOT / 'licenses', resources / 'Licenses', dirs_exist_ok=True)
shutil.copy2(ROOT / 'LICENSE', resources / 'Licenses/APPLICATION-LICENSE.txt')
for name, relative in [('AppleAuth', 'Vendor/AppleAuth'), ('ZIPFoundation', 'Vendor/ZIPFoundation'), ('ipatool', 'ThirdPartySource/ipatool'), ('libzip', 'ThirdPartySource/libzip'), ('LZFSE', 'ThirdPartySource/lzfse'), ('JSON', 'ThirdPartySource/nlohmann_json'), ('UnfairPlay', 'ThirdPartySource/UnfairPlay')]:
    target = resources / 'Licenses' / name
    target.mkdir(exist_ok=True)
    for original in (BASE / relative).iterdir():
        if original.is_file() and original.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE', 'THIRD_PARTY_NOTICES')):
            shutil.copy2(original, target / original.name)
    if (BASE / relative / 'Licenses').is_dir():
        shutil.copytree(BASE / relative / 'Licenses', target / 'Licenses')
shutil.copytree(ROOT / 'dependencies', resources / 'DependencyLocks', dirs_exist_ok=True)
(resources / 'bin').mkdir()
shutil.copy2(BASE / 'Vendor/unfairplay', resources / 'bin/unfairplay')
for name in ['idevice_id','ideviceinfo','iproxy']:
    source = USB_PREFIX / 'bin' / name
    shutil.copy2(source.resolve(), resources / 'bin' / name)

# Relocate the selected USB runtime; never reference the build prefix.
queue = [resources / 'bin' / name for name in ['idevice_id','ideviceinfo','iproxy']]; processed = set()
while queue:
    binary = queue.pop()
    if binary in processed: continue
    processed.add(binary)
    deps = subprocess.check_output(['otool','-L',str(binary)], text=True).splitlines()[1:]
    for line in deps:
        dependency = line.strip().split(' (')[0]
        if dependency == '@loader_path/' + binary.name: continue  # relocated dylib identity
        if dependency.startswith(('/System/Library/', '/usr/lib/')): continue
        if not dependency.startswith(str(USB_PREFIX) + '/'):
            raise SystemExit('USB dependency outside selected runtime prefix: ' + dependency)
        original = Path(dependency)
        dest = frameworks / original.name
        if not dest.exists():
            shutil.copy2(original.resolve(), dest)
            subprocess.run(['install_name_tool','-id','@loader_path/' + dest.name,str(dest)], check=True)
            queue.append(dest)
        relative = os.path.relpath(dest, binary.parent)
        subprocess.run(['install_name_tool','-change',dependency,'@loader_path/' + relative,str(binary)], check=True)

info = dict(CFBundleExecutable='IPADecryptMac', CFBundleIdentifier='local.ipadecrypt.mac', CFBundleName='IPA 解密', CFBundleDisplayName='IPA 解密', CFBundlePackageType='APPL', CFBundleIconFile='AppIcon', CFBundleShortVersionString='1.0.6', CFBundleVersion='7', LSMinimumSystemVersion='15.0', NSHighResolutionCapable=True, LSMultipleInstancesProhibited=True, NSPrincipalClass='NSApplication', NSLocalNetworkUsageDescription='允许局域网设备下载你主动分享的 IPA。', NSAppTransportSecurity=dict(NSAllowsLocalNetworking=True), CFBundleDocumentTypes=[dict(CFBundleTypeName='IPA 与 FairPlay 凭据',CFBundleTypeRole='Viewer',LSHandlerRank='Alternate',LSItemContentTypes=['public.data'])])
(contents / 'Info.plist').write_bytes(plistlib.dumps(info))
# Preserve ldid signatures/entitlements on device-side iOS helpers.
for directory in [frameworks, resources / 'bin', resources / 'Python']:
    for binary in directory.rglob('*'):
        if binary.is_file() and not binary.is_symlink():
            kind = subprocess.run(['file','-b',str(binary)], capture_output=True, text=True).stdout
            if 'Mach-O' in kind:
                subprocess.run(['codesign','--force','--sign','-',str(binary)], check=True, capture_output=True)
subprocess.run(['codesign','--force','--sign','-',str(STAGE)],check=True)
subprocess.run(['codesign','--verify','--deep','--strict',str(STAGE)],check=True)
subprocess.run(['python3', str(ROOT / 'scripts/verify-installation.py'), '--platform', 'macos', str(STAGE)], check=True)
if APP.exists():
    backup = OUTPUT / 'IPA 解密.previous.app'
    if backup.exists(): shutil.rmtree(backup)
    APP.rename(backup)
STAGE.rename(APP)
print(APP)
