"""Build a single console with exactly the existing Cloud sandbox entitlements."""
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import uuid
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'native/scripts'))
from build_support import discover_tools,compiler_flags,module_cache

def build(configuration):
    run=ROOT/'.runtime'/('console-'+uuid.uuid4().hex);run.mkdir(parents=True,mode=0o700)
    swift,sdk=discover_tools();flags=compiler_flags(swift,sdk,module_cache(ROOT,'console'))
    app=run/'VAPE Console.app';binary=app/'Contents/MacOS/Console';binary.parent.mkdir(parents=True)
    resources=app/'Contents/Resources';resources.mkdir();(resources/'local.json').write_text(json.dumps(configuration))
    info=dict(CFBundleExecutable='Console',CFBundleIdentifier='org.vape.console.'+uuid.uuid4().hex,CFBundleName='VAPE Console',CFBundlePackageType='APPL',CFBundleVersion='1',LSMinimumSystemVersion='13.0',NSPrincipalClass='NSApplication',NSAppTransportSecurity={'NSAllowsLocalNetworking':True})
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    entitlement=run/'App.entitlements';entitlement.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True,'com.apple.security.network.client':True}))
    sources=['native/ReadyCloud/Core.swift','native/ReadyCloud/SecurePaste.swift','native/Console/App.swift']
    subprocess.run(flags+[str(ROOT/p) for p in sources]+['-o',str(binary)],check=True)
    subprocess.run(['codesign','--force','--sign','-','--timestamp=none','--options','runtime','--entitlements',str(entitlement),str(app)],check=True)
    subprocess.run(['codesign','--verify','--strict',str(app)],check=True)
    return app
