"""Read-only readiness checks plus a temporary availability probe. No inference or chain startup."""
import argparse
import ast
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from vape.ledger.besu import CHAIN_ID

def pins():
    tree=ast.parse((ROOT/'vape/ledger/local_exercise.py').read_text())
    for item in ast.walk(tree):
        if isinstance(item,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='pins' for t in item.targets):
            return ast.literal_eval(item.value)
    raise RuntimeError('Pinned source configuration missing')

def tool_report(directory):
    expected=pins()
    report={'expectedChainId':CHAIN_ID,'pins':expected,'requiredPlatform':'macOS arm64',
            'requiredNode':'preinstalled Node.js (not version-pinned by driver)',
            'status':'tools_not_supplied','archives':{},'extractedFiles':'not_checked'}
    if directory is None:return report
    root=Path(directory)
    for name,digest in expected.items():
        path=root/name
        if not path.is_file():report['archives'][name]='missing';continue
        h=hashlib.sha256()
        with path.open('rb') as source:
            for data in iter(lambda:source.read(1024*1024),b''):h.update(data)
        report['archives'][name]='verified' if h.hexdigest()==digest else 'hash_mismatch'
    required=['jdk-25.0.5.1+2/Contents/Home/bin/java','jdk-25.0.5.1+2/Contents/Home/bin/javac',
              'besu-26.11.1/bin/besu','besu-26.11.1/lib/bcprov-jdk18on-1.86.jar']
    report['extractedFiles']='present' if all((root/p).is_file() for p in required) else 'missing'
    report['node']='present' if shutil.which('node') else 'missing'
    report['status']='ready' if all(v=='verified' for v in report['archives'].values()) and report['extractedFiles']=='present' and report['node']=='present' else 'not_ready'
    if platform.system()!='Darwin' or platform.machine()!='arm64':report['status']='platform_unsupported'
    return report

def check(directory=None):
    report={'system':platform.system(),'architecture':platform.machine(),'macOS':platform.mac_ver()[0] or None,
            'apple':{'status':'platform_unsupported','modelCalls':0,'fallback':False},'ledger':tool_report(directory),
            'chainStarted':False,'cloudCalls':0,'downloads':0}
    if report['system']=='Darwin' and report['architecture']=='arm64':
        sys.path.insert(0,str(ROOT/'native/scripts'))
        from build_support import discover_tools,compiler_flags
        try:
            swift,sdk=discover_tools()
            with tempfile.TemporaryDirectory(prefix='vape-readiness-') as temporary:
                temp=Path(temporary);binary=temp/'Readiness'
                build=subprocess.run(compiler_flags(swift,sdk,temp/'cache')+[str(ROOT/'portable/Readiness.swift'),'-o',str(binary)],capture_output=True,text=True)
                if build.returncode:report['apple']['status']='probe_build_failed'
                else:
                    result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=30)
                    report['apple']=json.loads(result.stdout) if result.returncode==0 else dict(status='probe_failed',modelCalls=0,fallback=False)
        except (OSError,RuntimeError,subprocess.SubprocessError,ValueError):report['apple']['status']='developer_tools_or_probe_unavailable'
    report['ready']=report['apple']['status']=='ready' and report['ledger']['status']=='ready'
    return report

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--tools-dir',type=Path);args=parser.parse_args()
    report=check(args.tools_dir);print(json.dumps(report,indent=2));return 0 if report['ready'] else 2
if __name__=='__main__':sys.exit(main())
