"""Export reviewed tracked regular text files only; refuse unsafe or unreviewed content."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zipfile

ROOT=Path(__file__).resolve().parents[1]

def selected():
    return json.loads((ROOT/'portable/files.json').read_text())

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output',type=Path)
    args=parser.parse_args()
    tracked=set(subprocess.check_output(['git','ls-files','-z'],cwd=str(ROOT)).decode().split('\0'))
    names=selected()
    if len(names)!=len(set(names)): raise RuntimeError('Duplicate source manifest entry')
    checked=[]
    for name in names:
        path=Path(name)
        if name not in tracked or path.is_absolute() or '..' in path.parts or path.is_symlink():
            raise RuntimeError('Not a safe tracked source: '+name)
        source=ROOT/name
        if source.is_symlink() or not source.is_file(): raise RuntimeError('Not a regular source')
        if any(p in {'.git','.runtime','.local','__pycache__','node_modules'} for p in path.parts):
            raise RuntimeError('Runtime directory refused')
        data=source.read_bytes();text=data.decode('utf-8')
        # Specific personal paths, credential-like secrets and private-key blocks are forbidden.
        patterns=[r'/Users/[A-Za-z0-9_-]+/',r'/home/[A-Za-z0-9_-]+/',
                  r'/private/var/folders/[A-Za-z0-9/]+',r'-----BEGIN [A-Z ]*PRIVATE KEY-----',
                  r'sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{24,}']
        if any(re.search(pattern,text) for pattern in patterns):
            raise RuntimeError('Review required: sensitive-looking content in '+name)
        if b'\x00' in data: raise RuntimeError('Binary refused: '+name)
        checked.append((name,data))
    args.output.parent.mkdir(parents=True,exist_ok=True)
    with zipfile.ZipFile(args.output,'x',compression=zipfile.ZIP_DEFLATED) as archive:
        for name,data in checked:
            info=zipfile.ZipInfo('VAPE-Private-Demo/'+name,date_time=(2026,11,24,0,0,0))
            info.external_attr=0o100644 << 16
            archive.writestr(info,data,compress_type=zipfile.ZIP_DEFLATED)
    digest=hashlib.sha256(args.output.read_bytes()).hexdigest()
    args.output.with_suffix('.zip.sha256').write_text(digest+'  '+args.output.name+'\n')
    print(json.dumps({'files':len(checked),'sha256':digest,'bytes':args.output.stat().st_size,'scan':'passed; curated text source only'},indent=2))

if __name__=='__main__':main()
