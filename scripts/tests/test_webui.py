"""Regression test for KernelSU WebUI bridge responses (Node optional)."""
from pathlib import Path
import shutil
import subprocess
import unittest

@unittest.skipUnless(shutil.which('node'), 'Node.js not installed')
class WebUIBridgeTests(unittest.TestCase):
    def test_bridge_status_reads(self):
        script = Path(__file__).with_name('webui_bridge.cjs')
        result = subprocess.run(['node', str(script)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

if __name__ == '__main__':
    unittest.main()
