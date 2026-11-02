"""Simulate meta-overlayfs image staging without mounting any filesystem."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'module' / 'stage-meta-overlayfs.sh'
FIXTURE = '<features><bool name="support_display_expert_mode">true</bool></features>'


class MetaOverlayStageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.meta = self.root/'metamodule'
        self.meta.mkdir()
        (self.meta/'module.prop').write_text('id=meta-overlayfs\n')
        (self.meta/'modules.img').write_bytes(b'fake image; no real mounting')
        (self.meta/'mnt').mkdir()
        self.mod = self.root/'module'
        (self.mod/'product/etc/device_features').mkdir(parents=True)
        self.stage = self.mod/'stage-meta-overlayfs.sh'
        self.stock = self.root/'stock.xml'
        self.stock.write_text(FIXTURE)
        script = SCRIPT.read_text().replace('/data/adb/metamodule', str(self.meta))
        script = script.replace('STOCK=/product/etc/device_features/kunzite.xml', 'STOCK='+str(self.stock))
        self.stage.write_text(script)
        (self.mod/'product/etc/device_features/kunzite.xml').write_text(FIXTURE)
        (self.mod/'skip_mount').touch()
        bindir = self.root/'bin'
        bindir.mkdir()
        mountpoint = bindir/'mountpoint'
        mountpoint.write_text('#!/bin/sh\nexit 0\n')
        mountpoint.chmod(0o755)
        self.env = dict(os.environ, PATH=str(bindir)+os.pathsep+os.environ.get('PATH',''))

    def run_stage(self, expected=0):
        p = subprocess.run(['/bin/sh',str(self.stage)],env=self.env,capture_output=True,text=True)
        self.assertEqual(p.returncode,expected,p.stdout+p.stderr)
        return p

    def destination(self):
        return self.meta/'mnt/kunzite_wcg_probe/product/etc/device_features/kunzite.xml'

    def test_correct_partition_content_and_gate(self):
        p=self.run_stage()
        self.assertIn('META_OVERLAY_STAGED',p.stdout)
        self.assertEqual(self.destination().read_text(), FIXTURE)
        self.assertFalse((self.mod/'skip_mount').exists())

    def test_reject_unknown_metamodule_without_removing_gate(self):
        (self.meta/'module.prop').write_text('id=unknown\n')
        self.run_stage(expected=22)
        self.assertTrue((self.mod/'skip_mount').exists())
        self.assertFalse(self.destination().exists())

    def test_reject_absent_image_without_removing_gate(self):
        (self.meta/'modules.img').unlink()
        self.run_stage(expected=23)
        self.assertTrue((self.mod/'skip_mount').exists())
        self.assertFalse(self.destination().exists())

    def test_missing_source_file_is_closed(self):
        (self.mod/'product/etc/device_features/kunzite.xml').unlink()
        self.run_stage(expected=21)
        self.assertTrue((self.mod/'skip_mount').exists())

if __name__=='__main__':
    unittest.main()
