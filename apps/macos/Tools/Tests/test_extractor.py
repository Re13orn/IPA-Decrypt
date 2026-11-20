import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('extractor_host', ROOT/'Resources/Extractor/host.py')
host = importlib.util.module_from_spec(spec); spec.loader.exec_module(host)
UDID = 'a' * 40
sys.path.insert(0, str(ROOT/'Resources/Extractor'))
import license_plan
FIXTURES = ROOT/'Tools/Tests/Fixtures'
IPA = str(FIXTURES/'target.ipa')
TARGET, SELECTORS = license_plan.target_license(IPA)
INSTALLED='/var/containers/Bundle/Application/b/Right.app/SC_Info/b.sinf'
DIGEST=hashlib.sha256(TARGET).hexdigest()
SELECTED=['--installed-sinf',INSTALLED,'--expected-sinf-hash',DIGEST]
def write_result(output, length=16):
    output.mkdir()
    (output/'credential.bin').write_bytes((FIXTURES/'credential.bin').read_bytes() + bytes(max(0,length-16)))
    _, selectors = license_plan.target_license(IPA)
    (output/'selected.sinf').write_bytes(TARGET)
    (output/'selection.json').write_text(json.dumps(dict(selectors, installedPath=INSTALLED, installedDigest=DIGEST, appName='Fixture', bundleID='example.fixture', triggerUser=selectors['user'], triggerKey=selectors['key'])))


class Tunnel:
    closed = False
    def poll(self): return None
    def terminate(self): self.closed = True
    def wait(self, timeout=None): return 0
class Connection:
    def __enter__(self): return self
    def __exit__(self, *_): pass

class ExtractorTests(unittest.TestCase):
    def test_devices_and_invalid_identifiers(self):
        def run(args, timeout=15):
            text = UDID + '\ninvalid;device\n' if args[0]=='idevice_id' else 'Test device'
            return subprocess.CompletedProcess(args, 0, text, '')
        out = io.StringIO()
        with patch.object(sys, 'argv', ['host.py','devices']), patch.object(host,'run',run), contextlib.redirect_stdout(out): host.main()
        self.assertEqual([x['id'] for x in json.loads(out.getvalue())['devices']], [UDID])
    def test_extract_validates_length_and_closes_tunnel(self):
        for length in [16,17]:
            with self.subTest(length=length), tempfile.TemporaryDirectory() as temp:
                output = Path(temp)/'new'; tunnel = Tunnel(); out = io.StringIO()
                def retrieve(args, **kwargs):
                    if args[0] == '/usr/bin/ssh':
                        return subprocess.CompletedProcess(args, 0, '0\nDarwin\n16.7.11\n', '')
                    self.assertNotIn('synthetic-password', repr(args))
                    self.assertEqual(kwargs['env']['IPA_SSH_PASSWORD'], 'synthetic-password')
                    write_result(output, length)
                    return subprocess.CompletedProcess(args,0,'credential ready','')
                args = ['host.py','extract']+SELECTED+['--ipa',IPA,'--device',UDID,'--output',str(output),'--known-hosts',str(Path(temp)/'known_hosts')]
                with patch.object(sys,'argv',args), patch.object(host.subprocess,'Popen',return_value=tunnel), patch.object(host.subprocess,'run',retrieve), patch.object(host.socket,'create_connection',return_value=Connection()), patch.dict(host.os.environ,{'IPA_SSH_PASSWORD':'synthetic-password'}), contextlib.redirect_stdout(out):
                    if length == 16:
                        host.main(); reply=json.loads(out.getvalue()); self.assertEqual(Path(reply['path']).stat().st_size,16)
                        self.assertNotIn('synthetic-password',out.getvalue())
                    else:
                        with self.assertRaises(RuntimeError): host.main()
                self.assertTrue(tunnel.closed)
    def test_rejects_invalid_device_and_existing_output(self):
        with patch.object(sys,'argv',['host.py','extract','--device','bad;device']):
            with self.assertRaises(RuntimeError): host.main()
        with tempfile.TemporaryDirectory() as temp, patch.object(sys,'argv',['host.py','extract']+SELECTED+['--ipa',IPA,'--device',UDID,'--output',temp]):
            with self.assertRaises(RuntimeError): host.main()

class TargetLicenseTests(unittest.TestCase):
    def test_no_target_never_contacts_device(self):
        for operation in ['auto', 'extract']:
            with patch.object(sys, 'argv', ['host.py', operation, '--host', 'iphone.local']), patch.object(host, 'connection') as connection:
                with self.assertRaisesRegex(RuntimeError, '设备许可证'): host.main()
                connection.assert_not_called()

    def test_inspection_returns_selectors_not_secrets(self):
        out = io.StringIO()
        with patch.object(sys, 'argv', ['host.py', 'inspect', '--ipa', IPA]), patch.object(host, 'connection') as connection, contextlib.redirect_stdout(out):
            host.main(); connection.assert_not_called()
        choices = json.loads(out.getvalue())['licenses']
        self.assertEqual(len(choices), 1)
        self.assertEqual(set(choices[0]), {'member', 'user', 'key'})
        self.assertNotIn((FIXTURES/'credential.bin').read_bytes().hex(), out.getvalue())

    def test_multiple_selectors_require_explicit_choice(self):
        from zipfile import ZipFile
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'multiple.ipa'
            with ZipFile(IPA) as source, ZipFile(path,'w') as dest:
                for name in source.namelist(): dest.writestr(name,source.read(name))
                original=license_plan.inspect_ipa(IPA)[0]
                extra=source.read(original['member']).replace(bytes.fromhex(original['user']),b'\xff\xff\xff\xff')
                dest.writestr('Payload/Other.app/SC_Info/Other.sinf',extra)
            choices=license_plan.inspect_ipa(path)
            self.assertEqual(len(choices),2)
            with self.assertRaisesRegex(ValueError,'explicit'): license_plan.target_license(path)
            _, selected=license_plan.target_license(path,original['member'])
            self.assertEqual(selected['user'],original['user'])

    def test_wrong_result_is_never_reported_as_success(self):
        for defect in ['user', 'key', 'triggerUser', 'installedPath', 'installedDigest', 'credential']:
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as temp:
                output = Path(temp)/'new'
                def retrieve(args, **kwargs):
                    if args[0] == '/usr/bin/ssh': return subprocess.CompletedProcess(args, 0, '0\nDarwin\n16.7.11\n', '')
                    write_result(output)
                    if defect == 'credential': (output/'credential.bin').write_bytes(bytes(16))
                    else:
                        proof=json.loads((output/'selection.json').read_text());proof[defect]='ffffffff';(output/'selection.json').write_text(json.dumps(proof))
                    return subprocess.CompletedProcess(args, 0, '', '')
                with patch.object(sys, 'argv', ['host.py','extract']+SELECTED+['--ipa',IPA,'--host','iphone.local','--output',str(output),'--known-hosts',str(Path(temp)/'known')]), patch.object(host.subprocess, 'run', retrieve):
                    with self.assertRaisesRegex(RuntimeError, '校验'): host.main()

    def test_installed_app_must_match_target_user(self):
        from retrieve import trigger_app, sinf_field
        import plistlib
        target, selectors = license_plan.target_license(IPA)
        wrong = target.replace(bytes.fromhex(selectors['user']), b'\xff\xff\xff\xff')
        class Device:
            def run(self, _): return b'/var/containers/Bundle/Application/a/Wrong.app/SC_Info/a.sinf\0/var/containers/Bundle/Application/b/Right.app/SC_Info/b.sinf\0'
            def read(self, path):
                if path.endswith('Info.plist'): return plistlib.dumps({'CFBundleExecutable': 'Fixture'})
                return wrong if 'Wrong.app' in path else target
        bundle, _, selected = trigger_app(Device(), target)
        self.assertIn('Right.app', bundle)
        self.assertEqual(sinf_field(selected,b'user'),bytes.fromhex(selectors['user']))
        class WrongOnly(Device):
            def run(self, _): return b'/var/containers/Bundle/Application/a/Wrong.app/SC_Info/a.sinf\0'
        with self.assertRaisesRegex(RuntimeError, 'selected account'): trigger_app(WrongOnly(), target)
        with self.assertRaisesRegex(ValueError, 'explicit'): trigger_app(Device(), None)

class DeviceCatalogTests(unittest.TestCase):
    def test_credentials_are_compared_by_bytes_and_license_validation(self):
        import device_catalog, base64
        credential=(FIXTURES/'credential.bin').read_bytes()
        with tempfile.TemporaryDirectory() as temp:
            cache=Path(temp)/'private.json'
            cache.write_text(json.dumps([{'id':'a','data':base64.b64encode(credential).decode()},{'id':'b','data':base64.b64encode(credential).decode()}]))
            candidates=device_catalog.credential_candidates(cache)
            self.assertEqual(len(candidates),1)
            self.assertEqual(device_catalog.credential_match(TARGET,candidates),'a')
            self.assertIsNone(device_catalog.credential_match(TARGET,[('wrong',bytes(16))]))
            changed=TARGET.replace(bytes.fromhex(SELECTORS['user']),b'\xff\xff\xff\xff')
            self.assertEqual(device_catalog.credential_match(changed,candidates),'a')
            # Same user/key with different encrypted license material is not
            # evidence that a credential works; the cryptographic check fails.
            damaged=bytearray(TARGET);damaged[TARGET.index(b'priv')+4]^=1
            self.assertIsNone(device_catalog.credential_match(bytes(damaged),candidates))


    def test_catalog_keeps_all_apps_including_unsupported_without_selecting(self):
        import device_catalog, plistlib
        first='/var/containers/Bundle/Application/a/First.app/SC_Info/a.sinf'
        bad='/var/containers/Bundle/Application/c/Old.app/SC_Info/a.v4.sinf'
        class Device:
            def run(self,_): return (first+'\0'+INSTALLED+'\0'+bad+'\0').encode()
            def read(self,path):
                if path.endswith('Info.plist'): return plistlib.dumps({'CFBundleDisplayName':Path(path).parent.stem,'CFBundleIdentifier':'example.fixture'})
                return b'unsupported' if path==bad else TARGET
        rows=device_catalog.catalog(Device())
        self.assertEqual(len(rows),3)
        self.assertEqual(sum(x['supported'] for x in rows),2)
        self.assertEqual({x['path'] for x in rows},{first,INSTALLED,bad})
        self.assertNotIn('selected',str(rows))
        from retrieve import trigger_app
        class TriggerDevice(Device):
            def read(self,path):
                if path.endswith('Info.plist'): return plistlib.dumps({'CFBundleExecutable':'Fixture'})
                return super().read(path)
        app,_,_=trigger_app(TriggerDevice(),TARGET,INSTALLED)
        self.assertIn('Right.app',app)
        with self.assertRaises(RuntimeError): trigger_app(TriggerDevice(),TARGET,'/var/containers/Bundle/Application/x/Missing.app/SC_Info/a.sinf')

    def test_private_snapshots_and_metadata_account_hint(self):
        import device_catalog, plistlib, stat
        class Device:
            def run(self,_): return (INSTALLED+'\0').encode()
            def read(self,path):
                if path.endswith('iTunesMetadata.plist'): return plistlib.dumps({'userName':'download@example.invalid'})
                if path.endswith('Info.plist'): return plistlib.dumps({'CFBundleDisplayName':'Fixture','CFBundleIdentifier':'example.fixture'})
                return TARGET
        with tempfile.TemporaryDirectory() as temp:
            rows=device_catalog.catalog(Device(),snapshots=Path(temp)/'snapshots')
            self.assertEqual(rows[0]['metadataAccount'],'download@example.invalid')
            saved=Path(temp)/'snapshots'/(DIGEST+'.sinf')
            self.assertEqual(saved.read_bytes(),TARGET)
            self.assertEqual(stat.S_IMODE(saved.stat().st_mode),0o600)
            self.assertNotIn('downloadAccounts',rows[0])

    def test_stale_or_invalid_selection_cannot_be_extracted(self):
        import device_catalog
        class Device:
            def read(self,path): return TARGET
        self.assertEqual(device_catalog.selected_license(Device(),INSTALLED,DIGEST),TARGET)
        with self.assertRaisesRegex(ValueError,'changed'): device_catalog.selected_license(Device(),INSTALLED,'0'*64)
        with self.assertRaisesRegex(ValueError,'Invalid'): device_catalog.selected_license(Device(),'/etc/passwd',DIGEST)

    def test_standalone_selected_license_needs_no_local_ipa(self):
        with tempfile.TemporaryDirectory() as temp:
            output=Path(temp)/'new';out=io.StringIO()
            def run(args,**kwargs):
                if args[0]=='/usr/bin/ssh': return subprocess.CompletedProcess(args,0,'0\nDarwin\n16.7.11\n','')
                self.assertNotIn('--ipa',args);self.assertIn(INSTALLED,args)
                write_result(output);return subprocess.CompletedProcess(args,0,'','')
            with patch.object(sys,'argv',['host.py','extract']+SELECTED+['--host','iphone.local','--output',str(output),'--known-hosts',str(Path(temp)/'known')]),patch.object(host.subprocess,'run',run),contextlib.redirect_stdout(out): host.main()
            self.assertEqual(json.loads(out.getvalue())['selection']['installedPath'],INSTALLED)

class NetworkTests(unittest.TestCase):
    def test_host_validation(self):
        for host_name in ['192.168.1.20', 'iphone.local', '2001:db8::1', 'fe80::1%en0']:
            self.assertEqual(host.validate_host(host_name), host_name)
        for host_name in ['ssh://192.168.1.20', '-oProxyCommand=x', 'a;b', 'a b', '../key', 'foo:22', '']:
            with self.assertRaises(RuntimeError): host.validate_host(host_name)
    def test_readonly_network_probe_does_not_launch_extractor_or_tunnel(self):
        out = io.StringIO()
        def probe(args, **kwargs):
            self.assertTrue(args[-1].endswith('id -u; uname -s; (sw_vers -productVersion 2>/dev/null || true)'))
            self.assertEqual(args[-2], 'root@192.168.1.20')
            self.assertEqual(kwargs['env']['IPA_DIRECT_SSH'], '1')
            self.assertFalse(any('retrieve.py' in value for value in args))
            return subprocess.CompletedProcess(args, 0, '0\nDarwin\n16.7.11\n', '')
        with patch.object(sys, 'argv', ['host.py', 'test', '--host', '192.168.1.20', '--known-hosts', '/tmp/known hosts']), patch.object(host.subprocess, 'run', probe), patch.object(host.subprocess, 'Popen') as tunnel, contextlib.redirect_stdout(out):
            host.main()
            tunnel.assert_not_called()
        self.assertIn('root', json.loads(out.getvalue())['message'])
    def test_network_extraction_does_not_require_usb_udid(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp)/'new'; out = io.StringIO()
            def retrieve(args, **kwargs):
                if args[0] == '/usr/bin/ssh':
                    return subprocess.CompletedProcess(args, 0, '0\nDarwin\n16.7.11\n', '')
                self.assertNotIn('--device-udid', args)
                self.assertEqual(kwargs['env']['IPA_SSH_HOST'], 'iphone.local')
                write_result(output)
                return subprocess.CompletedProcess(args, 0, '', '')
            with patch.object(sys, 'argv', ['host.py', 'extract']+SELECTED+['--ipa', IPA, '--host', 'iphone.local', '--output', str(output), '--known-hosts', str(Path(temp)/'known')]), patch.object(host.subprocess, 'run', retrieve), patch.object(host.subprocess, 'Popen') as tunnel, contextlib.redirect_stdout(out):
                host.main(); tunnel.assert_not_called()
            self.assertEqual(Path(json.loads(out.getvalue())['path']).stat().st_size,16)
    def test_capture_timeout_is_not_reported_as_network_failure(self):
        reply=subprocess.CompletedProcess([],1,'','in observe_uid_layer\nsubprocess.TimeoutExpired: command timed out after 100 seconds')
        message=host.failure(reply)
        self.assertIn('许可证捕获',message)
        self.assertNotIn('无法连接设备 SSH',message)

    def test_auth_error_is_redacted(self):
        reply = subprocess.CompletedProcess([], 255, '', 'Permission denied: synthetic-password-and-key')
        message = host.failure(reply)
        self.assertIn('SSH', message)
        self.assertNotIn('synthetic-password-and-key', message)

class AutomaticTests(unittest.TestCase):
    def test_two_requested_pairs_only_and_mobile_sudo(self):
        with tempfile.TemporaryDirectory() as temp:
            output=Path(temp)/'new'; logins=[]; out=io.StringIO()
            def run(args, **kwargs):
                env=kwargs['env']
                if args[0]=='/usr/bin/ssh':
                    if 'id -u; uname -s;' in args[-1]:
                        logins.append((env['IPA_SSH_USER'], env['IPA_SSH_PASSWORD']))
                        if env['IPA_SSH_USER']=='root':
                            return subprocess.CompletedProcess(args,255,'','Permission denied')
                        return subprocess.CompletedProcess(args,0,'501\nDarwin\n16.7.11\n','')
                    if 'sudo -n' in args[-1]: return subprocess.CompletedProcess(args,1,'','password required')
                    self.assertIn('sudo -k -S',args[-1]);self.assertEqual(kwargs['input'],'123456\n')
                    return subprocess.CompletedProcess(args,0,'0\n','')
                self.assertEqual(env['IPA_SUDO_MODE'],'password')
                self.assertEqual(env['IPA_SSH_USER'],'mobile')
                write_result(output)
                return subprocess.CompletedProcess(args,0,'','')
            with patch.object(sys,'argv',['host.py','auto']+SELECTED+['--ipa',IPA,'--host','iphone.local','--output',str(output),'--known-hosts',str(Path(temp)/'known')]), patch.object(host.subprocess,'run',run), contextlib.redirect_stdout(out): host.main()
            self.assertEqual(logins,[('root','alpine'),('mobile','123456')])
            self.assertNotIn('123456',out.getvalue())
            self.assertIn('mobile',json.loads(out.getvalue())['message'])
    def test_custom_username_and_sudo_preserve_binary_input(self):
        env={'IPA_KNOWN_HOSTS':'/tmp/known hosts','IPA_SSH_USER':'mobile','IPA_SSH_PASSWORD':'fixture','IPA_SUDO_MODE':'password'}
        import ssh_options
        args=ssh_options.command('iphone.local',22,'fixture',env=env)
        self.assertEqual(args[-1],'mobile@iphone.local')
        data=bytes(range(256))
        command, payload=ssh_options.elevate('cat > /tmp/test',data,env=env)
        self.assertIn('sudo -k -S',command)
        self.assertTrue(command.startswith(ssh_options.BOOTSTRAP_PATH))
        self.assertNotIn('/bin/sh',command)
        self.assertEqual(payload,b'fixture\n'+data)
    def test_auto_stops_after_two_failed_pairs(self):
        with tempfile.TemporaryDirectory() as temp:
            attempts=[]
            def run(args,**kwargs):
                attempts.append(kwargs['env']['IPA_SSH_USER'])
                return subprocess.CompletedProcess(args,255,'','Permission denied')
            with patch.object(sys,'argv',['host.py','auto']+SELECTED+['--ipa',IPA,'--host','iphone.local','--output',str(Path(temp)/'new'),'--known-hosts',str(Path(temp)/'known')]), patch.object(host.subprocess,'run',run):
                with self.assertRaisesRegex(RuntimeError,'两组'): host.main()
            self.assertEqual(attempts,['root','mobile'])

class SuTests(unittest.TestCase):
    def environment(self, method='auto'):
        return {'IPA_KNOWN_HOSTS':'/tmp/synthetic-known', 'IPA_SSH_USER':'mobile',
                'IPA_SSH_PASSWORD':'mobile-fixture', 'IPA_ROOT_PASSWORD':'root-fixture', 'IPA_ELEVATION_METHOD':method}

    def test_explicit_su_skips_sudo_and_checks_root(self):
        env=self.environment('su')
        process=unittest.mock.Mock(returncode=0)
        process.communicate.return_value=(b'0\n',b'')
        with patch.object(host.subprocess,'run',return_value=subprocess.CompletedProcess([],0,'501\nDarwin\n15.7.3\n','')) as run, patch.object(host,'su_start',return_value=(process,b'')) as su:
            message=host.probe_access('fixture',22,'fixture',env)
        self.assertEqual(run.call_count,1)
        self.assertEqual(env['IPA_SUDO_MODE'],'su')
        self.assertIn('su 已验证',message)
        self.assertNotIn('root-fixture',message)
        self.assertEqual(su.call_args.kwargs['env']['IPA_ROOT_PASSWORD'],'root-fixture')

    def test_su_rejects_nonroot_identity(self):
        env=self.environment('su'); process=unittest.mock.Mock(returncode=0)
        process.communicate.return_value=(b'501\n',b'')
        with patch.object(host.subprocess,'run',return_value=subprocess.CompletedProcess([],0,'501\nDarwin\n15.7.3\n','')),patch.object(host,'su_start',return_value=(process,b'')):
            with self.assertRaisesRegex(RuntimeError,'su 未取得 root'):
                host.probe_access('fixture',22,'fixture',env)
        self.assertNotEqual(env['IPA_SUDO_MODE'],'su')

    def test_auto_falls_back_after_sudo_failure(self):
        env=self.environment(); process=unittest.mock.Mock(returncode=0);process.communicate.return_value=(b'0\n',b'')
        replies=[subprocess.CompletedProcess([],0,'501\nDarwin\n15.7.3\n',''),subprocess.CompletedProcess([],1,'','no sudo'),subprocess.CompletedProcess([],1,'','no sudo')]
        with patch.object(host.subprocess,'run',side_effect=replies),patch.object(host,'su_start',return_value=(process,b'')):
            host.probe_access('fixture',22,'fixture',env)
        self.assertEqual(env['IPA_SUDO_MODE'],'su')

    def test_sudo_only_does_not_try_su(self):
        env=self.environment('sudo')
        replies=[subprocess.CompletedProcess([],0,'501\nDarwin\n15.7.3\n','')]+[subprocess.CompletedProcess([],1,'','denied')]*2
        with patch.object(host.subprocess,'run',side_effect=replies),patch.object(host,'su_start') as su:
            with self.assertRaisesRegex(RuntimeError,'sudo'):host.probe_access('fixture',22,'fixture',env)
            su.assert_not_called()

    def test_su_pty_auth_and_live_observer_stderr(self):
        import os
        import native_ssh
        import ssh_options
        with tempfile.TemporaryDirectory() as directory:
            fake=Path(directory)/'ssh'
            fake.write_text('#!'+sys.executable+'\n'+'import os,re,sys\nassert "-tt" in sys.argv\nassert os.environ["IPA_ROOT_PASSWORD"] not in " ".join(sys.argv)\nos.write(1,b"Password for root: ")\nassert sys.stdin.buffer.readline().strip().decode()==os.environ["IPA_ROOT_PASSWORD"]\nmarker=re.search(r"IPA_SU_READY_[0-9a-f]+",sys.argv[-1]).group().encode()\nos.write(1,b"\\r\\n"+marker+b"\\nobserving FairPlay synthetic\\n")\n')
            fake.chmod(0o700); env=dict(os.environ,**self.environment(),IPA_SUDO_MODE='su')
            process,pending=ssh_options.su_start([str(fake),'-T','mobile@fixture'],'observer',env=env)
            output,_=process.communicate(timeout=5)
            self.assertEqual(process.returncode,0);self.assertIn(b'observing FairPlay',pending+output)
            device=native_ssh.SSHDevice.__new__(native_ssh.SSHDevice);device.command=[str(fake),'-T','mobile@fixture']
            with patch.dict(os.environ,env,clear=True):
                observer=device.popen('observer',stdout=subprocess.PIPE,stderr=subprocess.PIPE)
                self.assertEqual(observer.stderr.readline(),b'observing FairPlay synthetic\n')
                out,err=observer.communicate(timeout=5)
                self.assertEqual(observer.returncode,0);self.assertEqual(out,b'')

    def test_su_binary_transport_is_non_pty_and_cleanup_runs(self):
        import ssh_options
        env=self.environment();binary=bytes(range(256))+b'\x00\r\n'
        process=unittest.mock.Mock(returncode=0);process.communicate.return_value=(b'',b'')
        calls=[]
        def run(args,**kwargs):
            calls.append((args,kwargs))
            if args[-1].startswith('cat ') and 'stdout' in args[-1]:return subprocess.CompletedProcess(args,0,binary,b'')
            return subprocess.CompletedProcess(args,0,b'',b'')
        with patch('subprocess.run',side_effect=run),patch.object(ssh_options,'su_start',return_value=(process,b'')):
            reply=ssh_options.su_run(['/usr/bin/ssh','-T','mobile@fixture'],'cat',binary,env=env)
        self.assertEqual(calls[1][1]['input'],binary);self.assertEqual(reply.stdout,binary)
        self.assertTrue(calls[-1][0][-1].startswith('rm -rf -- /var/tmp/ipa-su-'))
        self.assertTrue(all('-tt' not in args for args,_ in calls))

if __name__ == '__main__': unittest.main()
