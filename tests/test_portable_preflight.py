import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('preflight',ROOT/'portable/preflight.py')
p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)
class PortablePreflightTests(unittest.TestCase):
 def test_pins_match_driver(self):
  self.assertEqual(p.CHAIN_ID,2026112403)
  self.assertEqual(set(p.pins()),{'besu-26.11.1.tar.gz','OpenJDK25U-jdk_aarch64_mac_hotspot_25.0.5.1_2.tar.gz','soljson-0.8.28.js'})
 def test_missing_tools_are_not_ready(self):
  with tempfile.TemporaryDirectory() as folder:
   r=p.tool_report(folder)
   self.assertNotEqual(r['status'],'ready');self.assertTrue(all(v=='missing' for v in r['archives'].values()))
 def test_no_tools_is_explicit(self):
  self.assertEqual(p.tool_report(None)['status'],'tools_not_supplied')
 def test_unsupported_arch_no_model_probe(self):
  with patch.object(p.platform,'machine',return_value='x86_64'),patch.object(p.subprocess,'run') as run:
   r=p.check();self.assertEqual(r['apple']['status'],'platform_unsupported');self.assertFalse(r['ready']);run.assert_not_called()
 def test_changed_archive_is_rejected(self):
  with tempfile.TemporaryDirectory() as folder:
   for name in p.pins():(Path(folder)/name).write_bytes(b'SYNTHETIC INVALID ARCHIVE')
   r=p.tool_report(folder);self.assertTrue(all(v=='hash_mismatch' for v in r['archives'].values()));self.assertNotEqual(r['status'],'ready')

class BesuPathTests(unittest.TestCase):
 @unittest.skipUnless(Path("/bin/sh").is_file(),"Besu launcher word parsing needs a POSIX shell")
 def test_real_launcher_word_parsing_preserves_quoted_paths(self):
  import os,subprocess
  from vape.ledger.local_exercise import besu_jvm_options
  with tempfile.TemporaryDirectory() as folder:
   root=Path(folder)/"A Folder's $(not_a_command)"
   result=subprocess.run(['/bin/sh','-c','eval set -- $BESU_OPTS; printf "%s\\n" "$@"'],env={'PATH':os.environ.get('PATH',''),'BESU_OPTS':besu_jvm_options(root)},capture_output=True,text=True,check=True)
   self.assertEqual(result.stdout.splitlines(),['-Xmx512m','-Djava.io.tmpdir='+str(root/'tmp'),'-Duser.home='+str(root/'home')])
   self.assertEqual(result.stderr,'')
