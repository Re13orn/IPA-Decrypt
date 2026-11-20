"""Regression checks for public export boundaries and locked dependency bytes."""
import importlib.util,json,sys,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
from source_files import files
spec=importlib.util.spec_from_file_location('dependencies',ROOT/'scripts/verify-dependencies.py')
verify=importlib.util.module_from_spec(spec);spec.loader.exec_module(verify)
class ReleaseInputs(unittest.TestCase):
 def test_public_export_excludes_every_unreviewed_input(self):
  exported={p.relative_to(ROOT).as_posix() for p in files()}
  assets=json.loads((ROOT/'dependencies/external-assets.lock.json').read_text())['assets']
  self.assertEqual(len(assets),13)
  self.assertTrue(exported.isdisjoint({x['path'] for x in assets}))
  self.assertFalse(any(p.endswith('.a') or '.xcframework/' in p for p in exported))
  self.assertIn('licenses/upstream/Go-BSD-3-Clause.txt',exported)
 def test_tree_digest_detects_change_but_ignores_generated_subtree(self):
  with tempfile.TemporaryDirectory() as temp:
   root=Path(temp);(root/'source.c').write_text('original');(root/'build').mkdir();(root/'build/generated.a').write_text('old')
   before=verify.tree_digest(root,['build'])
   (root/'build/generated.a').write_text('new');self.assertEqual(before,verify.tree_digest(root,['build']))
   (root/'source.c').write_text('changed');self.assertNotEqual(before,verify.tree_digest(root,['build']))
 def test_requirements_match_wheel_locks(self):
  wheels=json.loads((ROOT/'dependencies/python-macos-arm64.lock.json').read_text())['wheels']
  lines=[x for x in (ROOT/'dependencies/requirements-macos-arm64.lock').read_text().splitlines() if x and not x.startswith('#')]
  self.assertEqual(set(lines),{x['name']+'=='+x['version']+' --hash=sha256:'+x['sha256'] for x in wheels})
if __name__=='__main__':unittest.main()
