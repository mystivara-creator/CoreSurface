from pathlib import Path
import hashlib
import importlib.util
import tempfile
import unittest
P=Path(__file__).resolve().parents[1]/'package.py'
spec=importlib.util.spec_from_file_location('packager',P)
packager=importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)
class PackageTests(unittest.TestCase):
 def test_reject_unknown_stock(self):
  with tempfile.TemporaryDirectory() as d:
   p=Path(d)/'stock.xml';p.write_text('<root/>')
   with self.assertRaisesRegex(ValueError,'fingerprint mismatch'): packager.verify_stock(p)
 def test_reject_changed_flag(self):
  with tempfile.TemporaryDirectory() as d:
   p=Path(d)/'stock.xml';data=b'<root><bool name="support_display_expert_mode">true</bool><bool name="support_video_hfr_mode">false</bool></root>';p.write_bytes(data)
   with self.assertRaisesRegex(ValueError,'baseline flag'): packager.verify_stock(p,hashlib.sha256(data).hexdigest())
 def test_accept_synthetic_fixture_under_test_only_hash(self):
  with tempfile.TemporaryDirectory() as d:
   p=Path(d)/'stock.xml';data=b'<root><bool name="support_display_expert_mode">false</bool><bool name="support_video_hfr_mode">false</bool></root>';p.write_bytes(data)
   sha=hashlib.sha256(data).hexdigest();self.assertEqual(packager.verify_stock(p,sha),sha)
 def test_module_manifest(self):
  self.assertEqual(len(packager.FILES),10)
  self.assertIn('post-fs-data.sh',packager.EXECUTABLES)
  for f in packager.FILES:self.assertTrue((packager.MODULE/f).is_file())
if __name__=='__main__':unittest.main()
