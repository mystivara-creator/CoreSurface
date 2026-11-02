#!/usr/bin/env python3
"""Deterministic KernelSU archive; never include proprietary vendor XML."""
import argparse
import hashlib
from pathlib import Path
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / 'module'
EXPECTED_SHA = '3b434af171d5d14d1a7c4fa40097dc5c6a5b19e8e4dd0515c37a38d23d3fd48f'
NAME = 'kunzite_capability_suite_v0.6.5-preview.zip'
FILES = ('README.md','module.prop','compat.conf','customize.sh','post-fs-data.sh','service.sh','control.sh','prepare-overlay.sh','stage-meta-overlayfs.sh','webroot/index.html')
EXECUTABLES = {'customize.sh','post-fs-data.sh','service.sh','control.sh','prepare-overlay.sh','stage-meta-overlayfs.sh'}

def verify_stock(path: Path, sha=EXPECTED_SHA):
    data = path.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != sha:
        raise ValueError('XML stock fingerprint mismatch; ROM outside audited baseline: '+actual)
    doc = ET.fromstring(data)
    for name in ('support_display_expert_mode','support_video_hfr_mode'):
        vals = [(e.text or '').strip().lower() for e in doc.iter('bool') if e.attrib.get('name') == name]
        if vals != ['false']:
            raise ValueError('Missing/changed baseline flag: '+name)
    return actual

def pack(output: Path):
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name in FILES:
            info = zipfile.ZipInfo(name, date_time=(2026, 11, 2, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = ((0o100755 if name in EXECUTABLES else 0o100644) << 16)
            archive.writestr(info, (MODULE/name).read_bytes())
    with zipfile.ZipFile(output) as archive:
        if archive.testzip() is not None or set(archive.namelist()) != set(FILES):
            raise RuntimeError('ZIP verification failed')

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stock-xml',type=Path,help='Optional preflight only; never bundled')
    parser.add_argument('--output',type=Path,default=ROOT/'dist'/NAME)
    args=parser.parse_args()
    try:
        if args.stock_xml: verify_stock(args.stock_xml)
        pack(args.output)
    except (OSError,ValueError,ET.ParseError) as exc:
        parser.exit(2, 'BUILD REFUSED: '+str(exc)+'\n')
    print('Created:',args.output)

if __name__=='__main__':
    main()
