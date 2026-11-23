"""Reject incomplete or development-machine-dependent distribution bundles."""
import hashlib,importlib.util,json,os,plistlib,shutil,subprocess,tempfile,unittest,zipfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('installation',ROOT/'scripts/verify-installation.py');installation=importlib.util.module_from_spec(spec);spec.loader.exec_module(installation)
class InstallationBundleTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.work=tempfile.TemporaryDirectory();cls.root=Path(cls.work.name);cls.main=cls.root/'main';cls.external=cls.root/'external'
  # Structural bundle fixtures are self-contained; real engine execution is covered
  # by the packaged app's empty-cache/offline smoke check.
  cls.proof_archive=cls.root/'unicorn.whl';member='unicorn/lib/libunicorn.2.dylib';data=b'synthetic structural proof fixture'
  with zipfile.ZipFile(cls.proof_archive,'w') as archive:archive.writestr(member,data)
  cls.proof={'sha256':hashlib.sha256(cls.proof_archive.read_bytes()).hexdigest(),'member':member,'library_sha256':hashlib.sha256(data).hexdigest()}

  subprocess.run(['xcrun','clang','-arch','arm64','-mmacosx-version-min=15.0','-x','c','-','-o',str(cls.main)],input=b'int main(void){return 0;}',check=True,capture_output=True)
  library=cls.root/'libfixture.dylib'
  subprocess.run(['xcrun','clang','-arch','arm64','-mmacosx-version-min=15.0','-dynamiclib','-install_name','/opt/homebrew/lib/libfixture.dylib','-x','c','-','-o',str(library)],input=b'int fixture(void){return 1;}',check=True,capture_output=True)
  subprocess.run(['xcrun','clang','-arch','arm64','-mmacosx-version-min=15.0','-x','c','-','-x','none',str(library),'-o',str(cls.external)],input=b'extern int fixture(void);int main(void){return fixture();}',check=True,capture_output=True)
 @classmethod
 def tearDownClass(cls):cls.work.cleanup()
 def inspect(self,app,platform):
  return installation.inspect(app,platform,proof_lock=self.proof)
 def make_bundle(self,root):
  app=root/'Fixture.app';contents=app/'Contents';(contents/'MacOS').mkdir(parents=True);r=contents/'Resources';runtime=r/'NativeStoreRuntime';runtime.mkdir(parents=True)
  (contents/'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'Fixture','LSMinimumSystemVersion':'15.0','CFBundleShortVersionString':'1.0'}));shutil.copyfile(self.main,contents/'MacOS/Fixture');(contents/'MacOS/Fixture').chmod(0o755)
  data=b'fixture';(runtime/'sap.wasm').write_bytes(data);(runtime/'PROVENANCE.json').write_text(json.dumps({'sha256':{'sap.wasm':hashlib.sha256(data).hexdigest()}}))
  for name in ['index.html','ipalab.mjs']:(runtime/name).write_text('fixture')
  (r/'Storefronts.plist').write_bytes(plistlib.dumps({'143441':'us'}))
  names=['Python/bin/python3','Extractor/host.py','Extractor/license_plan.py','Extractor/askpass','bin/idevice_id','bin/ideviceinfo','bin/iproxy','bin/unfairplay']+['Extractor/bundle/'+x for x in ['credential.ios','driver.ios','trigger.ios','arcade-capture.ios','static-key-table.bin','core4-word-table.bin']]
  for name in names:
   file=r/name;file.parent.mkdir(parents=True,exist_ok=True);file.write_text('fixture');file.chmod(0o755)
  proof=r/'StoreRuntime/unicorn.whl';proof.parent.mkdir();shutil.copyfile(self.proof_archive,proof)
  return app
 def test_missing_or_changed_proof_engine_rejected(self):
  with tempfile.TemporaryDirectory() as tmp:
   app=self.make_bundle(Path(tmp));proof=app/'Contents/Resources/StoreRuntime/unicorn.whl';proof.unlink()
   with self.assertRaisesRegex(installation.InvalidBundle,'Missing Store proof'):self.inspect(app,'macos')
   proof.write_bytes(b'corrupt')
   with self.assertRaisesRegex(installation.InvalidBundle,'Changed Store proof'):self.inspect(app,'macos')
 def test_proof_library_tampering_rejected_even_with_valid_archive_hash(self):
  with tempfile.TemporaryDirectory() as tmp:
   app=self.make_bundle(Path(tmp));proof=app/'Contents/Resources/StoreRuntime/unicorn.whl'
   with zipfile.ZipFile(proof,'w') as archive:archive.writestr(self.proof['member'],b'changed library')
   manifest=dict(self.proof,sha256=hashlib.sha256(proof.read_bytes()).hexdigest())
   with self.assertRaisesRegex(installation.InvalidBundle,'Changed Store proof engine library'):
    installation.inspect(app,'macos',proof_lock=manifest)
 def test_complete_bundle_passes_and_missing_wasm_fails(self):
  with tempfile.TemporaryDirectory() as tmp:
   app=self.make_bundle(Path(tmp));self.assertEqual(self.inspect(app,'macos')['mach_o_checked'],1)
   (app/'Contents/Resources/NativeStoreRuntime/sap.wasm').unlink()
   with self.assertRaisesRegex(installation.InvalidBundle,'Missing runtime'):self.inspect(app,'macos')
 def test_homebrew_dependency_rejected_even_when_main_exists(self):
  with tempfile.TemporaryDirectory() as tmp:
   app=self.make_bundle(Path(tmp));shutil.copyfile(self.external,app/'Contents/MacOS/Fixture')
   with self.assertRaisesRegex(installation.InvalidBundle,'External dependency'):self.inspect(app,'macos')
 def test_helper_requiring_newer_os_than_declared_is_rejected(self):
  with tempfile.TemporaryDirectory() as tmp:
   app=self.make_bundle(Path(tmp));helper=app/'Contents/Resources/bin/iproxy'
   subprocess.run(['xcrun','clang','-arch','arm64','-mmacosx-version-min=26.0','-x','c','-','-o',str(helper)],input=b'int main(void){return 0;}',check=True,capture_output=True)
   with self.assertRaisesRegex(installation.InvalidBundle,'Binary requires newer OS.*iproxy'):self.inspect(app,'macos')
 def test_private_state_and_simulator_distribution_rejected(self):
  with tempfile.TemporaryDirectory() as tmp:
   app=self.make_bundle(Path(tmp));(app/'Contents/Resources/accounts-v2.json').write_text('{}')
   with self.assertRaisesRegex(installation.InvalidBundle,'User state'):self.inspect(app,'macos')
   ios=Path(tmp)/'Simulator.app';ios.mkdir();shutil.copyfile(self.main,ios/'Fixture');(ios/'Fixture').chmod(0o755)
   (ios/'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'Fixture','CFBundleSupportedPlatforms':['iPhoneSimulator']}))
   with self.assertRaisesRegex(installation.InvalidBundle,'not Simulator'):self.inspect(ios,'ios')
 def test_ipa_inspection_preserves_archived_executable_bits(self):
  with tempfile.TemporaryDirectory() as tmp:
   archive=Path(tmp)/'fixture.ipa'
   with zipfile.ZipFile(archive,'w') as z:
    member=zipfile.ZipInfo('Payload/Test.app/Test');member.create_system=3;member.external_attr=0o100755 << 16;z.writestr(member,b'fixture')
   directory=Path(tmp)/'extracted'
   with zipfile.ZipFile(archive) as z:installation.extract_ipa(z,directory)
   self.assertTrue(os.access(directory/'Payload/Test.app/Test',os.X_OK))
if __name__=='__main__':unittest.main()
