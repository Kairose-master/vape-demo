"""Build a separate read-only selected-file App Sandbox app; no downloads/model calls."""
import argparse
import json
import hashlib
import os
from pathlib import Path
import plistlib
import secrets
import subprocess
import sys
import threading
import uuid
from vape.selected_flow.server import make_server

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--prepare-only',action='store_true');parser.add_argument('--apple-local',action='store_true',help='Opt in to installed Apple on-device model, newly generated synthetic file only');parser.add_argument('--unified-ledger',action='store_true');parser.add_argument('--tools-dir',type=Path);args=parser.parse_args()
    if args.unified_ledger:
        if not args.apple_local or not args.tools_dir:parser.error('--unified-ledger requires --apple-local --tools-dir')
    root=Path(__file__).resolve().parents[2];run=root/'.runtime'/('selected-flow-'+uuid.uuid4().hex);run.mkdir(parents=True,mode=0o700)
    sys.path.insert(0,str(root/'native/scripts'))
    from build_support import discover_tools,compiler_flags,module_cache
    swift,sdk=discover_tools();flags=compiler_flags(swift,sdk,module_cache(root,'selected-flow'))
    token=secrets.token_hex(32);server=make_server(token)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    app=run/'VAPE Selected Files.app';mac=app/'Contents/MacOS';resources=app/'Contents/Resources';mac.mkdir(parents=True);resources.mkdir()
    identifier='org.vape.selectedfiles.'+uuid.uuid4().hex
    entitlements={'com.apple.security.app-sandbox':True,'com.apple.security.files.user-selected.read-only':True,
                  'com.apple.security.files.bookmarks.app-scope':True,'com.apple.security.network.client':True}
    if args.apple_local:entitlements.pop('com.apple.security.network.client')
    sample=run/'SyntheticSelection.txt';sample.write_text('SYNTHETIC VAPE NOTE: The fictional library ordered three blue notebooks for its reading club. Delivery is on Friday.\n')
    def plist(path,value):path.write_bytes(plistlib.dumps(value))
    plist(app/'Contents/Info.plist',dict(CFBundleExecutable='SelectedFlow',CFBundleIdentifier=identifier,CFBundleName='VAPE Selected Files',CFBundlePackageType='APPL',CFBundleVersion='1',LSMinimumSystemVersion='13.0',NSHighResolutionCapable=True,NSPrincipalClass='NSApplication',NSAppTransportSecurity={'NSAllowsLocalNetworking':True}))
    plist(run/'App.entitlements',entitlements)
    config=resources/'bridge.json';config.write_text(json.dumps({'port':server.server_port,'token':token,'appleLocal':args.apple_local,'unifiedLedger':args.unified_ledger,'syntheticFile':str(sample),'syntheticSHA256':hashlib.sha256(sample.read_bytes()).hexdigest()}));config.chmod(0o600)
    names=['Classification/FileRegistry.swift','Classification/MacFileSelection.swift','Classification/PrivateRegistryStore.swift','SelectedFlow/AppleLocalModel.swift','UnifiedLedger/Evidence.swift','SelectedFlow/AppleAudit.swift','SelectedFlow/PrivateModelHandoff.swift','SelectedFlow/MetadataBridge.swift','SelectedFlow/Presentation.swift','SelectedFlow/SelectedFlow.swift']
    try:
        subprocess.run(flags+[str(root/'native'/n) for n in names]+['-o',str(mac/'SelectedFlow')],check=True)
        subprocess.run(['codesign','--force','--sign','-','--timestamp=none','--options','runtime','--entitlements',str(run/'App.entitlements'),str(app)],check=True)
        subprocess.run(['codesign','--verify','--strict',str(app)],check=True)
        verifier=run/'UnifiedVerify'
        stop=threading.Event()
        if args.unified_ledger:
            parts=['Classification/FileRegistry.swift','SelectedFlow/PrivateModelHandoff.swift','UnifiedLedger/Evidence.swift','UnifiedLedger/Verify.swift']
            subprocess.run(flags+[str(root/'native'/n) for n in parts]+['-o',str(verifier)],check=True)
        # A new synthetic file is offered for a user-operated picker rehearsal; never auto-select it.
        report={'app':str(app),'syntheticFile':str(sample),'port':server.server_port,'scope':'Apple local opt-in, synthetic only, GUI inference pending' if args.apple_local else 'metadata-only; providers disabled; not inference', 'entitlements':entitlements}
        (run/'build-report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2),flush=True)
        if args.prepare_only:return
        if args.unified_ledger:
            from vape.unified_ledger.helper import serve
            exchange=Path.home()/'Library/Containers'/identifier/'Data/Library/Application Support/UnifiedLedger'
            threading.Thread(target=serve,args=(verifier,exchange,args.tools_dir,stop),daemon=True).start()
        subprocess.run(['open','-n',str(app)],check=True)
        print('Owned loopback coordinator running. Apple opt-in: '+str(args.apple_local)+'. No cloud dispatch.',flush=True)
        threading.Event().wait()
    finally:server.shutdown();server.server_close();thread.join(timeout=5)

if __name__=='__main__':main()
