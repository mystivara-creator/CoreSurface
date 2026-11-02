"""Exercise the real overlay script with synthetic (non-OEM) XML."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'module' / 'prepare-overlay.sh'
BASELINE = '<?xml version="1.0"?>\n<features>\n  <bool name="support_display_expert_mode">false</bool>\n  <bool name="support_video_hfr_mode">false</bool>\n  <bool name="support_3d_face_beauty">true</bool>\n</features>\n'

class OverlayTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'baseline').mkdir()
        (self.root / 'baseline/kunzite.xml').write_text(BASELINE)
        shutil.copyfile(SCRIPT, self.root / 'prepare-overlay.sh')

    def run_overlay(self, ok=True):
        p = subprocess.run(['/bin/sh', str(self.root / 'prepare-overlay.sh')],
                           capture_output=True, text=True)
        if ok:
            self.assertEqual(p.returncode, 0, p.stderr)
        else:
            self.assertNotEqual(p.returncode, 0)
        return p

    def xml(self):
        return (self.root / 'product/etc/device_features/kunzite.xml')

    def test_default_does_not_mount(self):
        self.run_overlay()
        self.assertTrue((self.root / 'skip_mount').exists())
        self.assertFalse(self.xml().exists())

    def test_expert_only_changes_expert(self):
        (self.root / 'expert_enabled').touch()
        self.run_overlay()
        data = self.xml().read_text()
        self.assertIn('name="support_display_expert_mode">true', data)
        self.assertIn('name="support_video_hfr_mode">false', data)
        self.assertIn('name="support_3d_face_beauty">true', data)
        self.assertTrue((self.root / 'skip_mount').exists())
        self.assertEqual((self.root / 'baseline/kunzite.xml').read_text(), BASELINE)

    def test_legacy_hfr_marker_is_ignored(self):
        (self.root / 'hfr_enabled').touch()
        self.run_overlay()
        self.assertTrue((self.root / 'skip_mount').exists())
        self.assertFalse(self.xml().exists())

    def test_expert_never_changes_stock_hfr_even_with_legacy_marker(self):
        for name in ('expert_enabled', 'hfr_enabled'):
            (self.root / name).touch()
        self.run_overlay()
        data = self.xml().read_text()
        self.assertIn('name="support_display_expert_mode">true', data)
        self.assertIn('name="support_video_hfr_mode">false', data)
        (self.root / 'expert_enabled').unlink()
        self.run_overlay()
        self.assertTrue((self.root / 'skip_mount').exists())
        self.assertFalse(self.xml().exists())

    def test_duplicate_flag_rejected(self):
        (self.root / 'expert_enabled').touch()
        tag = '<bool name="support_display_expert_mode">false</bool>'
        bad = BASELINE.replace(tag, tag * 2)
        (self.root / 'baseline/kunzite.xml').write_text(bad)
        self.run_overlay(ok=False)
        self.assertFalse(self.xml().exists())

    def test_missing_baseline_rejected(self):
        (self.root / 'expert_enabled').touch()
        (self.root / 'baseline/kunzite.xml').unlink()
        self.run_overlay(ok=False)
        self.assertFalse(self.xml().exists())

if __name__ == '__main__':
    unittest.main()
