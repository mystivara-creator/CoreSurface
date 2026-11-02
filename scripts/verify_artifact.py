#!/usr/bin/env python3
"""Check distributable artifact payload, file modes and SHA-256."""
import argparse
import hashlib
from pathlib import Path
import zipfile
from package import FILES, EXECUTABLES, NAME

def verify(path):
    with zipfile.ZipFile(path) as archive:
        entries=archive.namelist()
        assert len(entries)==len(set(entries)), 'duplicate entries'
        assert set(entries)==set(FILES), 'unexpected file list'
        assert archive.testzip() is None, 'invalid ZIP data'
        for name in entries:
            assert not name.startswith('/') and '..' not in Path(name).parts, 'unsafe path'
            assert not name.startswith('baseline/'), 'vendor XML leak'
            assert archive.read(name), f'empty file: {name}'
            actual=(archive.getinfo(name).external_attr>>16)&0o777
            expected=0o755 if name in EXECUTABLES else 0o644
            assert actual==expected, f'bad permissions: {name}'
    return hashlib.sha256(path.read_bytes()).hexdigest()

if __name__=='__main__':
    cli=argparse.ArgumentParser()
    cli.add_argument('zip_path',nargs='?',type=Path,default=Path(__file__).resolve().parents[1]/'dist'/NAME)
    args=cli.parse_args()
    sha=verify(args.zip_path)
    args.zip_path.with_suffix(args.zip_path.suffix+'.sha256').write_text(f'{sha}  {args.zip_path.name}\n')
    print('PASS:',args.zip_path,'SHA256:',sha)
