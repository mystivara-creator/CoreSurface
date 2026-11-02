"""Host mock validates install-time baseline capture without Android writes."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

INSTALL=Path(__file__).resolve().parents[2]/'module/customize.sh'
FIXTURE=b'<features>\n<bool name="support_display_expert_mode">false</bool>\n<bool name="support_video_hfr_mode">false</bool>\n</features>\n'
EXPECTED='3b434af171d5d14d1a7c4fa40097dc5c6a5b19e8e4dd0515c37a38d23d3fd48f'

class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.mod=self.root/'module'
        self.mod.mkdir()
        self.stock=self.root/'stock.xml'
        self.stock.write_bytes(FIXTURE)
        self.script=self.root/'customize.sh'
        source=INSTALL.read_text()
        source=source.replace('STOCK_XML=/product/etc/device_features/kunzite.xml',
                              'STOCK_XML='+str(self.stock))
        source=source.replace('AUDITED_XML_SHA='+EXPECTED,
                              'AUDITED_XML_SHA='+hashlib.sha256(FIXTURE).hexdigest())
        self.script.write_text(source)
        bin_dir=self.root/'bin'
        bin_dir.mkdir()
        getprop=bin_dir/'getprop'
        getprop.write_text('''#!/bin/sh
case "$1" in
ro.product.device) echo kunzite;;
ro.board.platform) echo parrot;;
ro.system.build.version.incremental) echo 16OS3.1.260918.151434134.QCPEGL.S;;
esac
''')
        getprop.chmod(0o755)
        self.env=dict(os.environ, MODPATH=str(self.mod),
                      PATH=str(bin_dir)+os.pathsep+os.environ.get('PATH',''))

    def install(self, success=True):
        wrapper='abort(){ echo "ABORT:$*"; exit 12; }; ui_print(){ :; }; set_perm(){ :; }; . "$1"'
        result=subprocess.run(['/bin/sh','-c',wrapper,'installer-test',str(self.script)],
                              capture_output=True,text=True,env=self.env)
        self.assertEqual(result.returncode==0,success,result.stdout+result.stderr)

    def test_ksu_sourced_customizer_does_not_change_parent_shell(self):
        # KernelSU sources customize.sh and set_perm reads optional $5.
        # The previous set -eu killed the outer installer here.
        wrapper = ('''
abort(){ echo "ABORT:$*"; exit 12; }
ui_print(){ printf '%s\\n' "$1"; }
set_perm(){ local CON=$5; return 0; }
. "$1" || exit 87
case $- in *e*|*u*) echo "UNSAFE_SHELL_FLAGS:$-"; exit 88;; esac
echo INSTALLER_CONTINUES
''')
        p = subprocess.run(['/bin/sh', '-c', wrapper, 'ksu-install', str(self.script)],
                           capture_output=True, text=True, env=self.env)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn('INSTALLER_CONTINUES', p.stdout)
        self.assertIn('One module: existing WCG module', p.stdout)

    def test_permission_failure_has_named_abort(self):
        wrapper = ('''
abort(){ echo "ABORT:$*"; exit 12; }
ui_print(){ printf '%s\\n' "$1"; }
set_perm(){ return 1; }
. "$1"
echo INVALID_SUCCESS
''')
        p = subprocess.run(['/bin/sh', '-c', wrapper, 'ksu-install', str(self.script)],
                           capture_output=True, text=True, env=self.env)
        self.assertEqual(p.returncode, 12, p.stdout + p.stderr)
        self.assertIn('ABORT:Cannot set post-fs-data permissions', p.stdout)
        self.assertNotIn('INVALID_SUCCESS', p.stdout)

    def test_capture_valid_device_xml(self):
        self.install()
        self.assertEqual((self.mod/'baseline/kunzite.xml').read_bytes(),FIXTURE)
        self.assertEqual(self.stock.read_bytes(),FIXTURE)
        self.assertTrue((self.mod/'skip_mount').is_file())

    def test_reject_modified_stock(self):
        self.stock.write_bytes(b'<unknown/>')
        self.install(success=False)
        self.assertFalse((self.mod/'baseline/kunzite.xml').exists())

    def test_reject_stale_existing_baseline(self):
        target=self.mod/'baseline'
        target.mkdir()
        (target/'kunzite.xml').write_bytes(b'bad')
        self.install(success=False)
        self.assertEqual((target/'kunzite.xml').read_bytes(),b'bad')

if __name__=='__main__':
    unittest.main()
