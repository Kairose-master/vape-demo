"""Read only this newly built app's audit metadata; never inspect previous app containers."""
import argparse,json,plistlib,subprocess,sys,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'native/scripts'))
from build_support import discover_tools,compiler_flags,module_cache
parser=argparse.ArgumentParser();parser.add_argument('--build-report',required=True,type=Path);args=parser.parse_args()
report=args.build_report.resolve();assert ROOT/'.runtime' in report.parents
app=Path(json.loads(report.read_text())['app']);assert ROOT/'.runtime' in app.parents
info=plistlib.loads((app/'Contents/Info.plist').read_bytes());identifier=info['CFBundleIdentifier'];assert identifier.startswith('org.vape.selectedfiles.')
container=Path.home()/'Library/Containers'/identifier/'Data/Library/Application Support'
audits=list(container.glob('AppleAudit-*'));assert len(audits)==1,'Expected one new app audit directory'
run=ROOT/'.runtime'/('apple-audit-check-'+uuid.uuid4().hex);run.mkdir()
swift,sdk=discover_tools()
subprocess.run(compiler_flags(swift,sdk,module_cache(ROOT,'selected-flow'))+[str(ROOT/'native/SelectedFlow/VerifyAppleAudit.swift'),'-o',str(run/'Verify')],check=True)
subprocess.run([str(run/'Verify'),str(audits[0])],check=True)
