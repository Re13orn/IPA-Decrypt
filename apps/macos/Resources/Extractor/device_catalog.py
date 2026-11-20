"""Read installed SINF metadata; never choose a license on the user's behalf."""
import hashlib
import base64
import json
from core import derive_work16
from concurrent.futures import ThreadPoolExecutor
from functools import lru_cache
import os
from pathlib import PurePosixPath, Path
import sys
sys.path.insert(0,str(Path(__file__).parent/'credential-retrieval'))
import plistlib
import shlex
import subprocess
from ssh_options import command, elevate
from retrieve import sinf_field, supported_sinf, MAX_SINF_BYTES


def validate_path(path):
    item = PurePosixPath(path)
    if not path.startswith('/var/containers/Bundle/Application/') or '..' in item.parts or item.parent.name != 'SC_Info' or item.suffix != '.sinf' or item.parent.parent.suffix not in ('.app','.appex'):
        raise ValueError('Invalid installed license path')
    return path


class CatalogDevice:
    def __init__(self, host, port, alias):
        self.command = command(host, port, alias)
    def run(self, text):
        text, payload = elevate(text, None)
        result = subprocess.run(self.command + [text], input=payload, capture_output=True, timeout=120)
        if result.returncode: raise RuntimeError('Unable to read device licenses')
        return result.stdout
    def read(self, path):
        return self.run('head -c ' + str(MAX_SINF_BYTES + 1) + ' ' + shlex.quote(path))


def selected_license(device, path, expected):
    validate_path(path)
    data=device.read(path)
    if len(data)>MAX_SINF_BYTES or hashlib.sha256(data).hexdigest()!=expected or not supported_sinf(data) or path.endswith('.v4.sinf') or PurePosixPath(path).parent.parent.suffix != '.app':
        raise ValueError('selected installed license changed or is unsupported; rescan device')
    return data


def credential_candidates(path):
    if not path: return []
    candidates=[];seen=set()
    for item in json.loads(Path(path).read_text()):
        data=base64.b64decode(item['data'],validate=True)
        if len(data)!=16: raise ValueError('Invalid local credential')
        if data not in seen:
            seen.add(data);candidates.append((item['id'],data))
    return candidates


def credential_match(data, candidates):
    for identifier, credential in candidates:
        try: derive_work16(credential,data)
        except ValueError: continue
        return identifier
    return None


def catalog(device, candidates=(), snapshots=None):
    if snapshots:
        snapshots=Path(snapshots);snapshots.mkdir(parents=True,exist_ok=True,mode=0o700)
    listing=device.run("find /var/containers/Bundle/Application -type f -path '*/SC_Info/*.sinf' -print0")
    paths=[]
    for raw in sorted(set(listing.split(b'\0'))):
        if not raw: continue
        path=raw.decode('utf-8','surrogateescape')
        try: validate_path(path)
        except ValueError: continue
        paths.append(path)
    @lru_cache(maxsize=None)
    def account_hint(container):
        try:
            metadata=plistlib.loads(device.read(str(PurePosixPath(container)/'iTunesMetadata.plist')))
            for key in ('appleId','userName'):
                value=metadata.get(key)
                if isinstance(value,str) and 0<len(value)<=256 and not any(ord(c)<32 for c in value):
                    return value
        except (ValueError,RuntimeError,plistlib.InvalidFileException): pass
        return None
    def inspect(path):
        bundle=PurePosixPath(path).parent.parent
        record=dict(path=path, appName=bundle.stem, bundleID='', user='', key='', digest='', supported=False, reason='许可证无法读取或格式不支持')
        hint=account_hint(str(PurePosixPath(*bundle.parts[:6])))
        if hint: record['metadataAccount']=hint
        try:
            info=plistlib.loads(device.read(str(bundle/'Info.plist')))
            record.update(appName=str(info.get('CFBundleDisplayName') or info.get('CFBundleName') or bundle.stem),bundleID=str(info.get('CFBundleIdentifier') or ''))
            data=device.read(path)
            if len(data)>MAX_SINF_BYTES: raise ValueError('Too large')
            record.update(digest=hashlib.sha256(data).hexdigest(),supported=supported_sinf(data))
            if snapshots:
                destination=snapshots/(record['digest']+'.sinf')
                try:
                    descriptor=os.open(destination,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
                except FileExistsError: pass
                else:
                    with os.fdopen(descriptor,'wb') as stream: stream.write(data)
            match=credential_match(data,candidates)
            if match: record['credentialMatch']=match
            for tag, field in [(b'user','user'),(b'key ','key')]:
                value=sinf_field(data,tag)
                if len(value)==4: record[field]=value.hex()
            if path.endswith('.v4.sinf') or bundle.suffix == '.appex':
                record['supported']=False
                record['reason']='此许可证类型暂不支持直接提取'
            elif record['supported']: record['reason']=''
        except (ValueError,KeyError,RuntimeError,plistlib.InvalidFileException): pass
        return record
    with ThreadPoolExecutor(max_workers=4) as pool:
        records=list(pool.map(inspect,paths))
    return sorted(records,key=lambda item:(item['appName'].casefold(),item['bundleID'],item['path']))


if __name__=='__main__':
    import json,sys
    device=CatalogDevice(os.environ.get('IPA_SSH_HOST','127.0.0.1'),int(sys.argv[1]),os.environ['IPA_SSH_ALIAS'])
    print(json.dumps(dict(installedLicenses=catalog(device,credential_candidates(sys.argv[2] if len(sys.argv)>2 and sys.argv[2] else None),sys.argv[3] if len(sys.argv)>3 else None)),ensure_ascii=False))
