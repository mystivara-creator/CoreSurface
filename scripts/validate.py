#!/usr/bin/env python3
"""Host-only validations; runtime kernel/Android compatibility is NOT tested."""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
ROOT=Path(__file__).resolve().parents[1]
MOD=ROOT/'module'
REQUIRED=('README.md','CHANGELOG.md','ROADMAP.md','SECURITY.md','LICENSE',
'docs/FEATURE_MATRIX.md','docs/EVIDENCE_INDEX.md','docs/ROLLBACK.md','docs/ARCHITECTURE.md','docs/TEST_PLAN.md',
'docs/audits/2026-11-02-capabilities.md','docs/audits/2026-11-02-camera-apk.md',
'module/README.md','module/module.prop','module/compat.conf','module/customize.sh','module/post-fs-data.sh',
'module/service.sh','module/control.sh','module/prepare-overlay.sh','module/webroot/index.html')
def verify(ok,msg):
    if not ok: raise AssertionError(msg)
def main():
    for path in REQUIRED: verify((ROOT/path).is_file(), 'missing '+path)
    verify(not (MOD/'baseline/kunzite.xml').exists(),'Do not commit proprietary XML')
    verify('id=kunzite_wcg_probe' in (MOD/'module.prop').read_text(),'module ID drift')
    for file in ['customize.sh','post-fs-data.sh','service.sh','control.sh','prepare-overlay.sh']:
        p=subprocess.run(['sh','-n',str(MOD/file)],capture_output=True,text=True)
        verify(p.returncode==0, file+' invalid syntax: '+p.stderr)
    installer=(MOD/'customize.sh').read_text()
    boot=(MOD/'post-fs-data.sh').read_text()
    for shell_text in (installer, boot):
        verify('AUDITED_XML_SHA=' in shell_text and 'sha256sum' in shell_text,
               'missing source/firmware checksum gate')
    ui=(MOD/'webroot/index.html').read_text()
    for required in ['sf_wcg','wcg_property','active_color','p3_available']:
        verify(required in ui,'missing WebUI status: '+required)
    if shutil.which('node'):
        scripts=re.findall(r'<script(?:\s[^>]*)?>(.*?)</script>',ui,re.S|re.I)
        verify(len(scripts)==1,'expected one webui script')
        with tempfile.TemporaryDirectory() as tmp:
            js=Path(tmp)/'webui.js';js.write_text(scripts[0])
            p=subprocess.run(['node','--check',str(js)],capture_output=True,text=True)
            verify(p.returncode==0,'WebUI syntax: '+p.stderr)
    p=subprocess.run([sys.executable,'-m','unittest','discover','-s',str(ROOT/'scripts/tests'),'-v'],cwd=ROOT)
    verify(p.returncode==0,'unit tests failed')
    print('PASS: static syntax, tests and source inventory; Android runtime NOT tested')
if __name__=='__main__':
    try:main()
    except AssertionError as exc:
        print('FAIL:',exc,file=sys.stderr)
        sys.exit(1)
