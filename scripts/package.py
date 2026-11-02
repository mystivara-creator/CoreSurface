#!/usr/bin/env python3
"""Pack KernelSU preview from the exact audited stock XML (kept out of Git)."""
import argparse
import hashlib
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / 'module'
EXPECTED_SHA = '3b434af171d5d14d1a7c4fa40097dc5c6a5b19e8e4dd0515c37a38d23d3fd48f'
NAME = 'kunzite_capability_suite_v0.6.0-preview.zip'
FILES = ('README.md','module.prop','compat.conf','customize.sh','post-fs-data.sh','service.sh','control.sh','prepare-overlay.sh','webroot/index.html')
EXECUTABLES = {'customize.sh','post-fs-data.sh','service.sh','control.sh','prepare-overlay.sh'}


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


def pack(stock: Path, output: Path):
    verify_stock(stock)
    output.parent.mkdir(parents=True,exist_ok=True)
    with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
        for name in FILES+('baseline/kunzite.xml',):
            src=stock if name=='baseline/kunzite.xml' else MODULE/name
            info=zipfile.ZipInfo(name,date_time=(2026,11,2,0,0,0))
            info.compress_type=zipfile.ZIP_DEFLATED
            info.external_attr=((0o100755 if name in EXECUTABLES else 0o100644)<<16)
            z.writestr(info,src.read_bytes())
    with zipfile.ZipFile(output) as z:
        if z.testzip() is not None or set(z.namelist())!=set(FILES)|{'baseline/kunzite.xml'}:
            raise RuntimeError('ZIP validation failed')


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--stock-xml',required=True,type=Path)
    p.add_argument('--output',type=Path,default=ROOT/'dist'/NAME)
    a=p.parse_args()
    try: pack(a.stock_xml,a.output)
    except (OSError,ValueError,ET.ParseError) as e:
        p.exit(2,'BUILD REFUSED: '+str(e)+'\n')
    print('Created:',a.output)

if __name__=='__main__': main()
