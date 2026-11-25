"""Build/test only. Does not open input UI or make a live API request."""
from pathlib import Path
import json,plistlib,subprocess,sys,uuid
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'native/scripts'))
from build_support import discover_tools,compiler_flags,module_cache
run=ROOT/'.runtime'/('ready-cloud-'+uuid.uuid4().hex);run.mkdir(parents=True,mode=0o700)
swift,sdk=discover_tools();flags=compiler_flags(swift,sdk,module_cache(ROOT,'ready-cloud'))
core=ROOT/'native/ReadyCloud/Core.swift'
subprocess.run(flags+[str(core),str(ROOT/'native/ReadyCloud/Tests.swift'),'-o',str(run/'Tests')],check=True)
subprocess.run([str(run/'Tests'),str(run/'TestAudit')],check=True)
paste=ROOT/'native/ReadyCloud/SecurePaste.swift'
subprocess.run(flags+[str(paste),str(ROOT/'native/ReadyCloud/PasteTests.swift'),'-o',str(run/'PasteTests')],check=True)
subprocess.run([str(run/'PasteTests')],check=True)
app=run/'VAPE OpenAI Ready v2.app';binary=app/'Contents/MacOS/ReadyCloud';binary.parent.mkdir(parents=True)
info=dict(CFBundleExecutable='ReadyCloud',CFBundleIdentifier='org.vape.readycloud.'+uuid.uuid4().hex,CFBundleName='VAPE OpenAI Ready v2',CFBundlePackageType='APPL',CFBundleVersion='2',LSMinimumSystemVersion='13.0',NSPrincipalClass='NSApplication')
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
entitlements=run/'App.entitlements';entitlements.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True,'com.apple.security.network.client':True}))
subprocess.run(flags+[str(core),str(paste),str(ROOT/'native/ReadyCloud/App.swift'),'-o',str(binary)],check=True)
subprocess.run(['codesign','--force','--sign','-','--timestamp=none','--options','runtime','--entitlements',str(entitlements),str(app)],check=True)
subprocess.run(['codesign','--verify','--strict',str(app)],check=True)
report={'app':str(app),'tested':'synthetic-key and transport only','liveCalls':0,'fileEntitlements':False};(run/'build-report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2),flush=True)
