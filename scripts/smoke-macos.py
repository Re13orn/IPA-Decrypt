#!/usr/bin/env python3
"""Launch a packaged Mac app and exercise bundled helpers without accounts/devices."""
import argparse, json, platform, subprocess, sys
from pathlib import Path

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app',type=Path)
    parser.add_argument('--report',type=Path)
    args=parser.parse_args();app=args.app.resolve();resources=app/'Contents/Resources'
    def run(command,timeout=45):
        result=subprocess.run([str(x) for x in command],capture_output=True,text=True,timeout=timeout)
        if result.returncode:raise SystemExit(f'{Path(str(command[0])).name} failed ({result.returncode}): {result.stderr}')
        return result.stdout
    launch=run([app/'Contents/MacOS/IPADecryptMac','--launch-check'])
    if 'mac-launch-check: passed' not in launch:raise SystemExit('App did not confirm SwiftUI startup')
    run([resources/'Python/bin/python3','-I','-c','import cryptography, cffi; from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes; c=Cipher(algorithms.AES(bytes(16)),modes.ECB()).encryptor(); assert len(c.update(bytes(16)))==16; print("python-crypto: passed")'])
    run([resources/'Python/bin/python3',resources/'Extractor/host.py','--help'])
    for name in ['idevice_id','ideviceinfo','iproxy']:run([resources/'bin'/name,'--version'])
    run([resources/'bin/unfairplay','--version'])
    report={'system':platform.mac_ver()[0],'architecture':platform.machine(),'launch':'passed','python_crypto':'passed','extractor_cli':'passed','usb_helpers':'passed','enrollment_helper':'passed','scope':'Packaged app startup and offline helper checks; no Apple account, download, device SSH or decryption acceptance'}
    if args.report:args.report.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report))
if __name__=='__main__':main()
