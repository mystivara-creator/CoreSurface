"""Black-box host tests for root control command without any Android writes."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2] / 'module' / 'control.sh'


class ControlTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.mod = self.root / 'module'
        self.mod.mkdir()
        self.script = self.mod / 'control.sh'
        shutil.copyfile(SOURCE, self.script)
        commands = self.root / 'bin'
        commands.mkdir()
        getprop = commands / 'getprop'
        getprop.write_text('''#!/bin/sh
case "$1" in
ro.product.device) printf '%s\n' "${TEST_DEVICE:-kunzite}";;
ro.board.platform) printf '%s\n' "${TEST_BOARD:-parrot}";;
ro.system.build.version.incremental) printf '%s\n' "${TEST_ROM:-16OS3.1.260918.151434134.QCPEGL.S}";;
ro.surface_flinger.has_wide_color_display) echo false;;
esac
''')
        getprop.chmod(0o755)
        self.env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ.get('PATH',''))

    def run_control(self, *args, env=None, ok=True):
        p = subprocess.run(['/bin/sh', str(self.script), *args],
                           capture_output=True, text=True, env=env or self.env)
        if ok:
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        else:
            self.assertNotEqual(p.returncode, 0, p.stdout + p.stderr)
        return p.stdout

    def test_wcg_on_off_idempotent(self):
        self.assertIn('wcg_next=on', self.run_control('status'))
        self.assertIn('OK: wcg=off', self.run_control('set','wcg','off'))
        self.assertIn('wcg_next=off', self.run_control('status'))
        self.assertIn('OK: wcg=off', self.run_control('set','wcg','off'))
        self.assertTrue((self.mod/'wcg_disabled').exists())
        self.assertIn('OK: wcg=on', self.run_control('set','wcg','on'))
        self.assertIn('wcg_next=on', self.run_control('status'))
        self.assertFalse((self.mod/'wcg_disabled').exists())

    def test_reject_unrecognized_feature_and_value(self):
        self.assertIn('INVALID_FEATURE', self.run_control('set','hdr','on',ok=False))
        self.assertIn('INVALID_VALUE', self.run_control('set','wcg','sometimes',ok=False))
        self.assertFalse((self.mod/'wcg_disabled').exists())

    def test_experimental_toggle_does_not_modify_live_overlay(self):
        # Substitute only the KernelSU metamodule symlink path in test copy.
        fake_meta=self.root/'metamodule'
        fake_meta.touch()
        self.script.write_text(self.script.read_text().replace(
            '/data/adb/metamodule',str(fake_meta)))
        mounted=self.mod/'system/product/etc/device_features'
        mounted.mkdir(parents=True)
        installed=mounted/'kunzite.xml'
        installed.write_text('active-overlay: DO NOT DELETE WHILE MOUNTED')
        self.assertIn('OK: expert=on',self.run_control('set','expert','on'))
        self.assertTrue((self.mod/'expert_enabled').exists())
        self.assertEqual(installed.read_text(),'active-overlay: DO NOT DELETE WHILE MOUNTED')
        self.assertIn('OK: expert=off',self.run_control('set','expert','off'))
        self.assertFalse((self.mod/'expert_enabled').exists())
        self.assertEqual(installed.read_text(),'active-overlay: DO NOT DELETE WHILE MOUNTED')

    def test_incompatible_rom_blocks_write(self):
        env=dict(self.env,TEST_ROM='unknown-firmware')
        self.assertIn('BLOCKED: unsupported firmware',
                      self.run_control('set','wcg','off',env=env,ok=False))
        self.assertFalse((self.mod/'wcg_disabled').exists())
        self.assertIn('device=unsupported_or_updated',self.run_control('status',env=env))

    def test_expert_hfr_blocked_without_metamodule(self):
        # In host CI, /data/adb/metamodule should not exist. Otherwise skip.
        if Path('/data/adb/metamodule').exists():
            self.skipTest('Metamodule detected on host')
        for feature in ('expert','hfr'):
            self.assertIn('BLOCKED: KernelSU metamodule required',
                          self.run_control('set',feature,'on',ok=False))
            self.assertFalse((self.mod/f'{feature}_enabled').exists())


if __name__ == '__main__':
    unittest.main()
