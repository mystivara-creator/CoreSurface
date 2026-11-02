from pathlib import Path
import subprocess
import unittest

SCRIPT=Path(__file__).resolve().parents[2]/'collect-vulkan.sh'
class VulkanAuditTests(unittest.TestCase):
    def test_shell_syntax_and_read_only(self):
        proc=subprocess.run(['sh','-n',str(SCRIPT)],capture_output=True,text=True)
        self.assertEqual(proc.returncode,0,proc.stderr)
        content=SCRIPT.read_text()
        for forbidden in ('resetprop ','setprop ','mount -','insmod ','chmod ','chown ','rm -rf ','dd if='):
            self.assertNotIn(forbidden,content)
        self.assertIn('vulkaninfo',content)
