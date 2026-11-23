#!/usr/bin/env python3
"""Launch a packaged Mac app and exercise bundled helpers without accounts/devices."""
import argparse, json, platform, subprocess, sys, os
from pathlib import Path

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app',type=Path)
    parser.add_argument('--report',type=Path)
    args=parser.parse_args();app=args.app.resolve();resources=app/'Contents/Resources'
    def run(command,timeout=45,env=None):
        result=subprocess.run([str(x) for x in command],capture_output=True,text=True,timeout=timeout,env=env)
        if result.returncode:raise SystemExit(f'{Path(str(command[0])).name} failed ({result.returncode}): {result.stderr}')
        return result.stdout
    run(['/usr/bin/codesign','--verify','--deep','--strict',app])
    launch=run([app/'Contents/MacOS/IPADecryptMac','--launch-check'])
    if 'mac-launch-check: passed' not in launch:raise SystemExit('App did not confirm SwiftUI startup')
    # A fresh HOME plus denied network proves first login needs no runtime download.
    import tempfile
    with tempfile.TemporaryDirectory(prefix='ipa-store-runtime-') as home:
        env=dict(os.environ,HOME=home,CFFIXED_USER_HOME=home)
        proof=run(['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)',app/'Contents/MacOS/IPADecryptMac','--store-runtime-check'],env=env)
        if 'mac-store-runtime-check: passed' not in proof:raise SystemExit('Store proof runtime did not confirm execution')
    run([resources/'Python/bin/python3','-I','-B','-c','import cryptography, cffi; from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes; c=Cipher(algorithms.AES(bytes(16)),modes.ECB()).encryptor(); assert len(c.update(bytes(16)))==16; print("python-crypto: passed")'])
    run([resources/'Python/bin/python3','-B',resources/'Extractor/host.py','--help'])
    for name in ['idevice_id','ideviceinfo','iproxy']:run([resources/'bin'/name,'--version'])
    run([resources/'bin/unfairplay','--version'])
    run(['/usr/bin/codesign','--verify','--deep','--strict',app])
    report={'signature_after_execution':'passed','system':platform.mac_ver()[0],'architecture':platform.machine(),'launch':'passed','store_proof_empty_cache_offline':'passed','python_crypto':'passed','extractor_cli':'passed','usb_helpers':'passed','enrollment_helper':'passed','scope':'Packaged app startup and offline helper checks; no Apple account, download, device SSH or decryption acceptance'}
    if args.report:args.report.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report))
if __name__=='__main__':main()
