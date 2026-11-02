"""Host simulation of post-boot validation without mounting or writing Android partitions."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2] / 'module' / 'service.sh'
BASE = '<?xml version="1.0"?><features><bool name="support_display_expert_mode">{expert}</bool><bool name="support_video_hfr_mode">{hfr}</bool></features>'


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.module = self.root / 'module'
        self.module.mkdir()
        self.xml = self.root / 'mounted.xml'
        # Only the hard-coded Android path is replaced in the isolated test copy.
        source = SOURCE.read_text()
        source = source.replace('/product/etc/device_features/kunzite.xml', str(self.xml))
        self.script = self.module / 'service.sh'
        self.script.write_text(source)
        command_dir = self.root / 'bin'
        command_dir.mkdir()
        getprop = command_dir / 'getprop'
        getprop.write_text('#!/bin/sh\n[ "$1" = sys.boot_completed ] && echo 1\n')
        getprop.chmod(0o755)
        self.env = dict(os.environ, PATH=str(command_dir) + os.pathsep + os.environ.get('PATH', ''))

    def run_service(self, expected=0):
        proc = subprocess.run(['/bin/sh',str(self.script)],env=self.env,capture_output=True,text=True)
        self.assertEqual(proc.returncode,expected,proc.stdout+proc.stderr)

    def setup_pending(self,expert=False,hfr=False,expert_runtime='false',hfr_runtime='false'):
        (self.module/'boot_pending').touch()
        if expert: (self.module/'expert_enabled').touch()
        if hfr: (self.module/'hfr_enabled').touch()
        self.xml.write_text(BASE.format(expert=expert_runtime,hfr=hfr_runtime))

    def test_no_experiment_pending(self):
        self.run_service()
        self.assertFalse((self.module/'boot_result.txt').exists())

    def test_verified_expert_clears_pending(self):
        self.setup_pending(expert=True,expert_runtime='true')
        self.run_service()
        self.assertFalse((self.module/'boot_pending').exists())
        self.assertIn('EXPERIMENTAL_XML_VERIFIED',(self.module/'boot_result.txt').read_text())

    def test_stale_hfr_marker_does_not_gate_boot(self):
        self.setup_pending(hfr=True,hfr_runtime='false')
        self.run_service()
        self.assertFalse((self.module/'boot_pending').exists())

    def test_wrong_effective_flag_triggers_rollback_next_boot(self):
        self.setup_pending(expert=True,expert_runtime='false')
        self.run_service(expected=1)
        self.assertTrue((self.module/'boot_pending').exists())
        self.assertIn('EXPERT_FLAG_NOT_MOUNTED',(self.module/'recovery_reason').read_text())
        self.assertIn('EXPERIMENTAL_RUNTIME_FAILED',(self.module/'boot_result.txt').read_text())

    def test_expert_verifies_even_when_stock_hfr_is_false(self):
        self.setup_pending(expert=True,hfr=True,expert_runtime='true',hfr_runtime='false')
        self.run_service()
        self.assertFalse((self.module/'boot_pending').exists())

    def test_missing_runtime_xml_triggers_recovery(self):
        self.setup_pending(expert=True)
        self.xml.unlink()
        self.run_service(expected=1)
        self.assertEqual((self.module/'recovery_reason').read_text().strip(),'OEM_XML_UNREADABLE')

if __name__ == '__main__':
    unittest.main()
