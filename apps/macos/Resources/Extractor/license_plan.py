"""Explicit target selection; never infer account ownership from a UI label."""
from pathlib import Path
from zipfile import ZipFile
import sys
sys.path.insert(0, str(Path(__file__).parent/'credential-retrieval'))
from retrieve import license_sinf, sinf_field


def inspect_ipa(path):
    path=Path(path)
    with ZipFile(path) as archive:
        names=archive.namelist()
        if len(names)!=len(set(names)): raise ValueError('IPA contains duplicate paths')
        candidates=sorted(name for name in names if '/SC_Info/' in name and name.endswith('.sinf') and not name.endswith('.v4.sinf'))
    selectors={}
    for name in candidates:
        try: data=license_sinf(None,path,name)
        except (ValueError,KeyError): continue
        user=sinf_field(data,b'user').hex();key=sinf_field(data,b'key ').hex()
        previous=selectors.get((user,key))
        if previous is None or (name.count('/'),name)<(previous['member'].count('/'),previous['member']):
            selectors[(user,key)]={'member':name,'user':user,'key':key}
    if not selectors: raise ValueError('IPA has no supported license')
    return sorted(selectors.values(),key=lambda item:(item['member'].count('/'),item['member']))


def target_license(path,member=None):
    if not path: raise ValueError('An explicit target IPA is required')
    choices = inspect_ipa(path)
    if member is None and len(choices) != 1: raise ValueError('Choose an explicit target license')
    data=license_sinf(None,Path(path),member)
    return data,{'user':sinf_field(data,b'user').hex(),'key':sinf_field(data,b'key ').hex()}
